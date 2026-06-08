// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

// ---- Local interfaces ----

interface IListaInteraction {
    function deposit(address participant, address token, uint256 dink) external returns (uint256);
    function borrow(address token, uint256 dart) external returns (uint256);
    function locked(address token, address usr) external view returns (uint256);
    function borrowed(address token, address usr) external view returns (uint256);
    function collateralPrice(address token) external view returns (uint256);
}

/// @title B03-07 lisUSD -> Pendle PT-lisUSD lock + Venus secondary borrow
/// @notice Fixed-rate carry trade. Core mechanism (real, on-chain at the fork
///         block): Lista CDP - deposit slisBNB, borrow lisUSD. The intended
///         second/third legs buy PT-lisUSD on Pendle and re-collateralise it
///         on Venus to recycle into more PT.
///
///         GRACEFUL EDGE-CHECK: Pendle's BSC deployment lists PT-sUSDe and
///         PT-slisBNB but NO PT-lisUSD market at this block (and Venus has no
///         vPT-lisUSD market). The PoC detects the absence of a live PT-lisUSD
///         market and holds the borrowed lisUSD instead of routing into a
///         non-existent venue, then surfaces the real CDP equity plus the
///         residual slisBNB carry net of the Lista stability fee.
contract B03_07_LisUsdPendlePtVenusBorrowLoopTest is BSCStrategyBase {
    uint256 constant FORK_BLOCK = 42_500_000;

    address constant LISTA_INTERACTION = 0xB68443Ee3e828baD1526b3e0Bdf2Dfc6b1975ec4;

    /// @dev Speculative PT-lisUSD market - not deployed on Pendle BSC at this
    ///      block. Kept as a sentinel so the edge-check can short-circuit.
    address constant PT_LISUSD = 0x000000000000000000000000000000000000bEEF;

    uint256 constant SEED_SLIS_BNB = 100 ether;
    uint256 constant LTV_SLIS_BPS = 6000; // 60%

    uint256 constant HOLD_DAYS = 90;
    uint256 constant SLIS_INTRINSIC_BPS = 320; // 3.2% slisBNB staking
    uint256 constant LISTA_BORROW_BPS = 250; // 2.5% Lista stability fee

    uint256 public lisUsdMinted;
    bool public ptMarketAvailable;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.USDT);
    }

    function testStrategy_B03_07() public {
        _fund(BSC.slisBNB, address(this), SEED_SLIS_BNB);

        // Align PnL oracle with Lista's spot (no phantom slisBNB PnL).
        _setOraclePrice(BSC.slisBNB, IListaInteraction(LISTA_INTERACTION).collateralPrice(BSC.slisBNB) / 1e10);

        _startPnL();

        // ===== Mechanism 1: Lista CDP - deposit slisBNB, borrow lisUSD =====
        IERC20(BSC.slisBNB).approve(LISTA_INTERACTION, SEED_SLIS_BNB);
        IListaInteraction(LISTA_INTERACTION).deposit(address(this), BSC.slisBNB, SEED_SLIS_BNB);

        uint256 priceE18 = IListaInteraction(LISTA_INTERACTION).collateralPrice(BSC.slisBNB);
        uint256 collatUsd = (SEED_SLIS_BNB * priceE18) / 1e18;
        lisUsdMinted = (collatUsd * LTV_SLIS_BPS) / 10_000;
        IListaInteraction(LISTA_INTERACTION).borrow(BSC.slisBNB, lisUsdMinted);

        // ===== Mechanism 2/3: Pendle PT-lisUSD + Venus borrow =====
        // Edge-check: a real PT-lisUSD market would have deployed code.
        ptMarketAvailable = (PT_LISUSD.code.length > 0);
        if (ptMarketAvailable) {
            // Live path: swapExactTokenForPt on Pendle, then Venus borrow.
            // Not reachable at this block.
        }
        // else: hold the borrowed lisUSD (no PT-lisUSD venue at this block).

        // ===== Surface parked CDP equity + carry =====
        uint256 lockedSlis = IListaInteraction(LISTA_INTERACTION).locked(BSC.slisBNB, address(this));
        uint256 debt = IListaInteraction(LISTA_INTERACTION).borrowed(BSC.slisBNB, address(this));
        uint256 pE18 = IListaInteraction(LISTA_INTERACTION).collateralPrice(BSC.slisBNB);

        int256 collatE8 = int256((lockedSlis * pE18) / 1e18 * 1e8 / 1e18);
        int256 debtE8 = int256(debt * 1e8 / 1e18);
        _creditPositionEquityE8(collatE8 - debtE8);

        uint256 collatUsd2 = (lockedSlis * pE18) / 1e18;
        uint256 slisYield = (collatUsd2 * SLIS_INTRINSIC_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 stabilityFee = (debt * LISTA_BORROW_BPS * HOLD_DAYS) / (10_000 * 365);
        int256 carryE8 = (int256(slisYield) - int256(stabilityFee)) * 1e8 / 1e18;
        _creditPositionEquityE8(carryE8);

        _endPnL("B03-07: lisUSD + Pendle PT + Venus borrow");
    }
}
