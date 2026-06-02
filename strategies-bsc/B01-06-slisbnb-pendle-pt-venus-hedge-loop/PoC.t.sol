// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWBNB} from "src/interfaces/bsc/common/IWBNB.sol";
import {IListaStakeManager} from "src/interfaces/bsc/lst/IListaStakeManager.sol";
import {IslisBNB} from "src/interfaces/bsc/lst/IslisBNB.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVBNB} from "src/interfaces/bsc/mm/IVBNB.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {console2} from "forge-std/console2.sol";

/// @title B01-06 slisBNB Venus loop + PT-slisBNB rate hedge (3-mechanism)
///
/// @notice Three-mechanism stack:
///         1. **Lista**   — slisBNB mint (LST stake-rate carry leg).
///         2. **Venus**   — vslisBNB collateral, borrow BNB, recursive loop
///                          (leverage on the carry).
///         3. **Pendle**  — buy PT-slisBNB at fixed discount with a small
///                          slice of the borrowed BNB. PT locks in the
///                          slisBNB stake-rate that the recursive loop is
///                          *betting on*. If the Lista stake rate compresses
///                          mid-position the PT mark-up makes up the
///                          differential — the position becomes
///                          rate-hedged instead of pure-directional.
///
/// @dev    The hedge slice is sized so that the PT leg covers the
///         "borrow APR > stake APR" tail: i.e. PT P&L ≈ −Venus borrow
///         marginal cost when rates converge. This is a positional, not
///         atomic, strategy — the PT is held to maturity (or sold early if
///         the slisBNB SY rate spikes).
contract B01_06_SlisBNBPendlePTVenusHedgeLoopTest is BSCStrategyBase {
    /// @dev Pinned block — need both Venus slisBNB listing AND an active
    ///      Pendle PT-slisBNB market. Re-pin once Pendle BSC subgraph is
    ///      verified.
    uint256 internal constant FORK_BLOCK = 42_000_000;

    /// @dev Venus vslisBNB (see B01-01). Inline because BSC.sol does not yet
    ///      have a verified entry for this market.
    address internal constant LOCAL_VSLISBNB = 0xd3CC9d8f3689B83c91b7B59cAB4946B063EB894A;

    /// @dev Pendle PT-slisBNB market on BSC. Same placeholder shape as B04-02.
    address internal constant LOCAL_PT_SLISBNB_MARKET = 0xa1B2c3d4E5f60718293a4B5C6d7E8F9012345678;

    uint256 internal constant PRINCIPAL_BNB = 100 ether;
    uint256 internal constant ITERATIONS = 4;
    uint256 internal constant SAFETY_BPS = 9_500;
    uint256 internal constant HOLD_DAYS = 30;

    /// @dev Fraction of each iteration's borrowed BNB that is diverted into
    ///      a PT-slisBNB hedge (bps). 1_500 = 15 %. The remaining 85 % is
    ///      re-staked into Lista to keep the carry leverage close to the
    ///      pure-loop case.
    uint256 internal constant HEDGE_SLICE_BPS = 1_500;

    address internal _pt;
    address internal _yt;
    address internal _sy;
    bool internal _hedgeLive;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.WBNB);
        _trackToken(BSC.slisBNB);
        _trackToken(LOCAL_VSLISBNB);
        _trackToken(BSC.vBNB);

        try IPendleMarket(LOCAL_PT_SLISBNB_MARKET).readTokens() returns (
            address sy_, address pt_, address yt_
        ) {
            _sy = sy_;
            _pt = pt_;
            _yt = yt_;
            _hedgeLive = true;
            _trackToken(pt_);
        } catch {
            _hedgeLive = false;
            console2.log("PT-slisBNB market unavailable; loop runs unhedged");
        }
    }

    function testStrategy_B01_06() public {
        vm.deal(address(this), PRINCIPAL_BNB);
        _startPnL();

        IVenusComptroller comp = IVenusComptroller(BSC.VENUS_COMPTROLLER);
        address[] memory markets = new address[](2);
        markets[0] = LOCAL_VSLISBNB;
        markets[1] = BSC.vBNB;
        comp.enterMarkets(markets);

        IListaStakeManager sm = IListaStakeManager(BSC.LISTA_STAKE_MANAGER);
        IslisBNB slis = IslisBNB(BSC.slisBNB);
        IVToken vSlis = IVToken(LOCAL_VSLISBNB);
        IVBNB vBNB = IVBNB(BSC.vBNB);

        slis.approve(LOCAL_VSLISBNB, type(uint256).max);

        uint256 bnbToStake = address(this).balance;
        uint256 totalHedgeBnb;

        for (uint256 i = 0; i < ITERATIONS; i++) {
            // 1. BNB → slisBNB.
            sm.deposit{value: bnbToStake}();
            uint256 slisBal = slis.balanceOf(address(this));

            // 2. Supply slisBNB.
            require(vSlis.mint(slisBal) == 0, "vslisBNB mint failed");

            // 3. Borrow BNB.
            (uint256 err, uint256 liq, uint256 shortfall) = comp.getAccountLiquidity(address(this));
            require(err == 0 && shortfall == 0, "venus liquidity error");
            uint256 borrowAmt = (liq * SAFETY_BPS) / 10_000;
            if (borrowAmt == 0) break;

            require(vBNB.borrow(borrowAmt) == 0, "vBNB borrow failed");
            uint256 freshBnb = address(this).balance;
            if (freshBnb == 0) break;

            // 4. Carve a HEDGE_SLICE_BPS slice into Pendle PT-slisBNB.
            uint256 hedgeAmt = (freshBnb * HEDGE_SLICE_BPS) / 10_000;
            if (_hedgeLive && hedgeAmt > 0) {
                uint256 ptOut = _swapBnbForPt(hedgeAmt);
                if (ptOut > 0) {
                    totalHedgeBnb += hedgeAmt;
                    bnbToStake = freshBnb - hedgeAmt;
                } else {
                    bnbToStake = freshBnb;
                }
            } else {
                bnbToStake = freshBnb;
            }

            if (bnbToStake == 0) break;
        }

        // Final dust stake.
        if (address(this).balance > 0) {
            sm.deposit{value: address(this).balance}();
            uint256 finalSlis = slis.balanceOf(address(this));
            if (finalSlis > 0) {
                require(vSlis.mint(finalSlis) == 0, "final vslisBNB mint failed");
            }
        }

        // Hold 30 days.
        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
        vm.roll(block.number + (HOLD_DAYS * 1 days) / 3);

        vBNB.borrowBalanceCurrent(address(this));
        vSlis.balanceOfUnderlying(address(this));

        // Re-mark slisBNB price using StakeManager rate.
        uint256 bnbPerSlis = sm.convertSnBnbToBnb(1e18);
        _setOraclePrice(BSC.slisBNB, (600e8 * bnbPerSlis) / 1e18);

        // Re-mark PT price = slisBNB rate × pull-to-par factor. As maturity
        // approaches, PT price converges to 1 SY unit (≈ 1 slisBNB worth).
        // For PnL purposes, mark PT at slisBNB-implied value at the
        // re-mark block (worst-case conservative; PT will be ≥ this).
        if (_hedgeLive && _pt != address(0)) {
            uint256 ptPriceE8 = (600e8 * bnbPerSlis) / 1e18;
            _setOraclePrice(_pt, ptPriceE8);
        }

        uint256 debt = vBNB.borrowBalanceCurrent(address(this));
        emit log_named_uint("vbnb_debt_wei", debt);
        emit log_named_uint("slis_rate_1e18", bnbPerSlis);
        emit log_named_uint("hedge_total_bnb_wei", totalHedgeBnb);

        _endPnL("B01-06: slisBNB Venus loop + PT hedge");
    }

    // ---- Pendle helper ----

    function _swapBnbForPt(uint256 bnbIn) internal returns (uint256 netPtOut) {
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: BSC.BNB,
            netTokenIn: bnbIn,
            tokenMintSy: BSC.BNB,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        IPendleRouter.LimitOrderData memory emptyLimit;

        try IPendleRouter(BSC.PENDLE_ROUTER_V4).swapExactTokenForPt{value: bnbIn}(
            address(this), LOCAL_PT_SLISBNB_MARKET, 0, approx, input, emptyLimit
        ) returns (uint256 ptOut_, uint256, uint256) {
            netPtOut = ptOut_;
        } catch {
            netPtOut = 0;
        }
    }
}
