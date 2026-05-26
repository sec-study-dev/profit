// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ISUSDS} from "src/interfaces/stable/ISUSDS.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";

/// @notice Sky DaiUsds wrapper interface (zero-fee 1:1 DAI<->USDS).
/// @dev Mainnet address: 0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A
interface IDaiUsds {
    function daiToUsds(address usr, uint256 wad) external;
    function usdsToDai(address usr, uint256 wad) external;
}

/// @title F04-03 sUSDS loop on Spark using Sky Savings Rate spread
contract F04_03_SUsdsSparkLoop is StrategyBase {
    address internal constant DAI_USDS = 0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A;

    uint256 internal constant FORK_BLOCK = 21_500_000;
    uint256 internal constant SEED_DAI = 200_000e18;
    uint256 internal constant ITERATIONS = 5;
    uint256 internal constant SAFE_FRAC = 0.85e18;
    uint256 internal constant WARP_SECONDS = 60 days;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.USDS);
        _trackToken(Mainnet.SUSDS);
        _setEthUsdFallback(3_400e8);
    }

    function test_susdsSparkLoop() public {
        ISUSDS susds = ISUSDS(Mainnet.SUSDS);
        IAavePool spark = IAavePool(Mainnet.SPARK_POOL);

        // ---- 0. Probe SSR vs Spark DAI borrow rate (logging only).
        uint256 ssr = susds.ssr();
        IAavePool.ReserveDataLegacy memory daiRes = spark.getReserveData(Mainnet.DAI);
        emit log_named_uint("ssr_RAY_per_sec", ssr);
        emit log_named_uint("spark_dai_borrow_RAY", daiRes.currentVariableBorrowRate);

        // Verify Spark accepts sUSDS as collateral at this block.
        // Historical context (verified via Sky governance forum / Spark Prime spells):
        //   * sUSDS was onboarded to SparkLend shortly after the USDS launch in
        //     Sep-2024 with LTV ~75% and a stablecoin-emode rating that lets
        //     sUSDS borrow DAI/USDC at high efficiency.
        //   * A Spark Prime delist proposal (LTV -> 0, supplyCap -> 1) was first
        //     surfaced in late 2025 - far past this FORK_BLOCK (~Dec 22 2024).
        // So at block 21_500_000 sUSDS is a live, non-frozen collateral asset.
        // We still verify on-chain rather than trust the historical claim:
        //   1. aTokenAddress != 0  -> reserve is initialised
        //   2. configuration bits 0-15  == LTV       (basis points, Aave v3 layout)
        //      configuration bits 16-31 == LIQ_THRES (basis points)
        //      We require LTV > 0 (LTV == 0 == "no borrowing against").
        IAavePool.ReserveDataLegacy memory susdsRes =
            spark.getReserveData(Mainnet.SUSDS);
        require(susdsRes.aTokenAddress != address(0), "sUSDS not listed on Spark at this block");
        uint256 ltvBips = susdsRes.configuration & 0xFFFF;
        uint256 ltBips = (susdsRes.configuration >> 16) & 0xFFFF;
        emit log_named_uint("spark_sUSDS_LTV_bps", ltvBips);
        emit log_named_uint("spark_sUSDS_LT_bps", ltBips);
        require(ltvBips > 0, "sUSDS LTV frozen to 0 -> cannot borrow against it");

        // ---- Fund seed DAI ----
        _fund(Mainnet.DAI, address(this), SEED_DAI);

        // ---- Approvals ----
        IERC20(Mainnet.DAI).approve(DAI_USDS, type(uint256).max);
        IERC20(Mainnet.USDS).approve(DAI_USDS, type(uint256).max);
        IERC20(Mainnet.USDS).approve(address(susds), type(uint256).max);
        IERC20(Mainnet.SUSDS).approve(Mainnet.SPARK_POOL, type(uint256).max);
        IERC20(Mainnet.DAI).approve(Mainnet.SPARK_POOL, type(uint256).max);

        _startPnL();

        // ---- 1. DAI -> USDS via DaiUsds wrapper ----
        IDaiUsds(DAI_USDS).daiToUsds(address(this), SEED_DAI);
        uint256 usdsBal = IERC20(Mainnet.USDS).balanceOf(address(this));
        require(usdsBal >= SEED_DAI, "wrap shortfall");

        // ---- 2. USDS -> sUSDS ----
        susds.deposit(usdsBal, address(this));
        uint256 susdsBal = IERC20(Mainnet.SUSDS).balanceOf(address(this));
        require(susdsBal > 0, "no sUSDS minted");

        // ---- 3. Supply to Spark ----
        spark.supply(Mainnet.SUSDS, susdsBal, address(this), 0);

        // ---- 4. Loop ----
        for (uint256 i = 0; i < ITERATIONS; i++) {
            (, , uint256 avail, , , uint256 hf) =
                spark.getUserAccountData(address(this));
            if (avail == 0) break;
            require(hf > 1.1e18, "unhealthy");

            uint256 borrowDai = (avail * SAFE_FRAC) / 1e8; // avail is USD-e8
            if (borrowDai == 0) break;

            spark.borrow(Mainnet.DAI, borrowDai, 2, 0, address(this));

            uint256 daiHere = IERC20(Mainnet.DAI).balanceOf(address(this));
            IDaiUsds(DAI_USDS).daiToUsds(address(this), daiHere);

            uint256 usdsHere = IERC20(Mainnet.USDS).balanceOf(address(this));
            susds.deposit(usdsHere, address(this));

            uint256 newShares = IERC20(Mainnet.SUSDS).balanceOf(address(this));
            spark.supply(Mainnet.SUSDS, newShares, address(this), 0);
        }

        // ---- 5. Inspect leverage ----
        (uint256 colBase, uint256 debtBase, , , , uint256 hfFinal) =
            spark.getUserAccountData(address(this));
        require(colBase > debtBase, "underwater");
        uint256 equityBase = colBase - debtBase;
        uint256 leverageE4 = (colBase * 1e4) / equityBase;
        emit log_named_uint("leverage_x1e4", leverageE4);
        emit log_named_uint("hf_final_1e18", hfFinal);
        // 5-iter at 0.75 * 0.85 = 0.6375 -> ~2.65x. Allow slack for oracle.
        assertGt(leverageE4, 23_000, "leverage too low");

        // ---- 6. Warp + drip ----
        vm.warp(block.timestamp + WARP_SECONDS);
        susds.drip();

        // ---- 7. Unwind ----
        for (uint256 j = 0; j < ITERATIONS + 3; j++) {
            (, uint256 dBase, , , , ) = spark.getUserAccountData(address(this));
            if (dBase == 0) break;

            (uint256 cBase, , uint256 availB, , , ) = spark.getUserAccountData(address(this));
            uint256 withdrawUsdE8 = availB;
            if (withdrawUsdE8 == 0 && cBase > 0) {
                withdrawUsdE8 = cBase / 20;
            }
            uint256 usdsEquiv = withdrawUsdE8 * 1e10;
            uint256 sharesNeeded = susds.convertToShares(usdsEquiv);
            if (sharesNeeded == 0) break;

            uint256 got = spark.withdraw(Mainnet.SUSDS, sharesNeeded, address(this));
            uint256 usdsOut = susds.redeem(got, address(this), address(this));
            // USDS -> DAI for repayment.
            IDaiUsds(DAI_USDS).usdsToDai(address(this), usdsOut);

            uint256 daiHere = IERC20(Mainnet.DAI).balanceOf(address(this));
            uint256 dBaseDai = dBase * 1e10;
            uint256 toRepay = daiHere < dBaseDai ? daiHere : dBaseDai;
            if (toRepay == 0) break;
            spark.repay(Mainnet.DAI, toRepay, 2, address(this));
        }

        // Final pull of any remaining collateral.
        (uint256 cFinal, uint256 dFinal,,,,) = spark.getUserAccountData(address(this));
        if (dFinal == 0 && cFinal > 0) {
            spark.withdraw(Mainnet.SUSDS, type(uint256).max, address(this));
            uint256 sLeft = IERC20(Mainnet.SUSDS).balanceOf(address(this));
            if (sLeft > 0) {
                susds.redeem(sLeft, address(this), address(this));
            }
        }
        uint256 usdsLeft = IERC20(Mainnet.USDS).balanceOf(address(this));
        if (usdsLeft > 0) {
            IDaiUsds(DAI_USDS).usdsToDai(address(this), usdsLeft);
        }

        _endPnL("F04-03-susds-spark-loop");

        // Seed preservation guard.
        uint256 endDai = IERC20(Mainnet.DAI).balanceOf(address(this));
        emit log_named_uint("end_DAI_total", endDai);
        // On a positive-spread block we expect strict growth; bound generously to
        // tolerate Spark IRM jitter and rounding loss on the unwind path.
        assertGt(endDai, SEED_DAI * 99 / 100, "loop lost > 1% - spread likely inverted or stuck collateral");
    }
}
