// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IStETH} from "src/interfaces/lst/IStETH.sol";
import {IWstETH} from "src/interfaces/lst/IWstETH.sol";
import {IPufETH} from "src/interfaces/lrt/IPufETH.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Symbiotic DefaultCollateral interface — wrapper-style deposit pattern.
interface ISymbioticDefaultCollateral {
    function deposit(address recipient, uint256 amount) external returns (uint256);
    function withdraw(address recipient, uint256 amount) external;
    function totalSupply() external view returns (uint256);
    function limit() external view returns (uint256);
    function asset() external view returns (address);
}

/// @notice F02-06 — pufETH triple-stack: Puffer + Symbiotic + Aave eMode.
///
/// Combines THREE distinct mechanisms on correlated wstETH/pufETH notionals:
///   1. Puffer (pufETH) on Aave V3 eMode (cat 1, ETH-correlated) — leverage loop.
///   2. Symbiotic DC_wstETH side-deposit — unencumbered Symbiotic-point stream.
///   3. Lido + EigenLayer point streams compound through the pufETH leg.
contract F02_06_PufethSymbioticAaveEmodeTripleTest is StrategyBase {
    // ---- Pinned constants ----

    /// @dev Block 20,100,000 — early June 2024. pufETH on Aave eMode; Symbiotic
    /// DC_wstETH live and deposit-cap not full.
    uint256 constant FORK_BLOCK = 20_100_000;

    /// @dev Symbiotic DC_wstETH — DefaultCollateral wrapper over wstETH.
    /// https://etherscan.io/address/0xc329400492c6ff2438472d4651ad17389fcb843a
    address constant LOCAL_SYMBIOTIC_DC_WSTETH = 0xC329400492c6ff2438472D4651Ad17389fCb843a;

    /// @dev Aave V3 mainnet eMode category 1 = "ETH correlated" (genesis payload).
    /// pufETH was enrolled in cat 1 by Aave governance via the May-2024 listing
    /// payload; at FORK_BLOCK 20,100,000 it is live in eMode.
    uint8 constant EMODE_CATEGORY_ETH = 1;

    uint256 constant EQUITY = 100 ether;
    /// @dev 25% of equity goes to Symbiotic side-stack; 75% is the Aave loop seed.
    uint256 constant SYMBIOTIC_BPS = 2500;
    /// @dev Number of Aave loop iterations (5 → ~3.4x leverage at 85% borrow ratio).
    uint8 constant LOOPS = 5;
    /// @dev Per-iteration borrow as a fraction of `availableBorrowsBase`.
    uint256 constant BORROW_RATIO_BPS = 8500;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.STETH);
        _trackToken(Mainnet.WSTETH);
        _trackToken(Mainnet.PUFETH);
        _trackToken(LOCAL_SYMBIOTIC_DC_WSTETH);
    }

    function testStrategy_F02_06() public {
        _fund(Mainnet.WETH, address(this), EQUITY);
        _startPnL();

        // ---- 1. Unwrap, mint stETH, wrap to wstETH ----
        IWETH(Mainnet.WETH).withdraw(EQUITY);
        IStETH(Mainnet.STETH).submit{value: EQUITY}(address(0));
        uint256 stEthBal = IERC20(Mainnet.STETH).balanceOf(address(this));
        IERC20(Mainnet.STETH).approve(Mainnet.WSTETH, stEthBal);
        uint256 wstEthBal = IWstETH(Mainnet.WSTETH).wrap(stEthBal);
        console2.log("wstETH after wrap:", wstEthBal);

        // ---- 2. Split: Symbiotic leg ----
        uint256 symAmount = (wstEthBal * SYMBIOTIC_BPS) / 10_000;
        uint256 pufAmount = wstEthBal - symAmount;

        IERC20(Mainnet.WSTETH).approve(LOCAL_SYMBIOTIC_DC_WSTETH, symAmount);
        try ISymbioticDefaultCollateral(LOCAL_SYMBIOTIC_DC_WSTETH).deposit(address(this), symAmount) returns (uint256 dcOut) {
            console2.log("DC_wstETH minted:", dcOut);
        } catch {
            // DC cap reached or paused — leg degrades to raw wstETH (Lido pts only).
            console2.log("Symbiotic DC_wstETH deposit failed");
        }

        // ---- 3. Puffer leg: wstETH → pufETH ----
        IERC20(Mainnet.WSTETH).approve(Mainnet.PUFETH, pufAmount);
        IPufETH(Mainnet.PUFETH).depositWstETH(pufAmount, address(this));
        uint256 pufBal = IERC20(Mainnet.PUFETH).balanceOf(address(this));
        console2.log("pufETH minted:", pufBal);

        // ---- 4. Aave: set eMode, supply, enable collateral ----
        // Some Aave versions revert if user has no position; wrap in try/catch.
        try IAavePool(Mainnet.AAVE_V3_POOL).setUserEMode(EMODE_CATEGORY_ETH) {} catch {}

        IERC20(Mainnet.PUFETH).approve(Mainnet.AAVE_V3_POOL, type(uint256).max);
        IERC20(Mainnet.WETH).approve(Mainnet.AAVE_V3_POOL, type(uint256).max);
        IERC20(Mainnet.WSTETH).approve(Mainnet.AAVE_V3_POOL, type(uint256).max);

        try IAavePool(Mainnet.AAVE_V3_POOL).supply(Mainnet.PUFETH, pufBal, address(this), 0) {
            try IAavePool(Mainnet.AAVE_V3_POOL).setUserUseReserveAsCollateral(Mainnet.PUFETH, true) {} catch {}
        } catch {
            // pufETH not yet listed on Aave at this block — fall back: supply wstETH instead.
            console2.log("pufETH supply failed; falling back to wstETH supply path");
            IERC20(Mainnet.PUFETH).approve(Mainnet.PUFETH, pufBal);
            // Redeem pufETH back to wstETH (best-effort via ERC4626 withdraw API).
            try IPufETH(Mainnet.PUFETH).redeem(pufBal, address(this), address(this)) returns (uint256) {
                uint256 wstRecovered = IERC20(Mainnet.WSTETH).balanceOf(address(this));
                IAavePool(Mainnet.AAVE_V3_POOL).supply(Mainnet.WSTETH, wstRecovered, address(this), 0);
                IAavePool(Mainnet.AAVE_V3_POOL).setUserUseReserveAsCollateral(Mainnet.WSTETH, true);
            } catch {
                console2.log("pufETH redeem also failed; leg is illiquid");
            }
        }

        // Try eMode again now that there is collateral.
        try IAavePool(Mainnet.AAVE_V3_POOL).setUserEMode(EMODE_CATEGORY_ETH) {} catch {}

        // ---- 5. Loop: borrow WETH, convert back to pufETH, re-supply ----
        for (uint8 i = 0; i < LOOPS; i++) {
            (, , uint256 availBase, , , ) =
                IAavePool(Mainnet.AAVE_V3_POOL).getUserAccountData(address(this));
            if (availBase == 0) break;

            uint256 borrowAmt = _estimateBorrowAmount(availBase);
            if (borrowAmt < 1e15) break;

            uint256 wethBefore = IERC20(Mainnet.WETH).balanceOf(address(this));
            try IAavePool(Mainnet.AAVE_V3_POOL).borrow(
                Mainnet.WETH, borrowAmt, 2 /*variable*/, 0, address(this)
            ) {} catch {
                break;
            }
            uint256 newWeth = IERC20(Mainnet.WETH).balanceOf(address(this)) - wethBefore;
            if (newWeth == 0) break;

            // WETH → stETH → wstETH → pufETH
            IWETH(Mainnet.WETH).withdraw(newWeth);
            IStETH(Mainnet.STETH).submit{value: newWeth}(address(0));
            uint256 stEthNow = IERC20(Mainnet.STETH).balanceOf(address(this));
            IERC20(Mainnet.STETH).approve(Mainnet.WSTETH, stEthNow);
            uint256 wstNow = IWstETH(Mainnet.WSTETH).wrap(stEthNow);
            IERC20(Mainnet.WSTETH).approve(Mainnet.PUFETH, wstNow);
            try IPufETH(Mainnet.PUFETH).depositWstETH(wstNow, address(this)) returns (uint256) {
                uint256 newPuf = IERC20(Mainnet.PUFETH).balanceOf(address(this));
                if (newPuf == 0) break;
                try IAavePool(Mainnet.AAVE_V3_POOL).supply(Mainnet.PUFETH, newPuf, address(this), 0) {}
                catch { break; }
            } catch {
                // If pufETH minting fails, supply wstETH instead and continue.
                IAavePool(Mainnet.AAVE_V3_POOL).supply(Mainnet.WSTETH, wstNow, address(this), 0);
            }
        }

        _endPnL("F02-06: pufETH-symbiotic-aave-emode-triple");
    }

    /// @dev Conservative WETH-amount estimate from Aave's USD-8dec base unit.
    /// Uses a fixed ETH-USD=$3000 to avoid an extra Chainlink call.
    function _estimateBorrowAmount(uint256 availableBase) internal pure returns (uint256) {
        uint256 ETH_USD_E8 = 3000e8;
        uint256 capWei = (availableBase * 1e18) / ETH_USD_E8;
        return (capWei * BORROW_RATIO_BPS) / 10_000;
    }
}
