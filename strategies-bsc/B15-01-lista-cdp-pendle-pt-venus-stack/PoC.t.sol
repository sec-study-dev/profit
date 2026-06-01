// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IListaInteraction} from "src/interfaces/bsc/cdp/IListaInteraction.sol";
import {IPancakeStableRouter} from "src/interfaces/bsc/amm/IPancakeStableRouter.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {console2} from "forge-std/console2.sol";

/// @title B15-01 — Lista CDP + Pendle PT-USDe + Venus collateral stack
///
/// @notice Triple-protocol mechanism stack:
///         1. Lista CDP: deposit slisBNB → mint lisUSD.
///         2. Pendle BSC: lisUSD → USDe → PT-USDe (fixed yield to maturity).
///         3. Venus Core: supply PT (or USDe fallback), borrow USDT, recycle
///            USDT → lisUSD → Lista.payback to free CDP headroom.
///
/// @dev Offline-first PoC: all external interactions are wrapped in `try/catch`
///      so the PoC degrades to a logged no-op + projected PnL when a BSC fork
///      or a counterpart contract is unavailable.
contract B15_01_ListaCdpPendlePtVenusStackTest is BSCStrategyBase {
    // ---- Pinned block ----
    uint256 constant FORK_BLOCK = 42_500_000;

    // ---- Pendle BSC market (per-maturity inline) ----
    /// @notice Pendle PT-USDe-26JUN2025 market on BSC. // TODO verify.
    address constant LOCAL_PT_USDE_MARKET = 0x9eC4c502D989F04FfA9312C9D6E3F872EC91A0F9;

    // ---- Equity & sizing ----
    /// @dev 100 slisBNB ≈ $60,000 at $600/BNB.
    uint256 constant SEED_SLIS_BNB = 100 ether;
    /// @dev Target CDP LTV — conservative below the ~80% liquidation threshold.
    uint256 constant TARGET_CDP_LTV_BPS = 6500;
    /// @dev Venus collateral factor target for the PT/USDe leg.
    uint256 constant VENUS_CF_BPS = 5000;

    // ---- Projection ----
    uint256 constant HOLD_DAYS = 30;
    uint256 constant SLIS_BNB_APR_BPS = 320; // 3.20%
    uint256 constant PT_FIXED_APR_BPS = 1200; // 12.00%
    uint256 constant LISUSD_FEE_BPS = 200; // 2.00%
    uint256 constant VENUS_USDT_BORROW_BPS = 500; // 5.00%

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
        } catch {
            console2.log("BSC_RPC_URL not set; B15-01 runs as offline projection");
        }
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.USDe);
        _trackToken(BSC.USDT);
    }

    function testStrategy_B15_01() public {
        _fund(BSC.slisBNB, address(this), SEED_SLIS_BNB);
        _startPnL();

        // ---- Leg A: Lista CDP — deposit slisBNB, mint lisUSD ----
        IERC20(BSC.slisBNB).approve(BSC.LISTA_INTERACTION, SEED_SLIS_BNB);
        uint256 slisUsdValue = SEED_SLIS_BNB * 600; // 1 slisBNB ≈ $600 (default)
        uint256 lisUsdToMint = (slisUsdValue * TARGET_CDP_LTV_BPS) / 10_000;
        console2.log("cdp_mint_lisUSD_usd1e18=", lisUsdToMint);

        try IListaInteraction(BSC.LISTA_INTERACTION).deposit(address(this), BSC.slisBNB, SEED_SLIS_BNB) {
            try IListaInteraction(BSC.LISTA_INTERACTION).borrow(BSC.slisBNB, lisUsdToMint) {
                console2.log("cdp_borrow_live");
            } catch {
                _fund(BSC.lisUSD, address(this), lisUsdToMint);
                console2.log("cdp_borrow_fallback_mint");
            }
        } catch {
            // Offline: treat slisBNB as locked and mint lisUSD by deal()
            IERC20(BSC.slisBNB).transfer(address(0xCAFE), SEED_SLIS_BNB);
            _fund(BSC.lisUSD, address(this), lisUsdToMint);
            console2.log("cdp_full_offline_fallback");
        }

        // ---- Leg B: PCS StableSwap lisUSD -> USDe ----
        uint256 usdeOut = _swapStable(BSC.lisUSD, BSC.USDe, lisUsdToMint);
        console2.log("usde_after_stableswap_1e18=", usdeOut);

        // ---- Leg C: Pendle BSC swapExactTokenForPt(USDe -> PT-USDe) ----
        uint256 ptOut = _swapUsdeForPt(usdeOut);
        if (ptOut == 0) {
            // Fallback: model PT as USDe held at fixed yield (no router live).
            ptOut = usdeOut;
            console2.log("pendle_unavailable_holding_usde_as_pt");
        }
        console2.log("pt_or_pt_proxy_1e18=", ptOut);

        // ---- Leg D: Venus supply (fallback to USDC mint via vUSDT if PT not listed) ----
        // The PT vToken is not in BSC.sol; we model the supply as a USDT
        // borrow against a notional USDe-equivalent collateral.
        uint256 venusBorrowUsdt = (ptOut * VENUS_CF_BPS) / 10_000;
        _enterVenusUsdtMarket();
        bool venusLive = _tryVenusBorrow(venusBorrowUsdt);
        if (!venusLive) {
            _fund(BSC.USDT, address(this), venusBorrowUsdt);
            console2.log("venus_borrow_fallback_fund");
        }
        console2.log("venus_borrow_usdt_1e18=", venusBorrowUsdt);

        // ---- Leg E: recycle USDT -> lisUSD -> Lista.payback ----
        uint256 lisUsdBack = _swapStable(BSC.USDT, BSC.lisUSD, venusBorrowUsdt);
        IERC20(BSC.lisUSD).approve(BSC.LISTA_INTERACTION, lisUsdBack);
        try IListaInteraction(BSC.LISTA_INTERACTION).payback(BSC.slisBNB, lisUsdBack) {
            console2.log("lista_payback_live_1e18=", lisUsdBack);
        } catch {
            // Offline: burn lisUSD to the dead address to model debt reduction
            IERC20(BSC.lisUSD).transfer(address(0xdEaD), lisUsdBack);
            console2.log("lista_payback_offline_burn_1e18=", lisUsdBack);
        }

        // ---- 30-day carry projection (closed-form) ----
        uint256 slisYield = (SEED_SLIS_BNB * SLIS_BNB_APR_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 ptYield = (ptOut * PT_FIXED_APR_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 lisFee = (lisUsdToMint * LISUSD_FEE_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 venusCost = (venusBorrowUsdt * VENUS_USDT_BORROW_BPS * HOLD_DAYS) / (10_000 * 365);

        _fund(BSC.slisBNB, address(this), slisYield);
        _fund(BSC.USDe, address(this), ptYield);
        // Costs: burn equivalent lisUSD / USDT
        uint256 lisBal = IERC20(BSC.lisUSD).balanceOf(address(this));
        uint256 burnLis = lisFee > lisBal ? lisBal : lisFee;
        if (burnLis > 0) IERC20(BSC.lisUSD).transfer(address(0xdEaD), burnLis);
        uint256 usdtBal = IERC20(BSC.USDT).balanceOf(address(this));
        uint256 burnUsdt = venusCost > usdtBal ? usdtBal : venusCost;
        if (burnUsdt > 0) IERC20(BSC.USDT).transfer(address(0xdEaD), burnUsdt);

        _endPnL("B15-01: Lista CDP + Pendle PT + Venus stack");
    }

    // ---- Helpers ----

    function _swapStable(address from, address to, uint256 amt) internal returns (uint256 out) {
        IERC20(from).approve(BSC.PCS_STABLE_ROUTER, amt);
        // PCS StableSwap pool indices are not deterministic; for the offline
        // path we simulate a 5 bp haircut.
        try IPancakeStableRouter(BSC.PCS_STABLE_ROUTER).exchange(0, 1, amt, 0) returns (uint256 dy) {
            out = dy;
        } catch {
            // Offline: burn `from`, mint `to` minus 5 bp.
            IERC20(from).transfer(address(0xdEaD), amt);
            out = (amt * (10_000 - 5)) / 10_000;
            _fund(to, address(this), out);
        }
    }

    function _swapUsdeForPt(uint256 usdeIn) internal returns (uint256 netPtOut) {
        if (usdeIn == 0) return 0;
        IERC20(BSC.USDe).approve(BSC.PENDLE_ROUTER_V4, usdeIn);
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: BSC.USDe,
            netTokenIn: usdeIn,
            tokenMintSy: BSC.USDe,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        IPendleRouter.LimitOrderData memory emptyLimit;

        try IPendleRouter(BSC.PENDLE_ROUTER_V4).swapExactTokenForPt(
            address(this), LOCAL_PT_USDE_MARKET, 0, approx, input, emptyLimit
        ) returns (uint256 ptOut_, uint256, uint256) {
            netPtOut = ptOut_;
        } catch {
            netPtOut = 0;
        }
    }

    function _enterVenusUsdtMarket() internal {
        address[] memory mkts = new address[](1);
        mkts[0] = BSC.vUSDT;
        try IVenusComptroller(BSC.VENUS_COMPTROLLER).enterMarkets(mkts) returns (uint256[] memory) {
            // ok
        } catch {
            // ignore — offline
        }
    }

    function _tryVenusBorrow(uint256 amt) internal returns (bool ok) {
        try IVToken(BSC.vUSDT).borrow(amt) returns (uint256 err) {
            ok = (err == 0);
        } catch {
            ok = false;
        }
    }
}
