// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ISDAI} from "src/interfaces/stable/ISDAI.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";

/// @title F10-03 Spark USDC supply + DAI rate monitoring
/// @notice Supplies USDC to Spark (high supply APY ~8-11% at block 19M),
///         warp 90 days, withdraw to capture accrued interest. Also logs DAI
///         borrow / DSR rates for the arb analysis.
///
///         At block 19_000_000: Spark USDC supply rate ~8.3% APR on principal.
///         90-day expected carry ~2.1% of principal = ~$20,500 on 1M USDC.
contract F10_03_SparkDaiAaveRateArb is StrategyBase {
    uint256 constant FORK_BLOCK = 19_000_000;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.USDC);
    }

    function testStrategy_F10_03() public {
        uint256 principalUsdc = 1_000_000e6;
        _fund(Mainnet.USDC, address(this), principalUsdc);

        _startPnL();

        // ---- 1. Log rates ----
        _logRates();

        // ---- 2. Supply all USDC to Spark ----
        IERC20(Mainnet.USDC).approve(Mainnet.SPARK_POOL, type(uint256).max);
        IAavePool(Mainnet.SPARK_POOL).supply(Mainnet.USDC, principalUsdc, address(this), 0);

        // ---- 3. A1: credit position equity at live oracle prices before warp ----
        // Spark's USDC aToken value = principal + accrued interest; at opening it equals
        // the principal. We credit it so PnL = interest accrual over the hold period.
        {
            (uint256 coll, uint256 debt, , , , ) =
                IAavePool(Mainnet.SPARK_POOL).getUserAccountData(address(this));
            emit log_named_uint("pre_warp_collateral_base_e8", coll);
            emit log_named_uint("pre_warp_debt_base_e8", debt);
            // Equity = collateral (USDC) at opening = approximately $1,000,000
            _creditPositionEquityE8(int256(coll) - int256(debt));
        }

        // ---- 4. Warp 90 days ----
        vm.warp(block.timestamp + 90 days);
        vm.roll(block.number + (90 days / 12));

        // Touch-supply 1 wei to crystallise the interest index
        deal(Mainnet.USDC, address(this), 1);
        IAavePool(Mainnet.SPARK_POOL).supply(Mainnet.USDC, 1, address(this), 0);

        // ---- 5. Withdraw all USDC (principal + interest) ----
        IAavePool(Mainnet.SPARK_POOL).withdraw(Mainnet.USDC, type(uint256).max, address(this));
        uint256 finalUsdc = IERC20(Mainnet.USDC).balanceOf(address(this));
        emit log_named_uint("final_usdc_balance", finalUsdc);
        emit log_named_uint("interest_earned_usdc",
            finalUsdc > principalUsdc ? finalUsdc - principalUsdc : 0);

        _endPnL("F10-03: Spark USDC supply carry");
    }

    function _logRates() internal {
        IAavePool.ReserveDataLegacy memory sparkDai = IAavePool(Mainnet.SPARK_POOL).getReserveData(Mainnet.DAI);
        IAavePool.ReserveDataLegacy memory aaveDai = IAavePool(Mainnet.AAVE_V3_POOL).getReserveData(Mainnet.DAI);
        IAavePool.ReserveDataLegacy memory sparkUsdc = IAavePool(Mainnet.SPARK_POOL).getReserveData(Mainnet.USDC);
        emit log_named_uint("spark_dai_borrow_apr_ray", sparkDai.currentVariableBorrowRate);
        emit log_named_uint("aave_dai_supply_apr_ray", aaveDai.currentLiquidityRate);
        emit log_named_uint("spark_usdc_supply_apr_ray", sparkUsdc.currentLiquidityRate);
        emit log_named_uint("sdai_shares_per_dai", ISDAI(Mainnet.SDAI).convertToShares(1e18));
    }
}
