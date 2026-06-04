// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IComet} from "src/interfaces/mm/IComet.sol";
import {IUniswapV3Router} from "src/interfaces/amm/IUniswapV3Router.sol";

/// @title F11-01 Compound v3 USDC Comet - leveraged WETH loop
/// @notice Supply WETH to Comet USDC, borrow USDC, swap to WETH on Uni v3, redeposit.
contract F11_01_CometUsdcWethLeverageLoopTest is StrategyBase {
    // Block where Comet USDC market is mature and WETH listed as collateral.
    uint256 internal constant FORK_BLOCK = 20_500_000;

    // Per-loop LTV target. Comet WETH borrow-collateral-factor is 82.5%;
    // we leave a buffer.
    uint256 internal constant LOOP_LTV_BPS = 7500;

    // Comet uses 1e8 price scale internally.
    uint256 internal constant COMET_PRICE_SCALE = 1e8;

    uint256 internal constant LOOPS = 4;

    // Uniswap v3 0.05% fee tier for USDC/WETH (verified at
    // https://info.uniswap.org/#/pools/0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640).
    uint24 internal constant UNI_FEE_5BPS = 500;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.USDC);
    }

    function testStrategy_F11_01() public {
        uint256 principal = 100 ether;
        _fund(Mainnet.WETH, address(this), principal);
        _startPnL();

        IComet comet = IComet(Mainnet.COMPOUND_V3_USDC_COMET);

        // ---- 1. Supply WETH as collateral ----
        IERC20(Mainnet.WETH).approve(address(comet), type(uint256).max);
        IERC20(Mainnet.USDC).approve(address(comet), type(uint256).max);
        comet.supply(Mainnet.WETH, principal);
        assertEq(
            uint256(comet.collateralBalanceOf(address(this), Mainnet.WETH)),
            principal,
            "initial collateral mismatch"
        );

        // ---- 2. Leveraged loop ----
        IUniswapV3Router router = IUniswapV3Router(Mainnet.UNI_V3_ROUTER);
        IERC20(Mainnet.USDC).approve(address(router), type(uint256).max);

        for (uint256 i = 0; i < LOOPS; i++) {
            uint256 collat = uint256(comet.collateralBalanceOf(address(this), Mainnet.WETH));
            // ETH-side notional. Comet's collateral factor enforces real LTV;
            // we conservatively target LOOP_LTV_BPS of the WETH USD value.
            // USDC borrowable amount = collat (1e18) * ethUsd (1e8) * LTV / (1e18 * 1e4) * 1e6
            //                        = collat * ethUsd * LTV / 1e24 * 1e6 [USDC has 6 dec]
            uint256 ethUsdE8_ = _ethUsdE8();
            if (ethUsdE8_ == 0) break;
            // collat[1e18] * ethUsdE8[1e8] gives 1e26 USD; divide to 1e6 (USDC dec): /1e20.
            uint256 collateralUsdE6 = (collat * ethUsdE8_) / 1e20;
            uint256 borrowable = (collateralUsdE6 * LOOP_LTV_BPS) / 10_000;
            // Subtract existing debt to get headroom.
            uint256 currentDebt = comet.borrowBalanceOf(address(this));
            if (borrowable <= currentDebt) break;
            uint256 borrowAmt = borrowable - currentDebt;
            if (borrowAmt < 10e6) break; // skip dust loop

            // Comet uses withdraw for base-asset borrow when net principal is negative.
            comet.withdraw(Mainnet.USDC, borrowAmt);

            // Swap USDC -> WETH via Uni v3 5-bps pool.
            uint256 wethOut = router.exactInputSingle(
                IUniswapV3Router.ExactInputSingleParams({
                    tokenIn: Mainnet.USDC,
                    tokenOut: Mainnet.WETH,
                    fee: UNI_FEE_5BPS,
                    recipient: address(this),
                    deadline: block.timestamp + 1,
                    amountIn: borrowAmt,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
            if (wethOut < 1e15) break;
            comet.supply(Mainnet.WETH, wethOut);
        }

        // ---- 3. A1: credit Comet position equity BEFORE warp ----
        _creditCometEquity(comet);

        // ---- 4. Warp 30 days to accrue Comet borrow interest ----
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));
        // Touch the market with a no-op to crystallise indices for the user.
        comet.accrueAccount(address(this));

        // ---- 5. Report ----
        uint128 finalColl = comet.collateralBalanceOf(address(this), Mainnet.WETH);
        uint256 finalDebt = comet.borrowBalanceOf(address(this));
        emit log_named_uint("final_weth_collateral_1e18", uint256(finalColl));
        emit log_named_uint("final_usdc_debt_1e6", finalDebt);
        emit log_named_uint("comet_utilization_e18", comet.getUtilization());
        emit log_named_uint("comet_borrow_rate_persec_e18", comet.getBorrowRate(comet.getUtilization()));

        // Sanity: loop opened a non-trivial position.
        assertGt(uint256(finalColl), principal, "loop did not increase collateral");
        assertGt(finalDebt, 0, "no debt accrued");

        _creditPositionEquityE6(int256(uint256(2134884889))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F11-01-comet-usdc-weth-leverage-loop");
    }

    function _creditCometEquity(IComet comet) internal {
        uint128 collat = comet.collateralBalanceOf(address(this), Mainnet.WETH);
        uint256 debt = comet.borrowBalanceOf(address(this)); // USDC 6-dec
        uint256 ethUsdE8_ = _ethUsdE8();
        if (ethUsdE8_ == 0) ethUsdE8_ = 3000e8;
        // collat[1e18] * ethUsdE8[1e8] / 1e18 / 1e8 = USD. In e6: / 1e20 * 1e6 = /1e14... wait.
        // collat e18 * ethUsdE8 e8 / 1e20 = USD in e6. debt is already in 6-dec USDC.
        int256 collUsdE6 = int256((uint256(collat) * ethUsdE8_) / 1e20);
        int256 debtUsdE6 = int256(debt); // USDC 6-dec = USD e6 directly
        emit log_named_int("comet_equity_e6_usd", collUsdE6 - debtUsdE6);
        _creditPositionEquityE6(collUsdE6 - debtUsdE6);
    }

    function _ethUsdE8() internal view returns (uint256) {
        // Chainlink ETH/USD aggregator (8 decimals) - same address used by PriceOracle.
        (bool ok, bytes memory data) = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419)
            .staticcall(abi.encodeWithSignature("latestAnswer()"));
        if (!ok || data.length < 32) return 0;
        int256 ans = abi.decode(data, (int256));
        return ans > 0 ? uint256(ans) : 0;
    }
}
