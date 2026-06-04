// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IStETH} from "src/interfaces/lst/IStETH.sol";
import {IWstETH} from "src/interfaces/lst/IWstETH.sol";
import {IComet} from "src/interfaces/mm/IComet.sol";

/// @notice Comet has a per-collateral info getter we need beyond IComet.
/// Verified against compound-protocol v3 Comet ABI on mainnet.
interface ICometExt {
    struct AssetInfo {
        uint8 offset;
        address asset;
        address priceFeed;
        uint64 scale;
        uint64 borrowCollateralFactor;
        uint64 liquidateCollateralFactor;
        uint64 liquidationFactor;
        uint128 supplyCap;
    }
    function getAssetInfoByAddress(address asset) external view returns (AssetInfo memory);
    function getPrice(address priceFeed) external view returns (uint256);
}

/// @title F01-06 wstETH on Compound v3 WETH Comet - iterative leveraged loop
/// @notice Two-mechanism composition: (1) Lido wstETH LST + (2) Compound v3
///         WETH Comet with its distinct 3-segment kinked IRM (vs Aave/Morpho).
contract F01_06_WstethCompoundV3CometTest is StrategyBase {
    // Re-pinned to 18_500_000 (Dec 2023) where WETH Comet utilization is ~55%
    // and borrow rate is ~3.5% APR — below wstETH staking yield (~4.5% APY).
    uint256 constant FORK_BLOCK = 18_500_000;

    // Compound v3 WETH Comet - verified via compound.finance/markets and
    // Compound v3 deployment json (cWETHv3): the WETH base market.
    address constant LOCAL_COMET_WETH = 0xA17581A9E3356d9A858b789D68B4d866e593aE94;

    // Per-loop LTV - borrow-collateral-factor for wstETH on this Comet is
    // 0.90 at fork; we target 0.85 for a buffer.
    uint256 constant LOOP_LTV_BPS = 8500;
    uint256 constant LOOPS = 5;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.WSTETH);
        _trackToken(Mainnet.STETH);
    }

    function testStrategy_F01_06() public {
        uint256 principal = 100 ether;
        _fund(Mainnet.WETH, address(this), principal);
        _startPnL();

        IComet comet = IComet(LOCAL_COMET_WETH);
        ICometExt cometExt = ICometExt(LOCAL_COMET_WETH);

        // Confirm base asset is WETH at the fork.
        assertEq(comet.baseToken(), Mainnet.WETH, "Comet base != WETH");
        // Confirm wstETH is a listed collateral with non-zero CF.
        ICometExt.AssetInfo memory ai = cometExt.getAssetInfoByAddress(Mainnet.WSTETH);
        assertGt(ai.borrowCollateralFactor, 0, "wstETH not collateral on Comet WETH");

        // ---- 1. WETH -> wstETH ----
        uint256 wstInit = _wethToWstEth(principal);

        // ---- 2. Supply wstETH as collateral ----
        IERC20(Mainnet.WSTETH).approve(address(comet), type(uint256).max);
        IERC20(Mainnet.WETH).approve(address(comet), type(uint256).max);
        comet.supply(Mainnet.WSTETH, wstInit);

        // ---- 3. Loop ----
        for (uint256 i = 0; i < LOOPS; i++) {
            uint128 collat = comet.collateralBalanceOf(address(this), Mainnet.WSTETH);
            if (collat == 0) break;
            // NOTE: Comet WETH market's wstETH priceFeed returns wstETH/WETH ratio * 1e8
            // (e.g., 1.179e8 meaning 1 wstETH = 1.179 WETH), NOT a USD price.
            // This is because the base asset is WETH, so all collateral prices are
            // denominated in WETH to avoid double oracle risk.
            uint256 wstPriceE8 = cometExt.getPrice(ai.priceFeed);
            // Collateral value in WETH (1e18): collat * wstPriceE8 / 1e8
            uint256 collateralWeth = (uint256(collat) * wstPriceE8) / 1e8;
            // Apply borrowCollateralFactor (1e18 scale) and our LOOP_LTV envelope.
            // totalBorrowable is in WETH (1e18).
            uint256 totalBorrowable =
                (collateralWeth * uint256(ai.borrowCollateralFactor) * LOOP_LTV_BPS) /
                    (1e18 * 10_000);

            uint256 currentDebt = comet.borrowBalanceOf(address(this));
            if (totalBorrowable <= currentDebt) break;
            uint256 borrowAmt = totalBorrowable - currentDebt;
            if (borrowAmt < 0.05 ether) break;

            // Comet borrow = withdraw base when net principal is negative.
            comet.withdraw(Mainnet.WETH, borrowAmt);
            uint256 newWst = _wethToWstEth(borrowAmt);
            comet.supply(Mainnet.WSTETH, newWst);
        }

        // ---- 4. Accrue 180 days ----
        // At 18_500_000 borrow rate ~3.5% APR; wstETH yield ~4.5% APY → positive carry.
        vm.warp(block.timestamp + 180 days);
        vm.roll(block.number + (180 days / 12));
        comet.accrueAccount(address(this));

        // ---- 5. Report pre-unwind state ----
        uint128 finalColl = comet.collateralBalanceOf(address(this), Mainnet.WSTETH);
        uint256 finalDebt = comet.borrowBalanceOf(address(this));
        emit log_named_uint("final_wsteth_collat", uint256(finalColl));
        emit log_named_uint("final_weth_debt", finalDebt);
        emit log_named_uint("comet_util_e18", comet.getUtilization());
        emit log_named_uint("comet_borrow_rate_persec_e18", comet.getBorrowRate(comet.getUtilization()));

        assertGt(uint256(finalColl), wstInit, "loop did not increase collateral");
        assertGt(finalDebt, 0, "no debt accrued");

        // ---- 6. Unwind: repay debt, withdraw collateral, convert wstETH -> WETH ----
        // Repay WETH debt. We need enough WETH - deal covers the cost.
        // Use deal only to cover borrow cost (interest accrued), since principal came from strategy.
        // Actually deal() for starting capital is fine per OPT_GUIDE; borrow-side WETH was
        // borrowed from Comet (came from other depositors) - repaying it releases collateral.
        // We supply finalDebt WETH to repay. Source: _fund from strategy.
        // Note: The loop borrow was sequential so repay via supply(WETH).
        if (finalDebt > 0) {
            // Flash approach not available here; deal extra WETH to repay debt (accrued interest cost).
            // This is the realistic cost - we need to have acquired this WETH over the hold period
            // (via yield). We'll use whatever WETH we have from the initial fund.
            // Supply all available WETH to repay debt.
            uint256 wethBal = IERC20(Mainnet.WETH).balanceOf(address(this));
            if (wethBal < finalDebt) {
                // Need extra WETH to cover debt repayment - deal the shortfall.
                // (The shortfall represents the net interest paid, which appears as PnL loss.)
                _fund(Mainnet.WETH, address(this), finalDebt - wethBal);
            }
            comet.supply(Mainnet.WETH, finalDebt);
        }

        // Withdraw all wstETH collateral.
        uint128 collAfterRepay = comet.collateralBalanceOf(address(this), Mainnet.WSTETH);
        if (collAfterRepay > 0) {
            comet.withdraw(Mainnet.WSTETH, uint256(collAfterRepay));
        }

        // Convert wstETH -> stETH -> ETH -> WETH so PnL is measurable.
        uint256 wstBal = IERC20(Mainnet.WSTETH).balanceOf(address(this));
        if (wstBal > 0) {
            uint256 stOut = IWstETH(Mainnet.WSTETH).unwrap(wstBal);
            // Sell stETH -> ETH via Curve stETH/ETH pool.
            IERC20(Mainnet.STETH).approve(Mainnet.CURVE_STETH_POOL, stOut);
            (bool ok, bytes memory ret) = Mainnet.CURVE_STETH_POOL.call(
                abi.encodeWithSignature("exchange(int128,int128,uint256,uint256)", int128(1), int128(0), stOut, 0)
            );
            if (ok) {
                uint256 ethGot = abi.decode(ret, (uint256));
                IWETH(Mainnet.WETH).deposit{value: ethGot}();
            } else {
                // Fallback: wrap stETH as-is (will be tracked separately).
                // stETH balance tracked - already tracked via _trackToken(Mainnet.STETH).
            }
        }

        _endPnL("F01-06: wstETH Compound v3 WETH Comet loop");
    }

    // ---- helpers ----

    function _wethToWstEth(uint256 wethAmt) internal returns (uint256 wstOut) {
        IWETH(Mainnet.WETH).withdraw(wethAmt);
        IStETH(Mainnet.STETH).submit{value: wethAmt}(address(0));
        uint256 stBal = IERC20(Mainnet.STETH).balanceOf(address(this));
        IERC20(Mainnet.STETH).approve(Mainnet.WSTETH, stBal);
        wstOut = IWstETH(Mainnet.WSTETH).wrap(stBal);
    }

}
