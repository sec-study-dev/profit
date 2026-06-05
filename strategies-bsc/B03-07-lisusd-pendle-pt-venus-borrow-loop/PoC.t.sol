// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

// Interfaces referenced in commented live-call sketches:
//   IListaInteraction, IPendleRouterV4, IVenusComptroller, IVToken

/// @title B03-07 lisUSD -> Pendle PT-lisUSD lock + Venus secondary borrow
/// @notice 3-mechanism positional PoC:
///         1. Lista CDP - slisBNB collateral, mint lisUSD.
///         2. Pendle PT-lisUSD - lock the lisUSD into a fixed-yield PT
///            (buy PT-lisUSD at a discount; redeem at par on maturity).
///         3. Venus secondary borrow - use PT-lisUSD (or its sister sy/lp)
///            as off-book collateral to borrow USDT at a lower rate than
///            Lista's stability fee, recycle into more PT.
///
///         Effectively this is a fixed-rate carry trade that snaps the
///         lisUSD borrow cost (floating, set by Lista) against a fixed
///         PT yield (positive carry if PT_APY > Lista_borrow + Venus_borrow).
///
///         Real Pendle markets list PT-sUSDe and PT-slisBNB on BSC; the
///         existence of a true PT-lisUSD market is the speculative leg.
///         For the offline PoC we use a placeholder PT_LISUSD address and
///         model the fixed yield via balance accounting.
contract B03_07_LisUsdPendlePtVenusBorrowLoopTest is BSCStrategyBase {
    uint256 constant FORK_BLOCK = 42_500_000;

    /// @dev Placeholder PT-lisUSD market. // TODO verify Pendle BSC PT
    ///      registry - current Pendle BSC markets are PT-sUSDe and
    ///      PT-slisBNB; PT-lisUSD may not yet exist and would need a
    ///      Pendle market listing.
    address constant PT_LISUSD = 0x000000000000000000000000000000000000bEEF;

    /// @dev Seed slisBNB collateral.
    uint256 constant SEED_SLIS_BNB = 100 ether;
    /// @dev Target LTV on the slisBNB ilk.
    uint256 constant LTV_SLIS_BPS = 7500;
    /// @dev LTV used for the Venus PT-lisUSD-collateralised borrow (Venus
    ///      isolated pools are conservative - model 60% effective LTV).
    uint256 constant LTV_VENUS_BPS = 6000;

    /// @dev Lista slisBNB ilk stability fee.
    uint256 constant LISTA_BORROW_BPS = 250; // 2.5%
    /// @dev Pendle PT-lisUSD implied fixed APY (i.e. (1-PT_price)/T).
    uint256 constant PT_APY_BPS = 1100; // 11%
    /// @dev Venus USDT borrow APR (isolated pool variant).
    uint256 constant VENUS_BORROW_BPS = 400; // 4%

    /// @dev Holding period - typical Pendle PT maturity bucket.
    uint256 constant HOLD_DAYS = 90;

    uint256 public lisUsdMinted;
    uint256 public ptBought;
    uint256 public venusBorrowed;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.USDT);
        // PT-lisUSD itself is not tracked - its price isn't in the oracle
        // map, so we surface PnL through lisUSD/USDT legs only.
    }

    function testStrategy_B03_07() public {
        _fund(BSC.slisBNB, address(this), SEED_SLIS_BNB);

        _startPnL();

        // ===== Mechanism 1: Lista CDP =====
        //
        //   IERC20(BSC.slisBNB).approve(BSC.LISTA_INTERACTION, SEED_SLIS_BNB);
        //   IListaInteraction(BSC.LISTA_INTERACTION).deposit(
        //       address(this), BSC.slisBNB, SEED_SLIS_BNB
        //   );
        //   IListaInteraction(BSC.LISTA_INTERACTION).borrow(BSC.slisBNB, lisUsdMinted);
        //
        // Offline: lock slisBNB, mint lisUSD.
        IERC20(BSC.slisBNB).transfer(address(0xCAFE), SEED_SLIS_BNB);
        uint256 collatUsd = SEED_SLIS_BNB * 600;
        lisUsdMinted = (collatUsd * LTV_SLIS_BPS) / 10_000;
        _fund(BSC.lisUSD, address(this), lisUsdMinted);

        // ===== Mechanism 2: Pendle - buy PT-lisUSD =====
        //
        //   IERC20(BSC.lisUSD).approve(BSC.PENDLE_ROUTER_V4, lisUsdMinted);
        //   IPendleRouterV4(BSC.PENDLE_ROUTER_V4).swapExactTokenForPt({
        //       receiver: address(this),
        //       market: PENDLE_LISUSD_MARKET,
        //       minPtOut: 0,
        //       guessPtOut: PendleApproxParams(...),
        //       input: TokenInput({tokenIn: BSC.lisUSD, netTokenIn: lisUsdMinted, ...}),
        //       limit: LimitOrderData(...)
        //   });
        //
        // Offline: burn lisUSD, mint placeholder PT representing the locked
        // fixed-rate position. PT entry price = par - (PT_APY x T/365),
        // i.e. PT_amount > lisUSD_paid in nominal units.
        IERC20(BSC.lisUSD).transfer(address(0xdEaD), lisUsdMinted);
        // PT discount factor (T = HOLD_DAYS until maturity):
        //   PT_in = lisUsdMinted / (1 - PT_APY x T/365)
        uint256 discountBps = (PT_APY_BPS * HOLD_DAYS) / 365;
        ptBought = (lisUsdMinted * 10_000) / (10_000 - discountBps);
        _fund(PT_LISUSD, address(this), ptBought);

        // ===== Mechanism 3: Venus - borrow USDT against PT-lisUSD =====
        //
        //   IERC20(PT_LISUSD).approve(VENUS_VPT_LISUSD, ptBought);
        //   IVToken(VENUS_VPT_LISUSD).mint(ptBought);
        //   address[] memory mkts = new address[](1);
        //   mkts[0] = VENUS_VPT_LISUSD;
        //   IVenusComptroller(BSC.VENUS_COMPTROLLER).enterMarkets(mkts);
        //   IVToken(BSC.vUSDT).borrow(venusBorrowed);
        //
        // Offline: model the borrow against the PT collateral. PT par
        // value at maturity = ptBought x $1 = same nominal; usable
        // collateral = ptBought x LTV_VENUS_BPS.
        venusBorrowed = (ptBought * LTV_VENUS_BPS) / 10_000;
        _fund(BSC.USDT, address(this), venusBorrowed);

        // ---- Recycle: USDT -> lisUSD -> additional PT-lisUSD ----
        //
        // Single secondary loop only - we don't recurse, to keep the
        // accounting closed-form. PCS swap fee 1 bp.
        IERC20(BSC.USDT).transfer(address(0xdEaD), venusBorrowed);
        uint256 secondaryLisUsd = (venusBorrowed * (10_000 - 1)) / 10_000;
        _fund(BSC.lisUSD, address(this), secondaryLisUsd);

        IERC20(BSC.lisUSD).transfer(address(0xdEaD), secondaryLisUsd);
        uint256 secondaryPt = (secondaryLisUsd * 10_000) / (10_000 - discountBps);
        _fund(PT_LISUSD, address(this), secondaryPt);

        // ---- Carry over HOLD_DAYS ----
        //
        // PT yield: at maturity PT redeems 1:1 lisUSD; the gain over the
        // hold = ptBought x discountBps + secondaryPt x discountBps
        // measured against the *par* redemption.
        uint256 ptUsd = (ptBought + secondaryPt); // par value at maturity
        // We just minted the par-quantity PT, so the realised gain is
        // (par - paid). For accounting fidelity we instead skip ahead
        // and fund lisUSD = par redemption now (treat maturity as `t1`).
        IERC20(PT_LISUSD).transfer(address(0xdEaD), ptBought + secondaryPt);
        _fund(BSC.lisUSD, address(this), ptUsd);

        // Lista stability fee on the original lisUSD borrow.
        uint256 listaCostUsd =
            (lisUsdMinted * LISTA_BORROW_BPS * HOLD_DAYS) / (10_000 * 365);
        // Venus borrow cost.
        uint256 venusCostUsd =
            (venusBorrowed * VENUS_BORROW_BPS * HOLD_DAYS) / (10_000 * 365);
        // Realise debt-side costs by burning lisUSD.
        uint256 totalCostUsd = listaCostUsd + venusCostUsd;
        if (totalCostUsd > 0) {
            uint256 bal = IERC20(BSC.lisUSD).balanceOf(address(this));
            uint256 burn = totalCostUsd > bal ? bal : totalCostUsd;
            IERC20(BSC.lisUSD).transfer(address(0xdEaD), burn);
        }

        _endPnL("B03-07: lisUSD + Pendle PT + Venus borrow");
    }
}
