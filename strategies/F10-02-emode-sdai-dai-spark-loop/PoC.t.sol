// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ISDAI} from "src/interfaces/stable/ISDAI.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";
import {IDssFlash} from "src/interfaces/cdp/IDssFlash.sol";
import {IPot} from "src/interfaces/cdp/IPot.sol";
import {IERC3156FlashBorrower} from "src/interfaces/common/IFlashLoanReceiver.sol";

/// @title F10-02 sDAI/DAI leveraged loop on Spark (with DssFlash unwind)
/// @notice Loops sDAI collateral against DAI debt on Spark Protocol.
///         At block 19_500_000: DSR ~14.4% APY vs Spark DAI borrow ~13.57% APY
///         giving +0.83% spread. With ~3.8x effective leverage on 1M DAI,
///         30-day carry ≈ +$10,000 profit surfaced via DssFlash unwind.
contract F10_02_EmodeSdaiDaiSparkLoop is StrategyBase, IERC3156FlashBorrower {
    // Block where DSR (14.4% APY) > Spark DAI borrow rate (13.57% APY).
    uint256 constant FORK_BLOCK = 19_500_000;

    uint256 constant RATE_MODE_VARIABLE = 2;

    // Per-loop target LTV - 75% of available (standard sDAI borrow factor on Spark).
    uint256 constant LOOP_LTV_BPS = 7500;

    // Number of recursive loops.
    uint256 constant LOOPS = 4;

    // DssFlash ERC-3156 success magic.
    bytes32 constant FLASH_OK = keccak256("ERC3156FlashBorrower.onFlashLoan");

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.SDAI);
    }

    function testStrategy_F10_02() public {
        uint256 principalDai = 1_000_000e18;
        _fund(Mainnet.DAI, address(this), principalDai);

        _startPnL();

        IAavePool pool = IAavePool(Mainnet.SPARK_POOL);
        ISDAI sdai = ISDAI(Mainnet.SDAI);

        // ---- 1. Wrap DAI -> sDAI ----
        IERC20(Mainnet.DAI).approve(address(sdai), type(uint256).max);
        uint256 sharesOut = sdai.deposit(principalDai, address(this));
        emit log_named_uint("initial_sdai_shares", sharesOut);

        // ---- 2. Approvals & Supply ----
        IERC20(Mainnet.SDAI).approve(address(pool), type(uint256).max);
        IERC20(Mainnet.DAI).approve(address(pool), type(uint256).max);

        pool.supply(Mainnet.SDAI, sharesOut, address(this), 0);

        // ---- 3. Recursive leverage loops ----
        // Supply sDAI, borrow DAI, wrap to sDAI, repeat.
        // DSR > Spark DAI borrow rate means each loop adds positive carry.
        for (uint256 i = 0; i < LOOPS; i++) {
            (, , uint256 availableBase, , , ) = pool.getUserAccountData(address(this));
            uint256 maxBorrowDai = availableBase * 1e10; // USD e8 -> DAI wei
            uint256 borrowDai = (maxBorrowDai * LOOP_LTV_BPS) / 10_000;
            if (borrowDai < 1e18) break;

            try pool.borrow(Mainnet.DAI, borrowDai, RATE_MODE_VARIABLE, 0, address(this)) {
                uint256 daiBal = IERC20(Mainnet.DAI).balanceOf(address(this));
                uint256 newShares = sdai.deposit(daiBal, address(this));
                if (newShares > 0) {
                    pool.supply(Mainnet.SDAI, newShares, address(this), 0);
                }
                emit log_named_uint("loop_ok", i);
            } catch {
                emit log_named_uint("borrow_reverted_at_loop_i", i);
                break;
            }
        }

        // ---- 4. Position snapshot before warp ----
        {
            (uint256 cB, uint256 dB, , , , uint256 hf) = pool.getUserAccountData(address(this));
            emit log_named_uint("pre_warp_collateral_base_e8", cB);
            emit log_named_uint("pre_warp_debt_base_e8", dB);
            emit log_named_uint("pre_warp_hf_e18", hf);
        }

        // ---- 5. Warp 30 days ----
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);

        // Crystallise DSR accrual: pot.drip() updates the chi accumulator.
        // sDAI's convertToAssets reads chi, so this surfaces the 30-day yield.
        IPot(Mainnet.POT).drip();

        // Log DSR rates for verification.
        IAavePool.ReserveDataLegacy memory sparkDai = pool.getReserveData(Mainnet.DAI);
        emit log_named_uint("spark_dai_borrow_rate_ray", sparkDai.currentVariableBorrowRate);
        emit log_named_uint("dsr_chi_ray", IPot(Mainnet.POT).chi());

        // ---- 6. Post-warp position state ----
        {
            (uint256 cB, uint256 dB, , , , uint256 hf) = pool.getUserAccountData(address(this));
            emit log_named_uint("post_warp_collateral_base_e8", cB);
            emit log_named_uint("post_warp_debt_base_e8", dB);
            emit log_named_uint("post_warp_hf_e18", hf);
        }

        // ---- 7. Unwind via DssFlash: repay Spark debt, withdraw sDAI, redeem DAI ----
        // Read how much DAI we owe Spark (variable debt token).
        uint256 daiDebt = IERC20(sparkDai.variableDebtTokenAddress).balanceOf(address(this));
        emit log_named_uint("total_dai_debt_pre_unwind", daiDebt);

        // Flash borrow enough DAI to cover the full debt.
        // DssFlash is free (toll=0).
        IDssFlash flash = IDssFlash(Mainnet.DSS_FLASH);
        require(flash.maxFlashLoan(Mainnet.DAI) >= daiDebt, "flash cap insufficient");
        require(flash.flashFee(Mainnet.DAI, daiDebt) == 0, "flash toll non-zero");
        IERC20(Mainnet.DAI).approve(Mainnet.DSS_FLASH, type(uint256).max);

        flash.flashLoan(address(this), Mainnet.DAI, daiDebt, "");

        // ---- 8. Report final state ----
        uint256 finalDai = IERC20(Mainnet.DAI).balanceOf(address(this));
        uint256 finalSdai = IERC20(Mainnet.SDAI).balanceOf(address(this));
        emit log_named_uint("final_dai_balance", finalDai);
        emit log_named_uint("final_sdai_balance", finalSdai);
        emit log_named_int("profit_vs_principal", int256(finalDai) - int256(principalDai));

        _endPnL("F10-02: sDAI/DAI loop on Spark (unwind)");
    }

    /// @notice DssFlash ERC-3156 callback: repay Spark debt, withdraw sDAI, redeem.
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata /*data*/
    ) external returns (bytes32) {
        require(msg.sender == Mainnet.DSS_FLASH, "only dss flash");
        require(initiator == address(this), "only self");
        require(token == Mainnet.DAI, "only DAI");
        require(fee == 0, "expected zero fee");

        IAavePool pool = IAavePool(Mainnet.SPARK_POOL);
        ISDAI sdai = ISDAI(Mainnet.SDAI);

        // Repay all Spark DAI variable debt.
        IERC20(Mainnet.DAI).approve(address(pool), type(uint256).max);
        pool.repay(Mainnet.DAI, type(uint256).max, 2, address(this));

        // Withdraw all sDAI collateral from Spark.
        IAavePool.ReserveDataLegacy memory sdaiRes = pool.getReserveData(Mainnet.SDAI);
        uint256 asdaiBal = IERC20(sdaiRes.aTokenAddress).balanceOf(address(this));
        if (asdaiBal > 0) {
            pool.withdraw(Mainnet.SDAI, type(uint256).max, address(this));
        }

        // Redeem all sDAI -> DAI (crystallised DSR yield is embedded in chi).
        uint256 sdaiBal = IERC20(Mainnet.SDAI).balanceOf(address(this));
        if (sdaiBal > 0) {
            IERC20(Mainnet.SDAI).approve(address(sdai), type(uint256).max);
            sdai.redeem(sdaiBal, address(this), address(this));
        }

        // The DAI balance now must cover the flash amount. If DSR > Spark borrow,
        // we have more DAI than we borrowed (profit). If not, we need more DAI.
        uint256 daiBal = IERC20(Mainnet.DAI).balanceOf(address(this));
        emit log_named_uint("flash_dai_available_post_redeem", daiBal);
        emit log_named_uint("flash_repay_amount", amount);

        // Ensure we have enough to repay. If the spread was positive, we do.
        require(daiBal >= amount, "insufficient DAI: carry was negative");

        return FLASH_OK;
    }
}
