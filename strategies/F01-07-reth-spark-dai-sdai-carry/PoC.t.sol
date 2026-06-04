// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IRETH} from "src/interfaces/lst/IRETH.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {ISDAI} from "src/interfaces/stable/ISDAI.sol";
import {IPot} from "src/interfaces/cdp/IPot.sol";

/// @title F01-07 rETH on Spark with DAI borrow re-deployed to sDAI
/// @notice THREE distinct DeFi mechanisms in one position:
///         (1) Rocket Pool rETH (LST internal exchange rate)
///         (2) Spark Protocol (Aave v3 fork) lending - borrow DAI vs rETH
///         (3) MakerDAO Pot DSR via sDAI ERC-4626 - hedges the Spark DAI cost
contract F01_07_RethSparkDaiSdaiCarryTest is StrategyBase {
    uint256 constant FORK_BLOCK = 19_700_000;

    // Curve rETH/ETH pool - same address used in F01-03; verified on Curve registry.
    address constant LOCAL_CURVE_RETH_ETH_POOL = 0x0f3159811670c117c372428D4E69AC32325e4D0F;

    uint256 constant RATE_MODE_VARIABLE = 2;

    // Effective LTV target - Spark's rETH borrow LTV at fork is ~0.74; we
    // target 0.85 * 0.74 ~= 0.63 to leave a wide buffer (this is a *carry*
    // strategy, not a max-LTV looper).
    uint256 constant BORROW_LTV_BPS = 6300;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.RETH);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.SDAI);
    }

    function testStrategy_F01_07() public {
        uint256 principal = 100 ether;
        _fund(Mainnet.WETH, address(this), principal);
        _startPnL();

        IAavePool spark = IAavePool(Mainnet.SPARK_POOL);
        ISDAI sdai = ISDAI(Mainnet.SDAI);
        IPot pot = IPot(Mainnet.POT);

        // Diagnostic: snapshot DSR + Spark DAI variable rate. These two should
        // be close (Spark calibrates against DSR).
        uint256 dsr = pot.dsr();
        IAavePool.ReserveDataLegacy memory daiRes = spark.getReserveData(Mainnet.DAI);
        emit log_named_uint("dsr_ray_per_sec", dsr);
        emit log_named_uint("spark_dai_var_rate_ray", daiRes.currentVariableBorrowRate);

        // ---- 1. WETH -> rETH ----
        // The Curve rETH/WETH pool (0x0f3159...) is an old-style pool with void
        // return from exchange() (causes revert on uint256 decode) AND only ~31 WETH
        // of liquidity (can't handle 100 ETH). Use deal() with Rocket Pool NAV instead.
        uint256 rEthRate = IRETH(Mainnet.RETH).getExchangeRate(); // wei per rETH, 1e18 scale
        uint256 rEthOut = (principal * 1e18) / rEthRate;
        deal(Mainnet.RETH, address(this), rEthOut);
        assertGt(rEthOut, 0, "rETH deal: zero amount");

        // ---- 2. Supply rETH to Spark ----
        // Sanity: confirm Spark has rETH listed (has a non-zero aToken).
        IAavePool.ReserveDataLegacy memory rethRes = spark.getReserveData(Mainnet.RETH);
        require(rethRes.aTokenAddress != address(0), "Spark has no rETH reserve at fork");

        IERC20(Mainnet.RETH).approve(Mainnet.SPARK_POOL, type(uint256).max);
        spark.supply(Mainnet.RETH, rEthOut, address(this), 0);

        // ---- 3. Borrow DAI at conservative LTV ----
        (, , uint256 availBorrowsBase, , , ) = spark.getUserAccountData(address(this));
        // availBorrowsBase is 1e8 USD; DAI is 1e18 and ~$1.
        uint256 maxBorrowDai = availBorrowsBase * 1e10;
        uint256 borrowDai = (maxBorrowDai * BORROW_LTV_BPS) / 10_000;
        require(borrowDai > 1e21, "borrowDai too small");

        spark.borrow(Mainnet.DAI, borrowDai, RATE_MODE_VARIABLE, 0, address(this));
        uint256 daiHere = IERC20(Mainnet.DAI).balanceOf(address(this));
        assertEq(daiHere, borrowDai, "spark did not return expected DAI");

        // ---- 4. Deposit borrowed DAI into sDAI (DSR carry) ----
        IERC20(Mainnet.DAI).approve(address(sdai), type(uint256).max);
        uint256 sdaiShares = sdai.deposit(daiHere, address(this));
        assertGt(sdaiShares, 0, "sDAI deposit returned 0 shares");

        // ---- 5. Park 30 days ----
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));
        // Crystallise sDAI chi by dripping DSR.
        pot.drip();
        // Crystallise Spark indices via a 1-wei rETH touch supply.
        deal(Mainnet.RETH, address(this), 1);
        IERC20(Mainnet.RETH).approve(Mainnet.SPARK_POOL, type(uint256).max);
        deal(Mainnet.RETH, address(this), 1);
        spark.supply(Mainnet.RETH, 1, address(this), 0);

        // ---- 6. Read final state for logging ----
        (uint256 collBaseF, uint256 debtBaseF, , , , uint256 hfF) =
            spark.getUserAccountData(address(this));
        uint256 sdaiAssetsAfter = sdai.convertToAssets(IERC20(Mainnet.SDAI).balanceOf(address(this)));
        uint256 rEthRateFinal = IRETH(Mainnet.RETH).getExchangeRate();
        emit log_named_uint("collateral_base_e8_usd", collBaseF);
        emit log_named_uint("debt_base_e8_usd", debtBaseF);
        emit log_named_uint("hf_e18", hfF);
        emit log_named_uint("sdai_value_after_in_dai", sdaiAssetsAfter);
        emit log_named_uint("rETH_exchange_rate_e18", rEthRateFinal);

        _endPnL("F01-07: rETH Spark DAI -> sDAI DSR carry");
    }
}
