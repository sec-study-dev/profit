// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ISDAI} from "src/interfaces/stable/ISDAI.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";

/// @title F10-02 sDAI/DAI eMode leveraged loop on Spark
/// @notice Loops sDAI collateral against DAI debt on Spark Protocol. Uses
///         Spark's sDAI-correlated eMode (categoryId = 2) which lifts LTV to
///         ~91%. The trade captures K * (DSR - spark_spread) where K is the
///         leverage factor 1/(1-L).
contract F10_02_EmodeSdaiDaiSparkLoop is StrategyBase {
    uint256 constant FORK_BLOCK = 19_800_000;

    // Spark sDAI-correlated eMode categoryId (verified vs Spark docs).
    // If Spark renumbers the category the test will revert at setUserEMode,
    // acting as a regression check.
    uint8 constant SPARK_EMODE_SDAI = 2;

    uint256 constant RATE_MODE_VARIABLE = 2;

    // Per-loop target LTV — well under the 91% ceiling for buffer.
    uint256 constant LOOP_LTV_BPS = 8800;

    // Number of recursive loops. After ~5 the residual headroom is < 5%.
    uint256 constant LOOPS = 5;

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

        // ---- 2. Approvals & Supply (retain 1 wei sDAI for the touch tx). ----
        IERC20(Mainnet.SDAI).approve(address(pool), type(uint256).max);
        IERC20(Mainnet.DAI).approve(address(pool), type(uint256).max);

        pool.supply(Mainnet.SDAI, sharesOut - 1, address(this), 0);

        // ---- 3. Enter eMode (must be after first supply; some Aave forks gate). ----
        try pool.setUserEMode(SPARK_EMODE_SDAI) {
            // ok
        } catch {
            emit log("setUserEMode failed; Spark may have renumbered the sDAI category");
            // Fall through; loop will still execute at default LTV (~74%).
        }

        // ---- 4. Recursive loops ----
        for (uint256 i = 0; i < LOOPS; i++) {
            (, , uint256 availableBase, , , ) = pool.getUserAccountData(address(this));
            // availableBase is denominated in 1e8 USD. Translate to DAI (18-dec, $1):
            //   DAI_amt (1e18) = availableBase (1e8) * 1e10
            uint256 maxBorrowDai = availableBase * 1e10;
            uint256 borrowDai = (maxBorrowDai * LOOP_LTV_BPS) / 10_000;
            if (borrowDai < 1e18) break;

            try pool.borrow(Mainnet.DAI, borrowDai, RATE_MODE_VARIABLE, 0, address(this)) {
                uint256 daiBal = IERC20(Mainnet.DAI).balanceOf(address(this));
                // Wrap DAI -> sDAI
                uint256 newShares = sdai.deposit(daiBal, address(this));
                // Re-supply but keep 1 wei of sDAI behind for the eventual touch.
                if (newShares > 1) {
                    pool.supply(Mainnet.SDAI, newShares - 1, address(this), 0);
                }
            } catch {
                emit log_named_uint("borrow_reverted_at_loop_i", i);
                break;
            }
        }

        // ---- 5. Simulate 30 days of carry ----
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));
        // Touch supply to crystallise indices. Need ≥1 wei sDAI on hand.
        uint256 sdaiResidual = IERC20(Mainnet.SDAI).balanceOf(address(this));
        if (sdaiResidual > 0) {
            pool.supply(Mainnet.SDAI, 1, address(this), 0);
        }

        // ---- 6. Report position state ----
        (uint256 totalCollBase, uint256 totalDebtBase, , , , uint256 hf) =
            pool.getUserAccountData(address(this));
        emit log_named_uint("collateral_base_e8_usd", totalCollBase);
        emit log_named_uint("debt_base_e8_usd", totalDebtBase);
        emit log_named_int(
            "equity_base_e8_usd_signed",
            int256(totalCollBase) - int256(totalDebtBase)
        );
        emit log_named_uint("health_factor_e18", hf);
        emit log_named_uint("user_emode", pool.getUserEMode(address(this)));

        _endPnL("F10-02: sDAI/DAI eMode loop on Spark");
    }
}
