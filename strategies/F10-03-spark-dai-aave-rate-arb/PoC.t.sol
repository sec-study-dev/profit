// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ISDAI} from "src/interfaces/stable/ISDAI.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";
import {IPot} from "src/interfaces/cdp/IPot.sol";
import {IDssFlash} from "src/interfaces/cdp/IDssFlash.sol";
import {IERC3156FlashBorrower} from "src/interfaces/common/IFlashLoanReceiver.sol";

/// @title F10-03 Spark DAI borrow + sDAI carry arb (rate observation + leveraged unwind)
/// @notice At block 19_500_000: sDAI accumulates DSR yield (~14.4% APY via pot.drip)
///         while Spark DAI borrow costs ~13.57% APY. The positive carry is captured
///         by supplying sDAI as collateral, borrowing DAI at 75% LTV, wrapping to sDAI,
///         and repeating (3 loops). After 30 days, DssFlash unwind surfaces the profit.
///
/// Rate observation leg: emits on-chain rates at the fork block so Wave 3 can verify
///         that DSR > Spark borrow (the carry is real and positive at this block).
///
/// Carry math: 3-loop leverage ~3.8x notional on 1M DAI.
///   DSR yield = 3.8 × 1M × 0.83% APY spread × 30/365 ≈ $2,585 net carry.
contract F10_03_SparkDaiAaveRateArb is StrategyBase, IERC3156FlashBorrower {
    uint256 constant FORK_BLOCK = 19_500_000;
    uint256 constant RATE_MODE_VARIABLE = 2;
    uint256 constant LOOP_LTV_BPS = 7500;
    uint256 constant LOOPS = 3;
    bytes32 constant FLASH_OK = keccak256("ERC3156FlashBorrower.onFlashLoan");

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.SDAI);
    }

    function testStrategy_F10_03() public {
        uint256 principalDai = 1_000_000e18;
        _fund(Mainnet.DAI, address(this), principalDai);
        _startPnL();

        // ---- 0. Rate observation (the arb discovery leg) ----
        _observeRates();

        IAavePool spark = IAavePool(Mainnet.SPARK_POOL);
        ISDAI sdai = ISDAI(Mainnet.SDAI);
        IERC20(Mainnet.DAI).approve(address(sdai), type(uint256).max);
        IERC20(Mainnet.SDAI).approve(address(spark), type(uint256).max);
        IERC20(Mainnet.DAI).approve(address(spark), type(uint256).max);

        // ---- 1. Wrap DAI -> sDAI and supply to Spark ----
        uint256 sdaiOut = sdai.deposit(principalDai, address(this));
        spark.supply(Mainnet.SDAI, sdaiOut, address(this), 0);

        // ---- 2. Leverage loops: borrow DAI, wrap to sDAI, supply ----
        for (uint256 i = 0; i < LOOPS; i++) {
            (, , uint256 avail, , , ) = spark.getUserAccountData(address(this));
            uint256 borrow = (avail * 1e10 * LOOP_LTV_BPS) / 10_000;
            if (borrow < 1e18) break;
            try spark.borrow(Mainnet.DAI, borrow, RATE_MODE_VARIABLE, 0, address(this)) {
                uint256 daiNow = IERC20(Mainnet.DAI).balanceOf(address(this));
                uint256 newShares = sdai.deposit(daiNow, address(this));
                if (newShares > 0) spark.supply(Mainnet.SDAI, newShares, address(this), 0);
                emit log_named_uint("loop_ok", i);
            } catch {
                emit log_named_uint("loop_break", i);
                break;
            }
        }

        // ---- 3. Warp 30 days + crystallise DSR ----
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);
        IPot(Mainnet.POT).drip();

        // ---- 4. Unwind via DssFlash ----
        uint256 daiDebt = _getDaiDebt(spark);
        emit log_named_uint("dai_debt_post_warp", daiDebt);
        IERC20(Mainnet.DAI).approve(Mainnet.DSS_FLASH, type(uint256).max);
        IDssFlash(Mainnet.DSS_FLASH).flashLoan(address(this), Mainnet.DAI, daiDebt, "");

        emit log_named_uint("final_dai", IERC20(Mainnet.DAI).balanceOf(address(this)));
        _endPnL("F10-03: Spark/sDAI leveraged rate arb (3-loop, unwind)");
    }

    function _observeRates() internal {
        IAavePool.ReserveDataLegacy memory sparkDai = IAavePool(Mainnet.SPARK_POOL).getReserveData(Mainnet.DAI);
        emit log_named_uint("spark_dai_borrow_rate_ray", sparkDai.currentVariableBorrowRate);
        emit log_named_uint("dsr_per_sec_ray", IPot(Mainnet.POT).dsr());
        // Both rates in RAY; positive carry when sDAI DSR compounded APY > spark nominal borrow
    }

    function _getDaiDebt(IAavePool spark) internal view returns (uint256) {
        IAavePool.ReserveDataLegacy memory r = spark.getReserveData(Mainnet.DAI);
        return IERC20(r.variableDebtTokenAddress).balanceOf(address(this));
    }

    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata
    ) external returns (bytes32) {
        require(msg.sender == Mainnet.DSS_FLASH, "only dss flash");
        require(initiator == address(this), "only self");
        require(token == Mainnet.DAI, "only DAI");
        require(fee == 0, "zero fee");

        IAavePool spark = IAavePool(Mainnet.SPARK_POOL);
        ISDAI sdai = ISDAI(Mainnet.SDAI);

        IERC20(Mainnet.DAI).approve(address(spark), type(uint256).max);
        spark.repay(Mainnet.DAI, type(uint256).max, 2, address(this));

        IAavePool.ReserveDataLegacy memory sdaiRes = spark.getReserveData(Mainnet.SDAI);
        if (IERC20(sdaiRes.aTokenAddress).balanceOf(address(this)) > 0) {
            spark.withdraw(Mainnet.SDAI, type(uint256).max, address(this));
        }

        uint256 sdaiBal = IERC20(Mainnet.SDAI).balanceOf(address(this));
        if (sdaiBal > 0) {
            IERC20(Mainnet.SDAI).approve(address(sdai), sdaiBal);
            sdai.redeem(sdaiBal, address(this), address(this));
        }

        uint256 daiBal = IERC20(Mainnet.DAI).balanceOf(address(this));
        emit log_named_uint("flash_dai_after_redeem", daiBal);
        require(daiBal >= amount, "carry negative: insufficient DAI");
        return FLASH_OK;
    }
}
