// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

// Interfaces referenced in commented live-call sketches:
//   IListaInteraction, IListaStakeManager, IPancakeV3Router,
//   IVenusComptroller, IVToken, IWBNB

/// @title B03-08 slisBNB → Lista mint lisUSD → Venus borrow BNB → recursive restake
/// @notice 3-mechanism recursive PoC. Each round stacks:
///         1. **Lista CDP** — slisBNB collateral mints lisUSD.
///         2. **PCS v3 swap** — lisUSD → WBNB (intermediate liquidity hop).
///         3. **Venus borrow** — same WBNB also re-collateralised on Venus
///            to borrow *more* BNB (independent debt market), which is
///            re-staked to slisBNB.
///
///         The key innovation vs. B03-02 (single-mechanism Lista loop):
///         here Lista is *the lisUSD funding leg*, while Venus is *the BNB
///         leverage leg*. The two debt markets are uncorrelated (Lista
///         underwrites against lisUSD bad debt, Venus against pool
///         utilisation), so the operator effectively double-uses each
///         dollar of slisBNB collateral.
///
///         The recursion is bounded — each round borrows on a tighter
///         marginal LTV, so we converge geometrically.
contract B03_08_SlisBnbListaMintVenusBnbRecursiveTest is BSCStrategyBase {
    uint256 constant FORK_BLOCK = 42_500_000;

    /// @dev Seed slisBNB collateral.
    uint256 constant SEED_SLIS_BNB = 100 ether;

    /// @dev Per-round Lista LTV (slisBNB ilk).
    uint256 constant LISTA_LTV_BPS = 7500; // 75%
    /// @dev Per-round Venus LTV on WBNB collateral.
    uint256 constant VENUS_LTV_BPS = 7000; // 70%
    /// @dev How many rounds to recurse.
    uint256 constant ROUNDS = 3;

    /// @dev slisBNB intrinsic APR.
    uint256 constant SLIS_APR_BPS = 320; // 3.2%
    /// @dev Lista stability fee.
    uint256 constant LISTA_BORROW_BPS = 250; // 2.5%
    /// @dev Venus BNB borrow APR (vBNB).
    uint256 constant VENUS_BORROW_BPS = 350; // 3.5%
    /// @dev Holding period (positional carry).
    uint256 constant HOLD_DAYS = 30;

    uint256 public totalCollateralSlisBnb;
    uint256 public totalLisUsdDebt;
    uint256 public totalBnbDebt;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.WBNB);
        _trackToken(BSC.USDT);
    }

    function testStrategy_B03_08() public {
        _fund(BSC.slisBNB, address(this), SEED_SLIS_BNB);

        _startPnL();

        uint256 roundSlisBnb = SEED_SLIS_BNB;

        for (uint256 i = 0; i < ROUNDS; i++) {
            // ===== Mechanism 1: Lista CDP — deposit slisBNB, mint lisUSD ====
            //
            //   IERC20(BSC.slisBNB).approve(BSC.LISTA_INTERACTION, roundSlisBnb);
            //   IListaInteraction(BSC.LISTA_INTERACTION).deposit(
            //       address(this), BSC.slisBNB, roundSlisBnb
            //   );
            //   uint256 mint = roundSlisBnb * 600e18 / 1e18 * LISTA_LTV_BPS / 10_000;
            //   IListaInteraction(BSC.LISTA_INTERACTION).borrow(BSC.slisBNB, mint);
            //
            // Offline: lock slisBNB, mint lisUSD.
            IERC20(BSC.slisBNB).transfer(address(0xCAFE), roundSlisBnb);
            totalCollateralSlisBnb += roundSlisBnb;
            uint256 collatUsd = roundSlisBnb * 600; // $/slisBNB
            uint256 mintLisUsd = (collatUsd * LISTA_LTV_BPS) / 10_000;
            _fund(BSC.lisUSD, address(this), mintLisUsd);
            totalLisUsdDebt += mintLisUsd;

            // ---- Bridge: lisUSD -> WBNB via PCS v3 (5 bp hop) ----
            //
            //   IERC20(BSC.lisUSD).approve(BSC.PCS_V3_ROUTER, mintLisUsd);
            //   IPancakeV3Router(...).exactInputSingle({
            //       tokenIn: lisUSD, tokenOut: WBNB, fee: 500, ...
            //   });
            IERC20(BSC.lisUSD).transfer(address(0xdEaD), mintLisUsd);
            // 1 lisUSD = $1; 1 WBNB = $600; minus 5 bp.
            uint256 wbnbFromLisUsd = (mintLisUsd * (10_000 - 5)) / 10_000 / 600;
            _fund(BSC.WBNB, address(this), wbnbFromLisUsd);

            // ===== Mechanism 2: Venus — collateralise WBNB, borrow more BNB ===
            //
            //   IWBNB(BSC.WBNB).withdraw(wbnbFromLisUsd);
            //   IVToken(BSC.vBNB).mint{value: wbnbFromLisUsd}();
            //   address[] memory mkts = new address[](1);
            //   mkts[0] = BSC.vBNB;
            //   IVenusComptroller(BSC.VENUS_COMPTROLLER).enterMarkets(mkts);
            //   IVToken(BSC.vBNB).borrow(venusBnbBorrow);
            //
            // Offline: deposit WBNB into Venus (lock), borrow at LTV.
            IERC20(BSC.WBNB).transfer(address(0xCAFE), wbnbFromLisUsd);
            uint256 venusBorrowBnb = (wbnbFromLisUsd * VENUS_LTV_BPS) / 10_000;
            _fund(BSC.WBNB, address(this), venusBorrowBnb);
            totalBnbDebt += venusBorrowBnb;

            // ===== Mechanism 3: Lista StakeManager — restake BNB -> slisBNB ====
            //
            //   IWBNB(BSC.WBNB).withdraw(venusBorrowBnb);
            //   IListaStakeManager(BSC.LISTA_STAKE_MANAGER).deposit{value: venusBorrowBnb}();
            //
            // Offline: 1:1 swap (real rate ~1/exchangeRate, ~0.98 slisBNB
            // per BNB after months of accrual).
            IERC20(BSC.WBNB).transfer(address(0xdEaD), venusBorrowBnb);
            uint256 newSlisBnb = venusBorrowBnb; // 1:1 PoC simplification
            _fund(BSC.slisBNB, address(this), newSlisBnb);

            // Next round uses the freshly-minted slisBNB.
            roundSlisBnb = newSlisBnb;
        }

        // ---- Carry over HOLD_DAYS ----
        //
        // Intrinsic slisBNB APR on the full stacked collateral.
        uint256 slisYieldUsd =
            (totalCollateralSlisBnb * 600 * SLIS_APR_BPS * HOLD_DAYS) /
            (10_000 * 365);
        // Lista stability fee on the lisUSD debt.
        uint256 listaCostUsd =
            (totalLisUsdDebt * LISTA_BORROW_BPS * HOLD_DAYS) / (10_000 * 365);
        // Venus borrow cost on the BNB debt (per-BNB).
        uint256 venusCostUsd =
            (totalBnbDebt * 600 * VENUS_BORROW_BPS * HOLD_DAYS) /
            (10_000 * 365);

        int256 netUsd = int256(slisYieldUsd) - int256(listaCostUsd + venusCostUsd);
        if (netUsd > 0) {
            _fund(BSC.lisUSD, address(this), uint256(netUsd));
        } else if (netUsd < 0) {
            uint256 loss = uint256(-netUsd);
            uint256 bal = IERC20(BSC.lisUSD).balanceOf(address(this));
            uint256 burn = loss > bal ? bal : loss;
            IERC20(BSC.lisUSD).transfer(address(0xdEaD), burn);
        }

        _endPnL("B03-08: slisBNB-Lista-Venus recursive restake");
    }
}
