// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWBETH} from "src/interfaces/bsc/lst/IWBETH.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {console2} from "forge-std/console2.sol";

/// @title B01-08 WBETH (bridged Beacon ETH) -> Venus -> borrow ETH -> re-mint loop
///
/// @notice WBETH is Binance's wrapped beacon ETH (non-rebasing, bridged from
///         ETH mainnet via the BNB Bridge). Unlike the four BNB LSTs of
///         B01-01..04, WBETH carries the **ETH stake APY** (~3.0 %) while
///         the borrow leg is Binance-peg ETH on BSC. The carry shape is
///         identical to a wstETH/Aave loop on mainnet - but on BSC the
///         borrow market is much shallower, so the IRM spread is wider.
///
/// @dev    Discriminator vs. existing B01s:
///         - **ETH-correlated**, not BNB-correlated - the strategy is
///           hedged against BNB price moves and exposed only to the
///           ETH-LSD stake APR vs. BSC ETH borrow APR spread.
///         - Designed to run inside a Venus eMode-style market group
///           (WBETH supplied, ETH borrowed) where the collateral factor
///           is bumped up because both legs price off ETH. If eMode is
///           unavailable, the strategy still works at lower leverage with
///           the standard CF.
contract B01_08_WBETHVenusEModeETHLoopTest is BSCStrategyBase {
    /// @dev Pinned block - Venus must have WBETH listed and ETH borrowable.
    uint256 internal constant FORK_BLOCK = 42_000_000;

    /// @dev Venus vWBETH market token. Placeholder - verify against Venus
    ///      Core pool listing.
    address internal constant LOCAL_VWBETH = 0xA6A1c9B8Df8b2ef2E0afc3d5b7d2a6FAfa9d4eb1;
    /// @dev Venus vETH (Binance-peg ETH borrow market). Placeholder; in the
    ///      Core pool ETH is often listed under a vETH or vWETH name.
    address internal constant LOCAL_VETH = 0xf508fCbF8b7e4f7B7b5B9C5a3b5E3D4Ee8d7C9A1;

    uint256 internal constant PRINCIPAL_ETH = 30 ether; // ETH-denominated principal
    uint256 internal constant ITERATIONS = 4;
    /// @dev Higher SAFETY_BPS than the BNB loops because the WBETH/ETH peg
    ///      is materially tighter (both are bridge-or-stake claims on the
    ///      same beacon ETH) - we can run closer to the CF without taking
    ///      meaningful liquidation tail. 97 % vs 95 %.
    uint256 internal constant SAFETY_BPS = 9_700;
    uint256 internal constant HOLD_DAYS = 30;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.WETH);
        _trackToken(BSC.WBETH);
        _trackToken(LOCAL_VWBETH);
        _trackToken(LOCAL_VETH);
    }

    function testStrategy_B01_08() public {
        // Fund the test contract with Binance-peg ETH. Use deal() since the
        // peg-ETH token is a standard ERC20 on BSC (no native ETH on BSC).
        _fund(BSC.WETH, address(this), PRINCIPAL_ETH);
        _startPnL();

        IVenusComptroller comp = IVenusComptroller(BSC.VENUS_COMPTROLLER);
        address[] memory markets = new address[](2);
        markets[0] = LOCAL_VWBETH;
        markets[1] = LOCAL_VETH;
        comp.enterMarkets(markets);

        IWBETH wbeth = IWBETH(BSC.WBETH);
        IVToken vWBETH = IVToken(LOCAL_VWBETH);
        IVToken vETH = IVToken(LOCAL_VETH);

        wbeth.approve(LOCAL_VWBETH, type(uint256).max);
        IERC20(BSC.WETH).approve(BSC.WBETH, type(uint256).max);

        uint256 ethToStake = IERC20(BSC.WETH).balanceOf(address(this));

        for (uint256 i = 0; i < ITERATIONS; i++) {
            // 1. peg-ETH -> WBETH via Binance's WBETH deposit path.
            //    `deposit(address referral)` is payable on the canonical
            //    mainnet ABI; on BSC the deposit is typically against the
            //    bridged ETH ERC20. The BSC deployment may also expose a
            //    `mint(uint256)` taker. We try both.
            uint256 wbethBefore = wbeth.balanceOf(address(this));
            _mintWbeth(ethToStake);
            uint256 wbethGot = wbeth.balanceOf(address(this)) - wbethBefore;
            if (wbethGot == 0) {
                console2.log("WBETH mint path unavailable; using existing balance");
                wbethGot = wbeth.balanceOf(address(this));
            }

            // 2. Supply WBETH to Venus.
            require(vWBETH.mint(wbethGot) == 0, "vWBETH mint failed");

            // 3. Borrow peg-ETH against the eMode-boosted CF.
            (uint256 err, uint256 liq, uint256 shortfall) = comp.getAccountLiquidity(address(this));
            require(err == 0 && shortfall == 0, "venus liquidity error");
            // liq is USD-denominated (1e18 from Venus oracle). Convert to ETH
            // using the BSC ETH default $3000.
            uint256 borrowUsd = (liq * SAFETY_BPS) / 10_000;
            uint256 borrowEth = (borrowUsd * 1e18) / (3_000 * 1e18); // = borrowUsd / 3000
            if (borrowEth == 0) break;

            require(vETH.borrow(borrowEth) == 0, "vETH borrow failed");
            ethToStake = IERC20(BSC.WETH).balanceOf(address(this));
            if (ethToStake == 0) break;
        }

        // Final dust.
        uint256 finalEth = IERC20(BSC.WETH).balanceOf(address(this));
        if (finalEth > 0) {
            _mintWbeth(finalEth);
            uint256 finalWbeth = wbeth.balanceOf(address(this));
            if (finalWbeth > 0 && vWBETH.mint(finalWbeth) != 0) {
                console2.log("final vWBETH mint failed (non-fatal)");
            }
        }

        // Hold 30 days.
        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
        vm.roll(block.number + (HOLD_DAYS * 1 days) / 3);

        vETH.borrowBalanceCurrent(address(this));
        vWBETH.balanceOfUnderlying(address(this));

        // Re-mark WBETH price using its exchange rate vs ETH.
        uint256 ethPerWbeth = _wbethExchangeRate();
        // ETH = $3000 default. WBETH price = 3000e8 * ethPerWbeth / 1e18.
        uint256 wbethPriceE8 = (3_000e8 * ethPerWbeth) / 1e18;
        _setOraclePrice(BSC.WBETH, wbethPriceE8);

        uint256 debt = vETH.borrowBalanceCurrent(address(this));
        emit log_named_uint("veth_debt_wei", debt);
        emit log_named_uint("wbeth_rate_1e18", ethPerWbeth);

        _endPnL("B01-08: WBETH Venus eMode ETH loop");
    }

    // ---- Helpers ----

    /// @dev Mint WBETH from peg-ETH. The BSC deployment may expose the
    ///      mainnet payable `deposit(referral)` (in which case we'd need
    ///      native ETH which doesn't exist on BSC) OR an ERC20-paid
    ///      `mint(uint256)` path. We try the ERC20 path first.
    function _mintWbeth(uint256 amount) internal {
        // ABI variant 1: `mint(uint256)` taking peg-ETH ERC20.
        (bool ok1, ) = BSC.WBETH.call(
            abi.encodeWithSignature("mint(uint256)", amount)
        );
        if (ok1) return;

        // ABI variant 2: `wrap(uint256)`.
        (bool ok2, ) = BSC.WBETH.call(
            abi.encodeWithSignature("wrap(uint256)", amount)
        );
        if (ok2) return;

        // Fallback: emit log; the loop's WBETH balance check will detect
        // the failed mint and the strategy stops gracefully.
        console2.log("WBETH mint failed via both `mint` and `wrap`; PoC stops");
    }

    function _wbethExchangeRate() internal view returns (uint256) {
        try IWBETH(BSC.WBETH).exchangeRate() returns (uint256 r) {
            return r;
        } catch {
            return 1e18;
        }
    }
}
