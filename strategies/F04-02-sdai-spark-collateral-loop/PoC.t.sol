// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ISDAI} from "src/interfaces/stable/ISDAI.sol";
import {IPot} from "src/interfaces/cdp/IPot.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";

/// @title F04-02 sDAI Spark collateral loop
/// @notice Loops sDAI as Spark collateral, borrowing DAI and re-staking.
contract F04_02_SDaiSparkLoop is StrategyBase {
    uint256 internal constant FORK_BLOCK = 19_500_000;
    uint256 internal constant SEED_DAI = 200_000e18;
    uint256 internal constant ITERATIONS = 5;
    // Fraction of available-borrow capacity to use each loop (1e18 scale).
    uint256 internal constant SAFE_FRAC = 0.85e18;
    uint256 internal constant WARP_SECONDS = 30 days;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.SDAI);
        _setEthUsdFallback(3_900e8);
    }

    function test_sdaiSparkLoop() public {
        IPot pot = IPot(Mainnet.POT);
        ISDAI sdai = ISDAI(Mainnet.SDAI);
        IAavePool spark = IAavePool(Mainnet.SPARK_POOL);

        // Sanity: read DSR and Spark DAI borrow rate, sanity-log spread.
        uint256 dsr = pot.dsr();
        IAavePool.ReserveDataLegacy memory daiRes = spark.getReserveData(Mainnet.DAI);
        // currentVariableBorrowRate is in RAY per-second-equivalent ray; for
        // logging we just emit the raw values.
        emit log_named_uint("dsr (RAY/sec)", dsr);
        emit log_named_uint("spark DAI borrow rate (RAY)", daiRes.currentVariableBorrowRate);

        // ---- Fund seed DAI ----
        _fund(Mainnet.DAI, address(this), SEED_DAI);

        _startPnL();

        // ---- 1. Wrap to sDAI ----
        IERC20(Mainnet.DAI).approve(address(sdai), type(uint256).max);
        IERC20(Mainnet.SDAI).approve(Mainnet.SPARK_POOL, type(uint256).max);
        IERC20(Mainnet.DAI).approve(Mainnet.SPARK_POOL, type(uint256).max);

        sdai.deposit(SEED_DAI, address(this));
        uint256 sdaiBal = IERC20(Mainnet.SDAI).balanceOf(address(this));
        require(sdaiBal > 0, "no sDAI minted");

        // ---- 2. Supply to Spark ----
        spark.supply(Mainnet.SDAI, sdaiBal, address(this), 0);

        // ---- 3. Loop: borrow DAI -> mint sDAI -> supply ----
        for (uint256 i = 0; i < ITERATIONS; i++) {
            (, , uint256 availBorrowsBase, , , uint256 hf) =
                spark.getUserAccountData(address(this));
            if (availBorrowsBase == 0) break;
            require(hf > 1.1e18, "unhealthy");
            // availableBorrowsBase is in 8-decimal USD; convert to 18-decimal DAI
            // assuming DAI = $1 (Spark price oracle returns ~1e8 for DAI).
            // availBorrowsBase is USD-e8; SAFE_FRAC is 0.85e18.
            // borrowDai (1e18) = availE8 * 0.85e18 / 1e8 - i.e. 85% of headroom in DAI.
            uint256 borrowDai = (availBorrowsBase * SAFE_FRAC) / 1e8;
            if (borrowDai == 0) break;

            spark.borrow(Mainnet.DAI, borrowDai, 2, 0, address(this));
            uint256 daiHere = IERC20(Mainnet.DAI).balanceOf(address(this));
            sdai.deposit(daiHere, address(this));
            uint256 newSdai = IERC20(Mainnet.SDAI).balanceOf(address(this));
            spark.supply(Mainnet.SDAI, newSdai, address(this), 0);
        }

        // Read post-loop state.
        (uint256 colBase, uint256 debtBase,,,, uint256 hfFinal) =
            spark.getUserAccountData(address(this));
        emit log_named_uint("collateral_base_e8", colBase);
        emit log_named_uint("debt_base_e8", debtBase);
        emit log_named_uint("hf_final_1e18", hfFinal);

        // Effective leverage (collateral / equity); equity = collateral - debt.
        require(colBase > debtBase, "underwater");
        uint256 equityBase = colBase - debtBase;
        uint256 leverageE4 = (colBase * 1e4) / equityBase;
        emit log_named_uint("leverage_x1e4", leverageE4);
        // Expect > 2.5x with 5 iterations at 0.74 LTV * 0.85 safe frac.
        // 5-iter geometric leverage = (1 - q^5) / (1 - q) with q = 0.74*0.85 = 0.629.
        // -> ~2.59. Allow some slack from price-oracle noise.
        assertGt(leverageE4, 22_000, "leverage too low");

        // ---- 4. Warp 30 days ----
        vm.warp(block.timestamp + WARP_SECONDS);

        // Force DSR drip so sDAI chi catches up.
        pot.drip();

        // ---- 5. Unwind: repay DAI loop ----
        for (uint256 j = 0; j < ITERATIONS + 2; j++) {
            (, uint256 dBase, , , , ) = spark.getUserAccountData(address(this));
            if (dBase == 0) break;

            // Withdraw a chunk of sDAI proportional to head-room, redeem to DAI,
            // repay debt.
            (uint256 cBase, , uint256 availB, , , ) = spark.getUserAccountData(address(this));
            // We can safely withdraw cBase * (LT - HF_target/1)... simpler heuristic:
            // withdraw up to availableBorrowsBase / collateralFactor of sDAI in USD.
            uint256 withdrawUsdE8 = availB; // conservative
            if (withdrawUsdE8 == 0 && cBase > 0) {
                withdrawUsdE8 = cBase / 20; // small step
            }
            // Convert USD-e8 to sDAI shares using sdai.convertToShares on the
            // DAI-equivalent amount.
            uint256 daiEquiv = withdrawUsdE8 * 1e10; // USD8 -> 1e18 USD
            uint256 sharesNeeded = sdai.convertToShares(daiEquiv);
            if (sharesNeeded == 0) break;
            uint256 got = spark.withdraw(Mainnet.SDAI, sharesNeeded, address(this));
            uint256 daiOut = sdai.redeem(got, address(this), address(this));
            uint256 toRepay = daiOut < dBase * 1e10 ? daiOut : dBase * 1e10;
            if (toRepay == 0) break;
            spark.repay(Mainnet.DAI, toRepay, 2, address(this));
        }

        // Pull remaining sDAI collateral.
        (uint256 cBaseFinal, uint256 dBaseFinal,,,,) = spark.getUserAccountData(address(this));
        if (dBaseFinal == 0 && cBaseFinal > 0) {
            spark.withdraw(Mainnet.SDAI, type(uint256).max, address(this));
            uint256 sdaiLeft = IERC20(Mainnet.SDAI).balanceOf(address(this));
            if (sdaiLeft > 0) sdai.redeem(sdaiLeft, address(this), address(this));
        }

        _endPnL("F04-02-sdai-spark-loop");

        // Assert seed was preserved or grown (in DAI denomination).
        uint256 endDai = IERC20(Mainnet.DAI).balanceOf(address(this));
        emit log_named_uint("end_DAI", endDai);
        // Conservative bound: we should at least be within 99% of seed because
        // worst-case the spread is zero and we paid only Spark borrow/origination.
        assertGt(endDai, SEED_DAI * 99 / 100, "loop lost > 1% on flat spread");
    }
}
