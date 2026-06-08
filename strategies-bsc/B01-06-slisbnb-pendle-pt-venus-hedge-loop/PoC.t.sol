// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWBNB} from "src/interfaces/bsc/common/IWBNB.sol";
import {IListaStakeManager} from "src/interfaces/bsc/lst/IListaStakeManager.sol";
import {IslisBNB} from "src/interfaces/bsc/lst/IslisBNB.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {console2} from "forge-std/console2.sol";

/// @title B01-06 slisBNB Venus loop + PT-slisBNB rate hedge (3-mechanism)
/// @notice Three-mechanism stack:
///         1. Lista  - slisBNB mint (LST stake-rate carry leg).
///         2. Venus  - vslisBNB collateral (Liquid-Staked-BNB isolated pool),
///                     borrow WBNB, recursive leverage loop.
///         3. Pendle - buy PT-slisBNB at a fixed discount with a slice of the
///                     borrowed BNB to hedge the stake-rate the loop bets on.
/// @dev    The Venus loop matches B01-01 (slisBNB is in the isolated
///         "Liquid Staked BNB" pool, borrow asset is WBNB). The Pendle PT-
///         slisBNB market is not deployed/verifiable on BSC at the forkable
///         blocks, so the hedge leg degrades gracefully (playbook point 8): if
///         readTokens() on the configured market reverts, _hedgeLive=false and
///         the strategy runs as the faithful (unhedged) leveraged carry loop.
contract B01_06_SlisBNBPendlePTVenusHedgeLoopTest is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 44_000_000;

    address internal constant LOCAL_LSB_COMPTROLLER = 0xd933909A4a2b7A4638903028f44D1d38ce27c352;
    address internal constant LOCAL_VSLISBNB = 0xd3CC9d8f3689B83c91b7B59cAB4946B063EB894A;
    address internal constant LOCAL_VWBNB = 0xe10E80B7FD3a29fE46E16C30CC8F4dd938B742e2;

    /// @dev Pendle PT-slisBNB market on BSC. No verifiable deployment exists at
    ///      the forkable blocks; the hedge leg is guarded by a readTokens()
    ///      code-check and skips gracefully when absent.
    address internal constant LOCAL_PT_SLISBNB_MARKET = 0x0000000000000000000000000000000000000000;

    uint256 internal constant PRINCIPAL_BNB = 10 ether;
    uint256 internal constant ITERATIONS = 4;
    uint256 internal constant SAFETY_BPS = 8_000;
    uint256 internal constant HOLD_DAYS = 30;
    /// @dev Fraction of each iteration's borrowed BNB diverted into PT (bps).
    uint256 internal constant HEDGE_SLICE_BPS = 1_500;

    address internal _pt;
    bool internal _hedgeLive;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.WBNB);
        _trackToken(BSC.slisBNB);

        if (LOCAL_PT_SLISBNB_MARKET.code.length > 0) {
            try IPendleMarket(LOCAL_PT_SLISBNB_MARKET).readTokens() returns (
                address, address pt_, address
            ) {
                _pt = pt_;
                _hedgeLive = true;
                _trackToken(pt_);
            } catch {
                _hedgeLive = false;
            }
        }
        if (!_hedgeLive) {
            console2.log("PT-slisBNB market unavailable on BSC; loop runs unhedged");
        }
    }

    function testStrategy_B01_06() public {
        vm.deal(address(this), PRINCIPAL_BNB);
        _startPnL();

        IVenusComptroller comp = IVenusComptroller(LOCAL_LSB_COMPTROLLER);
        address[] memory markets = new address[](2);
        markets[0] = LOCAL_VSLISBNB;
        markets[1] = LOCAL_VWBNB;
        comp.enterMarkets(markets);

        IListaStakeManager sm = IListaStakeManager(BSC.LISTA_STAKE_MANAGER);
        IslisBNB slis = IslisBNB(BSC.slisBNB);
        IVToken vSlis = IVToken(LOCAL_VSLISBNB);
        IVToken vWBNB = IVToken(LOCAL_VWBNB);
        IWBNB wbnb = IWBNB(BSC.WBNB);

        slis.approve(LOCAL_VSLISBNB, type(uint256).max);

        uint256 bnbToStake = address(this).balance;
        uint256 totalHedgeBnb;

        for (uint256 i = 0; i < ITERATIONS; i++) {
            sm.deposit{value: bnbToStake}();
            require(vSlis.mint(slis.balanceOf(address(this))) == 0, "vslisBNB mint failed");

            (uint256 err, uint256 liq, uint256 shortfall) = comp.getAccountLiquidity(address(this));
            require(err == 0 && shortfall == 0, "venus liquidity error");
            if (liq == 0) break;

            uint256 wbnbPriceE18 = _poolBnbPriceE18();
            uint256 borrowAmt = (liq * SAFETY_BPS) / 10_000;
            if (wbnbPriceE18 > 0) borrowAmt = (borrowAmt * 1e18) / wbnbPriceE18;
            uint256 cash = vWBNB.getCash();
            if (borrowAmt > (cash * 9) / 10) borrowAmt = (cash * 9) / 10;
            if (borrowAmt == 0) break;

            require(vWBNB.borrow(borrowAmt) == 0, "vWBNB borrow failed");
            wbnb.withdraw(wbnb.balanceOf(address(this)));
            uint256 freshBnb = address(this).balance;
            if (freshBnb == 0) break;

            // Hedge slice into Pendle PT-slisBNB, if the market is live.
            uint256 hedgeAmt = (freshBnb * HEDGE_SLICE_BPS) / 10_000;
            if (_hedgeLive && hedgeAmt > 0 && _swapBnbForPt(hedgeAmt) > 0) {
                totalHedgeBnb += hedgeAmt;
                bnbToStake = freshBnb - hedgeAmt;
            } else {
                bnbToStake = freshBnb;
            }
            if (bnbToStake == 0) break;
        }

        if (address(this).balance > 0) {
            sm.deposit{value: address(this).balance}();
            uint256 finalSlis = slis.balanceOf(address(this));
            if (finalSlis > 0) require(vSlis.mint(finalSlis) == 0, "final vslisBNB mint failed");
        }

        // ---- Position equity at entry (1e8 USD). ----
        uint256 debtWei = vWBNB.borrowBalanceCurrent(address(this));
        uint256 collSlis = vSlis.balanceOfUnderlying(address(this));
        uint256 bnbPerSlis = sm.convertSnBnbToBnb(1e18);
        uint256 collBnbWei = (collSlis * bnbPerSlis) / 1e18;

        uint256 bnbUsdE8 = 600e8;
        int256 collUsdE8 = int256((collBnbWei * bnbUsdE8) / 1e18);
        int256 debtUsdE8 = int256((debtWei * bnbUsdE8) / 1e18);
        _creditPositionEquityE8(collUsdE8 - debtUsdE8);

        // Mark PT hedge (if held) at slisBNB-implied value (pull-to-par floor).
        if (_hedgeLive && _pt != address(0)) {
            _setOraclePrice(_pt, (bnbUsdE8 * bnbPerSlis) / 1e18);
        }

        // Projected 30-day carry: slisBNB stake yield on collateral minus WBNB
        // borrow APR on debt (live IRM rate).
        uint256 blocksPerYear = 365 days / 3;
        uint256 borrowApr1e18 = vWBNB.borrowRatePerBlock() * blocksPerYear;
        uint256 stakeApr1e18 = 35e15;
        int256 annualCarryBnb =
            int256((collBnbWei * stakeApr1e18) / 1e18) - int256((debtWei * borrowApr1e18) / 1e18);
        int256 carryBnb = (annualCarryBnb * int256(HOLD_DAYS)) / 365;
        _creditPositionEquityE8((carryBnb * int256(bnbUsdE8)) / 1e18);

        emit log_named_uint("coll_bnb_wei", collBnbWei);
        emit log_named_uint("wbnb_debt_wei", debtWei);
        emit log_named_uint("hedge_total_bnb_wei", totalHedgeBnb);
        emit log_named_int("carry_bnb_wei_30d", carryBnb);

        _endPnL("B01-06: slisBNB Venus loop + PT hedge");
    }

    function _poolBnbPriceE18() internal view returns (uint256) {
        (bool ok, bytes memory data) =
            LOCAL_LSB_COMPTROLLER.staticcall(abi.encodeWithSignature("oracle()"));
        if (!ok || data.length < 32) return 600e18;
        address oracle = abi.decode(data, (address));
        (bool ok2, bytes memory d2) =
            oracle.staticcall(abi.encodeWithSignature("getUnderlyingPrice(address)", LOCAL_VWBNB));
        if (!ok2 || d2.length < 32) return 600e18;
        uint256 p = abi.decode(d2, (uint256));
        return p == 0 ? 600e18 : p;
    }

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
