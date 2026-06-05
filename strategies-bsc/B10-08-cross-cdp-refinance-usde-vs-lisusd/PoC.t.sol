// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @title B10-08 Cross-CDP refinance - USDe short-term borrow vs lisUSD long-term debt
/// @notice A user already holds an open Lista lisUSD CDP (long-dated debt at
///         a stickily high stability fee). Venus, meanwhile, lists USDe as a
///         supply / borrow market at an instantaneous IRM rate that
///         frequently dips below the Lista SF for short windows (USDe
///         supply spikes from Ethena cash-and-carry funding).
///
///         B10-08 *refinances* a slice of the Lista debt by:
///         1. depositing slisBNB into Venus as Venus-side collateral,
///         2. borrowing USDe on Venus at the (cheap) Venus rate,
///         3. swapping USDe -> lisUSD via PCS StableSwap,
///         4. paying down the Lista lisUSD debt by the swapped notional.
///
///         The position is held while `Venus_USDe_borrow_rate < Lista_SF`,
///         and unwound (with a symmetric reverse trade) when the spread
///         crosses.
///
/// Mechanism stack (3 distinct):
///  1. Lista CDP - `payback(slisBNB, lisUSD)` against an existing debt.
///  2. Venus borrow - slisBNB collateral, USDe debt (separate
///     market / different rate than VAI mint).
///  3. PCS StableSwap - USDe -> lisUSD bridge so the Venus debt can be
///     applied as Lista debt reduction.
contract B10_08_CrossCdpRefinanceUsdeVsLisusdTest is BSCStrategyBase {
    /// @dev TODO: pin a block where Venus USDe borrow APR < Lista SF by >= 100 bp.
    uint256 internal constant FORK_BLOCK = 48_400_000;

    /// @dev User's outstanding Lista debt (lisUSD, 18d).
    uint256 internal constant LISTA_DEBT = 800_000 * 1e18;
    /// @dev Slice of that debt we refinance via Venus this period.
    uint256 internal constant REFINANCE_SLICE = 400_000 * 1e18;

    /// @dev slisBNB collateral the user deposits on Venus to back the USDe
    ///      borrow (denominated 1e18, valued at $600 in the test oracle).
    uint256 internal constant SLISBNB_COLLATERAL = 1_500 * 1e18;

    /// @dev Hold horizon in days.
    uint256 internal constant HOLD_DAYS = 21;

    /// @dev Annualised funding rates (bps).
    uint256 internal constant LISTA_SF_BPS = 720;          // 7.2 % APR
    uint256 internal constant VENUS_USDE_BORROW_BPS = 480; // 4.8 % APR

    /// @dev Per-edge fees in offline mode (bps).
    uint256 internal constant PCS_STABLE_FEE_BPS = 4;
    uint256 internal constant LISTA_PAYBACK_FEE_BPS = 0;   // Lista has no payback fee

    /// @dev Mock isolated market for USDe on Venus (selector promotion TODO).
    address internal constant LOCAL_VUSDE = 0x000000000000000000000000000000000000baBe;

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.USDe);
        _trackToken(BSC.slisBNB);
    }

    function testStrategy_B10_08() public {
        if (!_haveFork) {
            _offlinePnLCheck();
            return;
        }
        // On-fork branch requires the Venus USDe market (vUSDe) to be live.
        // Until that is canonicalised in BSC.sol, defer to offline accounting.
        _offlinePnLCheck();
    }

    // ---- Offline accounting ----------------------------------------------

    /// @dev Carry over `HOLD_DAYS` of:
    ///  - paying Venus USDe borrow rate on `REFINANCE_SLICE` instead of
    ///    Lista SF on the same slice, AND
    ///  - taking the round-trip PCS swap drag at entry + exit.
    function _offlinePnLCheck() internal {
        // The user starts already holding LISTA_DEBT worth of lisUSD (i.e.
        // they have minted lisUSD against slisBNB on Lista). For PnL
        // accounting we treat the lisUSD on hand as the position value.
        _fund(BSC.lisUSD, address(this), LISTA_DEBT);
        _fund(BSC.slisBNB, address(this), SLISBNB_COLLATERAL);
        _startPnL();

        // --- Step 1: Venus deposit slisBNB + borrow USDe -----------------
        // Model the Venus borrow as a USDe credit.
        uint256 venusBorrowUsde = REFINANCE_SLICE; // 1:1 by $-value (par stables)
        _fund(BSC.USDe, address(this), venusBorrowUsde);

        // --- Step 2: USDe -> lisUSD via PCS StableSwap -------------------
        uint256 lisFromSwap = (venusBorrowUsde * (10_000 - PCS_STABLE_FEE_BPS)) / 10_000;
        // Model: burn USDe, mint lisUSD.
        IERC20(BSC.USDe).transfer(address(0xdead), venusBorrowUsde);
        _fund(BSC.lisUSD, address(this), IERC20(BSC.lisUSD).balanceOf(address(this)) + lisFromSwap);

        // --- Step 3: Pay down Lista lisUSD debt by `lisFromSwap` ---------
        // The user's wallet lisUSD doesn't decrease (Lista CDP "absorbs" the
        // payback by reducing debt liability, not their hand). For accounting
        // we model the debt reduction as off-balance - credit `lisFromSwap`
        // as future interest avoided.
        uint256 listaPaybackFee =
            (lisFromSwap * LISTA_PAYBACK_FEE_BPS) / 10_000;
        IERC20(BSC.lisUSD).transfer(address(0xdead), lisFromSwap + listaPaybackFee);

        // --- Step 4: Hold for HOLD_DAYS ---------------------------------
        // Funding spread saved on REFINANCE_SLICE:
        //   (LISTA_SF - VENUS_USDe_borrow) x HOLD_DAYS / 365.
        uint256 spreadBps = LISTA_SF_BPS > VENUS_USDE_BORROW_BPS
            ? LISTA_SF_BPS - VENUS_USDE_BORROW_BPS : 0;
        uint256 fundingSaved =
            (REFINANCE_SLICE * spreadBps * HOLD_DAYS) / (10_000 * 365);
        emit log_named_uint("spread_bps", spreadBps);
        emit log_named_uint("funding_saved", fundingSaved);

        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
        vm.roll(block.number + (HOLD_DAYS * 1 days) / 3);

        // --- Step 5: Unwind. Re-borrow lisUSD on Lista, swap to USDe, ---
        // repay Venus USDe borrow.
        // (a) Mint lisUSD against the same slisBNB on Lista. For accounting
        //     we credit lisUSD back at par minus a tiny Lista mint fee
        //     (modeled as zero - Lista typically has no mint fee, just SF).
        _fund(BSC.lisUSD, address(this), IERC20(BSC.lisUSD).balanceOf(address(this)) + REFINANCE_SLICE);

        // (b) Swap lisUSD -> USDe via PCS Stable.
        uint256 usdeForRepay = (REFINANCE_SLICE * (10_000 - PCS_STABLE_FEE_BPS)) / 10_000;
        IERC20(BSC.lisUSD).transfer(address(0xdead), REFINANCE_SLICE);
        _fund(BSC.USDe, address(this), usdeForRepay);

        // (c) Repay Venus USDe debt - debt = principal + accrued cost.
        uint256 venusCost =
            (venusBorrowUsde * VENUS_USDE_BORROW_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 venusOwed = venusBorrowUsde + venusCost;
        // If the swap yielded less USDe than owed, we cover the gap with a
        // top-up swap (cost = top-up x stable fee).
        int256 usdeShortfall = int256(venusOwed) - int256(usdeForRepay);
        IERC20(BSC.USDe).transfer(address(0xdead), usdeForRepay);
        if (usdeShortfall > 0) {
            // Top-up: pay lisUSD for the shortfall at PCS rate (slippage 4 bp).
            uint256 lisCost =
                (uint256(usdeShortfall) * (10_000 + PCS_STABLE_FEE_BPS)) / 10_000;
            IERC20(BSC.lisUSD).transfer(address(0xdead), lisCost);
        }

        // (d) Credit the funding saved onto the lisUSD leg (it shows up as
        //     reduced Lista interest liability, equivalent to a lisUSD gain).
        _fund(BSC.lisUSD, address(this), IERC20(BSC.lisUSD).balanceOf(address(this)) + fundingSaved);

        _endPnL("B10-08[offline]: cross-CDP refinance USDe vs lisUSD");
    }
}
