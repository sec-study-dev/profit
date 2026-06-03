// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ISDAI} from "src/interfaces/stable/ISDAI.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";

/// @title F10-03 Spark DAI borrow + sDAI / Aave aDAI rate arb
/// @notice Reads on-chain DAI rates from Spark borrow, Aave V3 supply and
///         sDAI (via `convertToAssets` drift), then opens a small 50% LTV
///         position to capture whichever leg is profitable. Designed as an
///         observational PoC - emits rate snapshots even when the carry is
///         negative.
///
///         Note: at block 19_500_000, USDC has LTV=0 on Spark. WETH has LTV=82%,
///         so we use WETH as collateral to borrow DAI.
contract F10_03_SparkDaiAaveRateArb is StrategyBase {
    uint256 constant FORK_BLOCK = 19_500_000;

    uint256 constant RATE_MODE_VARIABLE = 2;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.SDAI);
    }

    function testStrategy_F10_03() public {
        // Use WETH as collateral - USDC has LTV=0 on Spark at this block.
        // 1000 ETH at ~$3500 = ~$3.5M collateral, borrow ~$1.4M DAI at 40% LTV.
        uint256 principalWeth = 1_000 ether;
        _fund(Mainnet.WETH, address(this), principalWeth);

        _startPnL();

        IAavePool spark = IAavePool(Mainnet.SPARK_POOL);
        IAavePool aave = IAavePool(Mainnet.AAVE_V3_POOL);
        ISDAI sdai = ISDAI(Mainnet.SDAI);

        // ---- 1. Read rates ----
        // Aave/Spark stores rates in RAY (1e27) per second-equivalent (actually
        // per-year RAY). Log raw - interpretation is annual APR scaled by 1e27.
        IAavePool.ReserveDataLegacy memory sparkDai = spark.getReserveData(Mainnet.DAI);
        IAavePool.ReserveDataLegacy memory aaveDai = aave.getReserveData(Mainnet.DAI);
        IAavePool.ReserveDataLegacy memory sparkWeth = spark.getReserveData(Mainnet.WETH);

        emit log_named_uint("spark_dai_borrow_apr_ray", sparkDai.currentVariableBorrowRate);
        emit log_named_uint("aave_dai_supply_apr_ray", aaveDai.currentLiquidityRate);
        emit log_named_uint("spark_weth_supply_apr_ray", sparkWeth.currentLiquidityRate);

        // sDAI: probe drift over a single warp window to surface effective DSR.
        uint256 oneDaiInShares = sdai.convertToShares(1e18);
        emit log_named_uint("sdai_shares_per_dai_pre", oneDaiInShares);

        // Heuristic: if Spark borrow rate < Aave supply rate, the carry-via-Aave
        // leg is in profit. Log a flag for Wave 3 sweeps.
        bool aaveLegProfitable = aaveDai.currentLiquidityRate > sparkDai.currentVariableBorrowRate;
        emit log_named_uint(
            "aave_leg_profitable_flag",
            aaveLegProfitable ? uint256(1) : uint256(0)
        );

        // ---- 2. Supply WETH to Spark (LTV=82% at this block). ----
        IERC20(Mainnet.WETH).approve(address(spark), type(uint256).max);
        spark.supply(Mainnet.WETH, principalWeth, address(this), 0);

        // ---- 3. Borrow DAI at conservative 40% LTV ----
        // 40% of ~$3.5M WETH collateral ~ $1.4M DAI; cap by actual `availableBorrowsBase`.
        (, , uint256 availableBase, , , ) = spark.getUserAccountData(address(this));
        // availableBase is 1e8 USD; DAI is 18-dec, 1 DAI ~ 1 USD.
        // Cap borrow at 40% of available headroom.
        uint256 capDai = (availableBase * 1e10 * 4000) / 10_000;
        uint256 borrowDai = 500_000e18;
        if (borrowDai > capDai) borrowDai = capDai;
        if (borrowDai == 0) {
            emit log("borrow_cap_zero: insufficient collateral value");
            _endPnL("F10-03: Spark borrow + sDAI/aDAI three-way arb (skipped)");
            return;
        }

        spark.borrow(Mainnet.DAI, borrowDai, RATE_MODE_VARIABLE, 0, address(this));
        uint256 daiOnHand = IERC20(Mainnet.DAI).balanceOf(address(this));
        emit log_named_uint("dai_borrowed", daiOnHand);

        // ---- 4. Split: half -> Aave aDAI, half -> sDAI, retain 1 DAI for touch. ----
        uint256 retainForTouch = 2; // 2 wei DAI, will be split into the two touches.
        uint256 deployable = daiOnHand - retainForTouch;
        uint256 halfDai = deployable / 2;

        // Aave leg
        IERC20(Mainnet.DAI).approve(address(aave), type(uint256).max);
        aave.supply(Mainnet.DAI, halfDai, address(this), 0);

        // sDAI leg
        IERC20(Mainnet.DAI).approve(address(sdai), type(uint256).max);
        uint256 sdaiOut = sdai.deposit(deployable - halfDai, address(this));
        emit log_named_uint("sdai_minted", sdaiOut);

        // ---- 5. Warp 30 days ----
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));

        // Touch each reserve to crystallise indices.
        deal(Mainnet.WETH, address(this), 1);
        IERC20(Mainnet.WETH).approve(address(spark), 1);
        spark.supply(Mainnet.WETH, 1, address(this), 0);
        deal(Mainnet.DAI, address(this), 1);
        aave.supply(Mainnet.DAI, 1, address(this), 0);

        // ---- 6. Post-warp rate readout ----
        uint256 oneDaiInSharesPost = sdai.convertToShares(1e18);
        emit log_named_uint("sdai_shares_per_dai_post", oneDaiInSharesPost);

        (uint256 collBase, uint256 debtBase, , , , uint256 hf) =
            spark.getUserAccountData(address(this));
        emit log_named_uint("spark_collateral_base_e8_usd", collBase);
        emit log_named_uint("spark_debt_base_e8_usd", debtBase);
        emit log_named_int(
            "spark_equity_base_e8_usd_signed",
            int256(collBase) - int256(debtBase)
        );
        emit log_named_uint("spark_hf_e18", hf);

        // Aave aDAI balance - read the aTokenAddress from reserve data and
        // call balanceOf on it.
        address aDaiToken = aaveDai.aTokenAddress;
        uint256 aDaiBal = IERC20(aDaiToken).balanceOf(address(this));
        emit log_named_uint("adai_balance", aDaiBal);

        _endPnL("F10-03: Spark borrow + sDAI/aDAI three-way arb");
    }
}
