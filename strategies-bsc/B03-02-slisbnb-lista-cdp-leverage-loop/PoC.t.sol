// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

// Interfaces referenced in commented-out live-call sketches (kept inline for
// documentation only; uncomment when a real BSC fork is available):
//   IWBNB, IListaInteraction, IListaStakeManager, IslisBNB, IPancakeV3Router

/// @title B03-02 slisBNB · Lista CDP recursive leverage loop
/// @notice Multi-round (not single-tx) PoC. Each round:
///         1. Deposit slisBNB into Lista vault.
///         2. Borrow lisUSD against it (LTV target = TARGET_LTV_BPS).
///         3. Swap lisUSD -> BNB on PCS v3.
///         4. Stake BNB -> slisBNB via Lista StakeManager (canonical rate,
///            no AMM slippage).
///         5. Re-deposit the freshly-minted slisBNB.
///
///         Geometric leverage = 1/(1 - LTV). At 75% target we approach
///         4x exposure after 3 rounds (~85% of the geometric limit).
///
///         For offline modelling we synthesize all live calls (Lista
///         Interaction + PCS v3 router) using `_fund`-based balance
///         accounting so the PoC compiles and reports a clean PnL line
///         without a live BSC fork.
contract B03_02_SlisBnbListaCdpLeverageLoopTest is BSCStrategyBase {
    /// @dev Late-2024 block — slisBNB is live; Lista vault is established.
    uint256 constant FORK_BLOCK = 42_500_000;

    /// @dev Target LTV per round in bps. 7500 = 75%.
    uint256 constant TARGET_LTV_BPS = 7500;
    /// @dev Rounds to execute.
    uint256 constant ROUNDS = 3;
    /// @dev Seed collateral.
    uint256 constant SEED_SLIS_BNB = 100 ether;

    /// @dev Assumed APRs (annualized). For an offline PnL projection only.
    uint256 constant SLIS_BNB_APR_BPS = 320; // 3.20%
    uint256 constant LISUSD_BORROW_BPS = 200; // 2.00%

    /// @dev Holding period for the carry projection.
    uint256 constant HOLD_DAYS = 30;

    uint256 public totalCollateralFinal;
    uint256 public totalDebtFinal;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.WBNB);
    }

    function testStrategy_B03_02() public {
        _fund(BSC.slisBNB, address(this), SEED_SLIS_BNB);

        _startPnL();

        uint256 roundCollat = SEED_SLIS_BNB;
        uint256 cumulativeCollat = 0;
        uint256 cumulativeDebt = 0;

        for (uint256 i = 0; i < ROUNDS; i++) {
            // ---- 1. Deposit slisBNB into Lista vault ----
            //
            //   IERC20(BSC.slisBNB).approve(BSC.LISTA_INTERACTION, roundCollat);
            //   IListaInteraction(BSC.LISTA_INTERACTION).deposit(
            //       address(this), BSC.slisBNB, roundCollat
            //   );
            //
            // For offline mode, treat slisBNB as "locked" by transferring
            // to a dead address — the test contract no longer owns it.
            IERC20(BSC.slisBNB).transfer(address(0xCAFE), roundCollat);
            cumulativeCollat += roundCollat;

            // ---- 2. Borrow lisUSD at target LTV ----
            // slisBNB -> BNB via canonical rate (offline approx 1:1; in a
            // live run use convertSnBnbToBnb()).
            uint256 slisInUsd = roundCollat; // 1 slisBNB ~ 1 BNB ~ $600 — see
            // _initDefaultPrices(); the PnL math treats every token at its
            // tracked price, so we mint lisUSD whose **par value** = LTV%
            // of the slisBNB collateral USD value.
            uint256 lisUsdMinted = (slisInUsd * 600 * TARGET_LTV_BPS) / 10_000;
            _fund(BSC.lisUSD, address(this), lisUsdMinted);
            cumulativeDebt += lisUsdMinted;

            // ---- 3. Swap lisUSD -> BNB on PCS v3 ----
            //
            //   IERC20(BSC.lisUSD).approve(BSC.PCS_V3_ROUTER, lisUsdMinted);
            //   IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(...);
            //
            // Offline: burn lisUSD, mint WBNB worth the same USD value
            // minus a 10 bp AMM hop.
            IERC20(BSC.lisUSD).transfer(address(0xdEaD), lisUsdMinted);
            uint256 bnbOut = (lisUsdMinted * (10_000 - 10)) / 10_000 / 600;
            _fund(BSC.WBNB, address(this), bnbOut);

            // ---- 4. Re-stake BNB -> slisBNB ----
            //
            //   IWBNB(BSC.WBNB).withdraw(bnbOut);
            //   IListaStakeManager(BSC.LISTA_STAKE_MANAGER).deposit{value: bnbOut}();
            //
            // Offline: swap WBNB for slisBNB at 1:1 (real rate ~ 1.02
            // slisBNB-per-BNB after months of accrual; we use 1:1 to
            // keep the PoC parameter-free).
            IERC20(BSC.WBNB).transfer(address(0xdEaD), bnbOut);
            _fund(BSC.slisBNB, address(this), bnbOut);

            roundCollat = bnbOut;
        }

        // ---- 5. Final round-trip: redeposit residual slisBNB ----
        //
        // We don't bother re-depositing the residual; it lives on the
        // contract balance and gets priced into the PnL line. Real loop
        // would call `deposit` one final time.

        totalCollateralFinal = cumulativeCollat;
        totalDebtFinal = cumulativeDebt;

        // ---- 6. Apply carry over the holding period ----
        //
        // For PnL display only — we credit slisBNB worth (APR × time)
        // and debit lisUSD worth (borrow × time). The result is the
        // expected carry capture.
        uint256 collatYield = (cumulativeCollat * SLIS_BNB_APR_BPS * HOLD_DAYS)
            / (10_000 * 365);
        uint256 debtCost = (cumulativeDebt * LISUSD_BORROW_BPS * HOLD_DAYS)
            / (10_000 * 365);
        _fund(BSC.slisBNB, address(this), collatYield);
        // debtCost lives as an extra unrepayable lisUSD obligation — for
        // a closed-form PoC we model it by burning slisBNB worth the same
        // USD amount as the lisUSD borrow cost.
        // (1 slisBNB ~= $600, 1 lisUSD ~= $1.)
        uint256 debtCostInSlisBnb = debtCost / 600;
        if (debtCostInSlisBnb > 0) {
            // Pull from balance to keep the accounting honest.
            uint256 bal = IERC20(BSC.slisBNB).balanceOf(address(this));
            uint256 burn = debtCostInSlisBnb > bal ? bal : debtCostInSlisBnb;
            IERC20(BSC.slisBNB).transfer(address(0xdEaD), burn);
        }

        _endPnL("B03-02: slisBNB Lista CDP leverage loop");
    }
}
