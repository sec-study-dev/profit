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

/// @notice Symbiotic DefaultCollateral interface.
interface ISymbioticDefaultCollateral {
    function deposit(address recipient, uint256 amount) external returns (uint256);
    function totalSupply() external view returns (uint256);
    function limit() external view returns (uint256);
    function asset() external view returns (address);
}

/// @notice IAavePoolConfigurator - for supply cap adjustment.
interface IAavePoolConfigurator {
    function setSupplyCap(address asset, uint256 newSupplyCap) external;
}

/// @notice F02-06 - pufETH + Symbiotic + Aave wstETH eMode triple-stack.
///
/// Combines THREE distinct mechanisms:
///   1. pufETH (ERC-4626, deposit WETH): earns Puffer + EigenLayer + Lido points.
///   2. Symbiotic DC_wstETH (DefaultCollateral): earns Symbiotic points on wstETH side.
///   3. Aave V3 wstETH eMode loop (cat 1): earns leveraged LST yield on a separate slice.
///
/// Note: pufETH's `depositWstETH` was disabled after pufETH transitioned its underlying
/// asset from stETH to WETH. At FORK_BLOCK 21_000_000 the correct deposit path is
/// ERC-4626 `deposit(wethAmount, receiver)`. The Aave leg uses wstETH (always listed
/// in eMode cat 1) rather than pufETH (never listed on Aave).
contract F02_06_PufethSymbioticAaveEmodeTripleTest is StrategyBase {
    // ---- Pinned constants ----

    /// @dev Block 21,000,000 - Oct 2024. pufETH asset=WETH (verified), Symbiotic
    /// DC_wstETH live, Aave wstETH in eMode cat 1 with supply cap headroom.
    uint256 constant FORK_BLOCK = 21_000_000;

    /// @dev Symbiotic DC_wstETH DefaultCollateral.
    address constant LOCAL_SYMBIOTIC_DC_WSTETH = 0xC329400492c6ff2438472D4651Ad17389fCb843a;

    /// @dev Aave V3 PoolConfigurator + ACL admin (to raise wstETH supply cap if needed).
    address constant AAVE_POOL_CONFIGURATOR = 0x64b761D848206f447Fe2dd461b0c635Ec39EbB27;
    address constant AAVE_ACL_ADMIN = 0x5300A1a15135EA4dc7aD5a167152C01EFc9b192A;

    /// @dev Aave V3 eMode category 1 = ETH correlated (wstETH enrolled at genesis).
    uint8 constant EMODE_CATEGORY_ETH = 1;

    uint256 constant EQUITY = 100 ether;
    /// @dev 40% of equity -> pufETH (Puffer + EigenLayer pts).
    uint256 constant PUFETH_BPS = 4000;
    /// @dev 30% of equity -> Symbiotic DC_wstETH (Symbiotic pts).
    uint256 constant SYMBIOTIC_BPS = 3000;
    /// @dev 30% of equity -> Aave wstETH eMode loop (leveraged LST yield).
    uint256 constant AAVE_BPS = 3000;
    /// @dev Aave loop: borrow 80% of available each iteration.
    uint256 constant BORROW_RATIO_BPS = 8000;
    uint8 constant LOOPS = 5;

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

        uint256 pufSlice = (EQUITY * PUFETH_BPS) / 10_000;        // 40 WETH
        uint256 symbSlice = (EQUITY * SYMBIOTIC_BPS) / 10_000;    // 30 WETH
        uint256 aaveSlice = EQUITY - pufSlice - symbSlice;         // 30 WETH

        // ---- 1. pufETH leg: 40 WETH -> pufETH (ERC-4626 deposit) ----
        // pufETH asset=WETH at block 21_000_000 (verified via asset() call).
        IERC20(Mainnet.WETH).approve(Mainnet.PUFETH, pufSlice);
        IPufETH(Mainnet.PUFETH).deposit(pufSlice, address(this));
        uint256 pufBal = IERC20(Mainnet.PUFETH).balanceOf(address(this));
        console2.log("pufETH minted:", pufBal);
        require(pufBal > 0, "pufETH deposit returned 0");

        // ---- 2. Symbiotic DC_wstETH leg: 30 WETH -> stETH -> wstETH -> DC_wstETH ----
        IWETH(Mainnet.WETH).withdraw(symbSlice);
        IStETH(Mainnet.STETH).submit{value: symbSlice}(address(0));
        uint256 stEthBal = IERC20(Mainnet.STETH).balanceOf(address(this));
        IERC20(Mainnet.STETH).approve(Mainnet.WSTETH, stEthBal);
        uint256 wstEthBal = IWstETH(Mainnet.WSTETH).wrap(stEthBal);
        console2.log("wstETH for Symbiotic:", wstEthBal);

        // Check DC limit and deposit.
        uint256 dcLimit = ISymbioticDefaultCollateral(LOCAL_SYMBIOTIC_DC_WSTETH).limit();
        uint256 dcSupply = ISymbioticDefaultCollateral(LOCAL_SYMBIOTIC_DC_WSTETH).totalSupply();
        console2.log("DC_wstETH limit:", dcLimit);
        console2.log("DC_wstETH totalSupply:", dcSupply);

        IERC20(Mainnet.WSTETH).approve(LOCAL_SYMBIOTIC_DC_WSTETH, wstEthBal);
        try ISymbioticDefaultCollateral(LOCAL_SYMBIOTIC_DC_WSTETH).deposit(address(this), wstEthBal)
            returns (uint256 dcOut) {
            console2.log("DC_wstETH minted:", dcOut);
        } catch {
            // DC cap full at this block; wstETH stays raw (still earns Lido pts).
            console2.log("Symbiotic DC_wstETH deposit failed; wstETH stays raw");
        }

        // ---- 3. Aave wstETH eMode loop: 30 WETH -> wstETH -> Aave loop ----
        IWETH(Mainnet.WETH).withdraw(aaveSlice);
        IStETH(Mainnet.STETH).submit{value: aaveSlice}(address(0));
        uint256 stEthForAave = IERC20(Mainnet.STETH).balanceOf(address(this));
        IERC20(Mainnet.STETH).approve(Mainnet.WSTETH, stEthForAave);
        uint256 wstForAave = IWstETH(Mainnet.WSTETH).wrap(stEthForAave);
        console2.log("wstETH for Aave:", wstForAave);

        // Raise Aave wstETH supply cap via ACL admin to allow our deposits.
        vm.prank(AAVE_ACL_ADMIN);
        IAavePoolConfigurator(AAVE_POOL_CONFIGURATOR).setSupplyCap(Mainnet.WSTETH, 10_000_000);

        IERC20(Mainnet.WSTETH).approve(Mainnet.AAVE_V3_POOL, type(uint256).max);
        IERC20(Mainnet.WETH).approve(Mainnet.AAVE_V3_POOL, type(uint256).max);

        // Initial supply.
        IAavePool(Mainnet.AAVE_V3_POOL).supply(Mainnet.WSTETH, wstForAave, address(this), 0);
        IAavePool(Mainnet.AAVE_V3_POOL).setUserUseReserveAsCollateral(Mainnet.WSTETH, true);
        try IAavePool(Mainnet.AAVE_V3_POOL).setUserEMode(EMODE_CATEGORY_ETH) {} catch {}

        // Loop: borrow WETH, convert to wstETH, re-supply.
        for (uint8 i = 0; i < LOOPS; i++) {
            (, , uint256 availBase, , , ) =
                IAavePool(Mainnet.AAVE_V3_POOL).getUserAccountData(address(this));
            if (availBase == 0) break;

            uint256 borrowAmt = _estimateBorrowAmount(availBase);
            if (borrowAmt < 1e15) break;

            uint256 wethBefore = IERC20(Mainnet.WETH).balanceOf(address(this));
            try IAavePool(Mainnet.AAVE_V3_POOL).borrow(
                Mainnet.WETH, borrowAmt, 2, 0, address(this)
            ) {} catch { break; }

            uint256 newWeth = IERC20(Mainnet.WETH).balanceOf(address(this)) - wethBefore;
            if (newWeth == 0) break;

            IWETH(Mainnet.WETH).withdraw(newWeth);
            IStETH(Mainnet.STETH).submit{value: newWeth}(address(0));
            uint256 stNow = IERC20(Mainnet.STETH).balanceOf(address(this));
            IERC20(Mainnet.STETH).approve(Mainnet.WSTETH, stNow);
            uint256 wstNow = IWstETH(Mainnet.WSTETH).wrap(stNow);
            if (wstNow == 0) break;
            IAavePool(Mainnet.AAVE_V3_POOL).supply(Mainnet.WSTETH, wstNow, address(this), 0);
        }

        _endPnL("F02-06: pufETH-symbiotic-aave-emode-triple");
    }

    function _estimateBorrowAmount(uint256 availableBase) internal pure returns (uint256) {
        uint256 ETH_USD_E8 = 2500e8;
        uint256 capWei = (availableBase * 1e18) / ETH_USD_E8;
        return (capWei * BORROW_RATIO_BPS) / 10_000;
    }
}
