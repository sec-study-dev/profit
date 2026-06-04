// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ISDAI} from "src/interfaces/stable/ISDAI.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";

/// @title F10-02 sDAI/DAI leveraged loop on Spark (flash-unwind)
/// @notice Loops sDAI collateral against DAI debt on Spark Protocol.
///         Block 19_000_000: DAI variable borrow APR ~5.4% < DSR ~6.8%.
///         sDAI LTV in Spark = 74%. Loop 5x at 70% LOOP_LTV (~3.3x leverage).
///         After 90 days, uses a Spark flashloan to repay all DAI debt atomically,
///         withdraw all sDAI, redeem to DAI, repay flash. Residual DAI = profit.
///
///         Note: Spark flashLoanSimple premium = 0 (unlike Aave's 5 bp).
contract F10_02_EmodeSdaiDaiSparkLoop is StrategyBase {
    // DAI borrow ~5.38% APR, DSR ~6.77% -> +1.39% spread.
    uint256 constant FORK_BLOCK = 19_000_000;

    uint256 constant RATE_MODE_VARIABLE = 2;
    uint256 constant LOOP_LTV_BPS = 7000;
    uint256 constant LOOPS = 5;

    // Set during flash callback to avoid stack-too-deep.
    bool internal _inFlashCallback;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.SDAI);
    }

    function testStrategy_F10_02() public {
        uint256 principalDai = 1_000_000e18;
        _fund(Mainnet.DAI, address(this), principalDai);

        _startPnL();

        IERC20(Mainnet.DAI).approve(Mainnet.SDAI, type(uint256).max);
        IERC20(Mainnet.SDAI).approve(Mainnet.SPARK_POOL, type(uint256).max);
        IERC20(Mainnet.DAI).approve(Mainnet.SPARK_POOL, type(uint256).max);

        // ---- 1. Wrap DAI -> sDAI, supply to Spark ----
        uint256 sharesOut = ISDAI(Mainnet.SDAI).deposit(principalDai, address(this));
        emit log_named_uint("initial_sdai_shares", sharesOut);
        IAavePool(Mainnet.SPARK_POOL).supply(Mainnet.SDAI, sharesOut, address(this), 0);

        // ---- 2. Recursive loops ----
        for (uint256 i = 0; i < LOOPS; i++) {
            (, , uint256 avail, , , ) = IAavePool(Mainnet.SPARK_POOL).getUserAccountData(address(this));
            uint256 borrowDai = (avail * 1e10 * LOOP_LTV_BPS) / 10_000;
            if (borrowDai < 1e18) break;
            try IAavePool(Mainnet.SPARK_POOL).borrow(Mainnet.DAI, borrowDai, RATE_MODE_VARIABLE, 0, address(this)) {
                uint256 newShares = ISDAI(Mainnet.SDAI).deposit(IERC20(Mainnet.DAI).balanceOf(address(this)), address(this));
                if (newShares > 0) IAavePool(Mainnet.SPARK_POOL).supply(Mainnet.SDAI, newShares, address(this), 0);
                emit log_named_uint("loop_ok", i);
            } catch {
                emit log_named_uint("borrow_reverted_at_loop_i", i);
                break;
            }
        }

        // ---- 3. Snapshot pre-warp ----
        {
            (uint256 coll, uint256 debt, , , , uint256 hf) = IAavePool(Mainnet.SPARK_POOL).getUserAccountData(address(this));
            emit log_named_uint("pre_warp_collateral_base_e8", coll);
            emit log_named_uint("pre_warp_debt_base_e8", debt);
            emit log_named_uint("pre_warp_hf_e18", hf);
            emit log_named_uint("spark_dai_borrow_rate_ray",
                IAavePool(Mainnet.SPARK_POOL).getReserveData(Mainnet.DAI).currentVariableBorrowRate);
        }

        // ---- 4. Simulate 90 days of carry ----
        vm.warp(block.timestamp + 90 days);
        vm.roll(block.number + (90 days / 12));

        // ---- 5. Post-warp snapshot ----
        {
            (uint256 postColl, uint256 postDebt, , , , ) = IAavePool(Mainnet.SPARK_POOL).getUserAccountData(address(this));
            emit log_named_uint("post_warp_collateral_base_e8", postColl);
            emit log_named_uint("post_warp_debt_base_e8", postDebt);
        }

        // ---- 6. Flash-unwind: borrow DAI via flash, repay debt, withdraw sDAI, redeem ----
        address vDebtDai = IAavePool(Mainnet.SPARK_POOL).getReserveData(Mainnet.DAI).variableDebtTokenAddress;
        uint256 totalDaiDebt = IERC20(vDebtDai).balanceOf(address(this));
        emit log_named_uint("total_dai_debt_pre_unwind", totalDaiDebt);

        // Flash-borrow exactly the current DAI debt amount from Spark.
        // In the callback: repay debt, withdraw all sDAI, redeem to DAI, repay flash.
        IAavePool(Mainnet.SPARK_POOL).flashLoanSimple(
            address(this),
            Mainnet.DAI,
            totalDaiDebt,
            abi.encode(totalDaiDebt),
            0
        );

        emit log_named_uint("final_dai_balance", IERC20(Mainnet.DAI).balanceOf(address(this)));
        emit log_named_uint("final_sdai_balance", IERC20(Mainnet.SDAI).balanceOf(address(this)));
        uint256 finalDai = IERC20(Mainnet.DAI).balanceOf(address(this));
        emit log_named_uint("profit_vs_principal",
            finalDai > principalDai ? finalDai - principalDai : 0);

        _endPnL("F10-02: sDAI/DAI loop on Spark (unwind)");
    }

    /// @notice Spark flashLoanSimple callback. Repays all debt, withdraws + redeems sDAI.
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        require(msg.sender == Mainnet.SPARK_POOL, "only spark");
        require(initiator == address(this), "only self");
        require(asset == Mainnet.DAI, "asset");

        uint256 flashAmount = abi.decode(params, (uint256));
        require(amount == flashAmount, "amount mismatch");

        // 1. Repay all DAI debt using the flashloaned DAI
        IAavePool(Mainnet.SPARK_POOL).repay(Mainnet.DAI, type(uint256).max, RATE_MODE_VARIABLE, address(this));

        // 2. Withdraw all sDAI collateral
        address aTokenSdai = IAavePool(Mainnet.SPARK_POOL).getReserveData(Mainnet.SDAI).aTokenAddress;
        uint256 aBalance = IERC20(aTokenSdai).balanceOf(address(this));
        emit log_named_uint("flash_dai_available_post_redeem", aBalance);
        IAavePool(Mainnet.SPARK_POOL).withdraw(Mainnet.SDAI, type(uint256).max, address(this));

        // 3. Redeem all sDAI -> DAI
        uint256 sdaiBal = IERC20(Mainnet.SDAI).balanceOf(address(this));
        ISDAI(Mainnet.SDAI).redeem(sdaiBal, address(this), address(this));

        // 4. Approve Spark to pull back flashloan + premium (premium=0 for Spark)
        uint256 repayAmount = amount + premium;
        emit log_named_uint("flash_repay_amount", repayAmount);
        IERC20(Mainnet.DAI).approve(Mainnet.SPARK_POOL, repayAmount);

        return true;
    }
}
