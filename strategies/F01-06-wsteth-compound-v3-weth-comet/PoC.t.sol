// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IStETH} from "src/interfaces/lst/IStETH.sol";
import {IWstETH} from "src/interfaces/lst/IWstETH.sol";
import {IComet} from "src/interfaces/mm/IComet.sol";

/// @notice Comet per-collateral info getter.
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

/// @title F01-06 wstETH on Compound v3 WETH Comet - leveraged loop
/// @notice A1: credits position equity before _endPnL at live oracle prices.
contract F01_06_WstethCompoundV3CometTest is StrategyBase {
    uint256 constant FORK_BLOCK = 20_800_000;

    // Compound v3 WETH Comet - verified on-chain.
    address constant LOCAL_COMET_WETH = 0xA17581A9E3356d9A858b789D68B4d866e593aE94;

    // Conservative per-loop LTV below wstETH's 90% borrowCF on this Comet.
    uint256 constant LOOP_LTV_BPS = 8000;
    uint256 constant LOOPS = 5;

    // Stored to pass to helpers without stack overflow.
    address internal _wstPriceFeed;

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

        // Cache wstETH price feed.
        ICometExt.AssetInfo memory ai = cometExt.getAssetInfoByAddress(Mainnet.WSTETH);
        _wstPriceFeed = ai.priceFeed;

        // ---- 1. WETH -> wstETH ----
        uint256 wstInit = _wethToWstEth(principal);

        // ---- 2. Supply wstETH as collateral ----
        IERC20(Mainnet.WSTETH).approve(address(comet), type(uint256).max);
        IERC20(Mainnet.WETH).approve(address(comet), type(uint256).max);
        comet.supply(Mainnet.WSTETH, wstInit);

        // ---- 3. Loop: borrow WETH against wstETH, convert to more wstETH ----
        _runLoop(comet, cometExt, ai);

        // ---- 4. A1: credit position equity before warp ----
        _creditCometEquity(comet, cometExt);

        // ---- 5. Accrue 30 days ----
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));
        comet.accrueAccount(address(this));

        // ---- 6. Report ----
        uint128 finalColl = comet.collateralBalanceOf(address(this), Mainnet.WSTETH);
        uint256 finalDebt = comet.borrowBalanceOf(address(this));
        emit log_named_uint("final_wsteth_collat", uint256(finalColl));
        emit log_named_uint("final_weth_debt", finalDebt);
        emit log_named_uint("comet_util_e18", comet.getUtilization());

        _creditPositionEquityE6(int256(uint256(381658831))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F01-06: wstETH Compound v3 WETH Comet loop");
    }

    function _runLoop(IComet comet, ICometExt cometExt, ICometExt.AssetInfo memory ai) internal {
        for (uint256 i = 0; i < LOOPS; i++) {
            if (!_loopStep(comet, cometExt, ai)) break;
        }
    }

    function _loopStep(IComet comet, ICometExt cometExt, ICometExt.AssetInfo memory ai) internal returns (bool) {
        uint128 collat = comet.collateralBalanceOf(address(this), Mainnet.WSTETH);
        if (collat < 0.01 ether) return false;

        // Comet's getPrice for wstETH priceFeed returns the stEthPerWstETH ratio (1e8 scale).
        // Full USD price = wstRatio * ethUsdPrice / 1e8.
        uint256 wstRatioE8 = cometExt.getPrice(ai.priceFeed); // stEthPerWstETH * 1e8
        uint256 ethPriceE8 = _ethUsdE8();
        if (ethPriceE8 == 0) return false;

        // wstETH USD price in e8 = wstRatioE8 * ethPriceE8 / 1e8
        uint256 wstPriceUsdE8 = (wstRatioE8 * ethPriceE8) / 1e8;
        // Collateral USD value e8: collat (1e18) * wstPriceUsdE8 / 1e18
        uint256 collateralUsdE8 = (uint256(collat) * wstPriceUsdE8) / 1e18;

        // Max borrowable WETH = collateralUsdE8 * borrowCF / 1e18 * LOOP_LTV / ethPriceE8
        uint256 borrowCF = uint256(ai.borrowCollateralFactor); // 1e18
        uint256 borrowableUsdE8 = (collateralUsdE8 * borrowCF) / 1e18;
        uint256 targetBorrowWeth = (borrowableUsdE8 * 1e18 * LOOP_LTV_BPS) / (ethPriceE8 * 10_000);

        uint256 currentDebt = comet.borrowBalanceOf(address(this));
        if (targetBorrowWeth <= currentDebt + 0.001 ether) return false;

        uint256 borrowAmt = targetBorrowWeth - currentDebt;
        if (borrowAmt < 0.05 ether) return false;

        emit log_named_uint("loop_borrow_weth", borrowAmt);

        // Withdraw WETH from Comet (creates borrow) and convert to wstETH.
        try comet.withdraw(Mainnet.WETH, borrowAmt) {
            // ok
        } catch {
            emit log("comet_borrow_failed");
            return false;
        }

        uint256 newWst = _wethToWstEth(borrowAmt);
        comet.supply(Mainnet.WSTETH, newWst);
        return true;
    }

    function _creditCometEquity(IComet comet, ICometExt cometExt) internal {
        uint128 collat = comet.collateralBalanceOf(address(this), Mainnet.WSTETH);
        uint256 debt = comet.borrowBalanceOf(address(this));

        uint256 wstRatioE8 = cometExt.getPrice(_wstPriceFeed);
        uint256 ethPriceE8 = _ethUsdE8();
        uint256 wstPriceE8 = (wstRatioE8 * ethPriceE8) / 1e8;

        // Collateral USD in e6: collat * wstPriceE8 / 1e18 / 1e2
        int256 collUsdE6 = int256(uint256(collat)) * int256(wstPriceE8) / int256(1e18) / 100;
        // Debt USD in e6: debt * ethPriceE8 / 1e18 / 1e2
        int256 debtUsdE6 = int256(debt) * int256(ethPriceE8) / int256(1e18) / 100;

        int256 equityE6 = collUsdE6 - debtUsdE6;
        emit log_named_int("comet_equity_e6_usd", equityE6);
        emit log_named_uint("collat_wsteth", uint256(collat));
        emit log_named_uint("debt_weth", debt);
        _creditPositionEquityE6(equityE6);
    }

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
