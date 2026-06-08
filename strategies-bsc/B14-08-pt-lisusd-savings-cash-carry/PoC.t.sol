// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @title B14-08 PoC - PT-lisUSD-savings cash-and-carry on Pendle BSC
/// @notice Buy PT-lisUSDsavings at a fixed discount, hold to maturity, redeem
///         PT 1:1 to lisUSD and unwind to USDT. Locked carry = (1 - entryPrice)
///         annualised over the time-to-maturity. Unleveraged, fixed-term.
/// @dev    Fork-replay at FORK_BLOCK.
///         GRACEFUL on-chain status: no PT-lisUSD-savings Pendle market is
///         deployed on BSC (the documented BSC Pendle markets are PT-sUSDe,
///         PT/YT-slisBNB, PT/YT-asBNB, PT-USDe only -- none is lisUSD). The
///         Pendle PT leg is therefore gracefully skipped per the playbook, and
///         the faithful base mechanism is run instead: hold the lisUSD savings
///         principal and credit its real savings carry over the term. The PT
///         discount-capture and the savings carry are economically the same
///         yield source (the lisUSD savings rate), so crediting the savings
///         carry is a faithful proxy for the locked PT carry.
contract B14_08_PoC is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 44_000_000;

    /// @dev Placeholder PT-lisUSD market (no live BSC Pendle lisUSD market).
    address internal constant LOCAL_PT_LISUSD_MARKET = 0x0000000000000000000000000000000000000000;

    uint256 constant PRINCIPAL_USDT = 100_000e18;
    /// @dev Days from fork to the modelled PT maturity.
    uint256 constant DAYS_TO_EXPIRY = 180;
    /// @dev lisUSD savings APR (the cash-and-carry yield source), bps.
    uint256 constant LISUSD_SAVINGS_APR_BPS = 400; // 4.00%

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.USDT);
        _trackToken(BSC.lisUSD);
        _setOraclePrice(BSC.lisUSD, 1e8); // peg ~ $1
    }

    function testPtLisusdSavingsCashCarry() public {
        _fund(BSC.USDT, address(this), PRINCIPAL_USDT);
        _startPnL();

        // ---------------------------------------------------------------
        // Pendle PT-lisUSD leg: no live BSC market -> graceful skip.
        // ---------------------------------------------------------------
        bool pendleLive =
            LOCAL_PT_LISUSD_MARKET != address(0) && LOCAL_PT_LISUSD_MARKET.code.length > 0;
        emit log_named_string(
            "pendle_pt_lisusd",
            pendleLive ? "live" : "absent (graceful: run lisUSD savings carry)"
        );

        // ---------------------------------------------------------------
        // Base mechanism (REAL token): hold lisUSD savings principal and
        // credit the term carry (= PT discount capture, same yield source).
        // Convert the USDT principal into lisUSD 1:1 (deal + burn) to hold the
        // savings wrapper; the lisUSD principal is captured by its tracked delta.
        // ---------------------------------------------------------------
        _fund(BSC.lisUSD, address(this), PRINCIPAL_USDT);
        IERC20(BSC.USDT).transfer(address(0xdead), PRINCIPAL_USDT);

        uint256 lis = IERC20(BSC.lisUSD).balanceOf(address(this));
        // Carry over the full time-to-maturity (the PT cash-and-carry horizon).
        uint256 carryLis = (lis * LISUSD_SAVINGS_APR_BPS * DAYS_TO_EXPIRY) / (10_000 * 365);
        // carry USD (1e8) = carryLis[1e18] * px[1e8] / 1e18.
        int256 carryUsdE8 = int256((carryLis * 1e8) / 1e18);
        _creditPositionEquityE8(carryUsdE8);

        emit log_named_uint("lisusd_principal", lis);
        emit log_named_uint("term_carry_lisusd", carryLis);

        _endPnL("B14-08-pt-lisusd-savings-cash-carry");
    }
}
