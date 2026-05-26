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
    uint256 constant FORK_BLOCK = 20_800_000;

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
            // Use Comet's own price feeds for accuracy (1e8 scale).
            uint256 wstPriceE8 = cometExt.getPrice(ai.priceFeed);
            // Comet base scale is 1e18 (WETH); collateral scale is ai.scale (1e18).
            // Collateral USD value (1e8) = collat * wstPriceE8 / 1e18.
            uint256 collateralUsdE8 = (uint256(collat) * wstPriceE8) / 1e18;
            // Apply borrowCollateralFactor (1e18 scale) and our LOOP_LTV envelope.
            uint256 borrowableUsdE8 =
                (collateralUsdE8 * uint256(ai.borrowCollateralFactor) * LOOP_LTV_BPS) /
                    (1e18 * 10_000);
            // Convert USD value back to WETH using ETH/USD oracle (1e8).
            uint256 ethPriceE8 = _ethUsdE8();
            if (ethPriceE8 == 0) break;
            uint256 totalBorrowable = (borrowableUsdE8 * 1e18) / ethPriceE8;

            uint256 currentDebt = comet.borrowBalanceOf(address(this));
            if (totalBorrowable <= currentDebt) break;
            uint256 borrowAmt = totalBorrowable - currentDebt;
            if (borrowAmt < 0.05 ether) break;

            // Comet borrow = withdraw base when net principal is negative.
            comet.withdraw(Mainnet.WETH, borrowAmt);
            uint256 newWst = _wethToWstEth(borrowAmt);
            comet.supply(Mainnet.WSTETH, newWst);
        }

        // ---- 4. Accrue 30 days ----
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));
        comet.accrueAccount(address(this));

        // ---- 5. Report ----
        uint128 finalColl = comet.collateralBalanceOf(address(this), Mainnet.WSTETH);
        uint256 finalDebt = comet.borrowBalanceOf(address(this));
        emit log_named_uint("final_wsteth_collat", uint256(finalColl));
        emit log_named_uint("final_weth_debt", finalDebt);
        emit log_named_uint("comet_util_e18", comet.getUtilization());
        emit log_named_uint("comet_borrow_rate_persec_e18", comet.getBorrowRate(comet.getUtilization()));

        assertGt(uint256(finalColl), wstInit, "loop did not increase collateral");
        assertGt(finalDebt, 0, "no debt accrued");

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

    function _ethUsdE8() internal view returns (uint256) {
        (bool ok, bytes memory data) = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419)
            .staticcall(abi.encodeWithSignature("latestAnswer()"));
        if (!ok || data.length < 32) return 0;
        int256 ans = abi.decode(data, (int256));
        return ans > 0 ? uint256(ans) : 0;
    }
}
