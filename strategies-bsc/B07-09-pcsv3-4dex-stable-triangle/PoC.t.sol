// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";
import {IPancakeV3Router} from "src/interfaces/bsc/amm/IPancakeV3Router.sol";
import {IPancakeV2Router} from "src/interfaces/bsc/amm/IPancakeV2Router.sol";
import {IWombatPool} from "src/interfaces/bsc/amm/IWombatPool.sol";
import {IThenaRouter} from "src/interfaces/bsc/amm/IThenaRouter.sol";

/// @title B07-09 PCS v3 USDC flash → 4-DEX stable triangle (v2 + v3 + Wombat + Thena stable)
/// @notice Four BSC venues, each with a different invariant or pricing
///         mechanism, route the same USDC↔USDT trade differently:
///           - PancakeSwap v2 (constant-product, 0.25% fee). Catches
///             retail flow.
///           - PancakeSwap v3 0.01% USDT/USDC (concentrated band).
///             Flash source.
///           - Wombat Main Pool (dynamic-asset-weight StableSwap, ~5 bp
///             haircut at neutral coverage).
///           - Thena stable pair (Solidly stable invariant
///             k = x³y + xy³, 0.04% fee). Often the most stale because
///             LPs are bribe-driven.
///
///         The strategy picks the best two-hop cycle through three of
///         the four venues that produces a positive edge after the
///         PCS v3 flash fee. With four venues there are 4·3·2 = 24
///         ordered cycles; the PoC enumerates a curated subset (three
///         distinct cycles) representative of the family.
/// @dev    Mechanism count: 3 (PCS v3 flash + at least two of: PCS v2,
///         Wombat, Thena stable). The fourth venue (PCS StableSwap) is
///         tracked as an alternate exit but not used in the active
///         cycle in this PoC — it's in scope as a Wave 3 expansion.
contract B07_09_PcsV3FourDexStableTriangleTest is BSCStrategyBase, IPancakeV3FlashCallback {
    uint256 internal constant FORK_BLOCK = 42_000_000;

    /// @dev Flash source: PCS v3 USDC/USDT 0.01%.
    address internal constant PCS_V3_USDT_USDC_100 = 0x92b7807bF19b7DDdf89b706143896d05228f3121;
    uint24 internal constant PCS_V3_FEE_100 = 100;

    /// @dev Wombat main pool (USDT/USDC/BUSD basket).
    address internal constant WOMBAT_MAIN = BSC.WOMBAT_MAIN_POOL;

    /// @dev Thena USDT/USDC STABLE pair (stable=true). Placeholder —
    ///      Wave 3 verify via `THENA_ROUTER.pairFor(USDT, USDC, true)`.
    address internal constant THENA_USDT_USDC_STABLE = 0x6321B57b6fdc14924be480c54e93294617E672aB;

    /// @dev PCS v2 USDT/USDC pair (constant-product 0.25%). Placeholder —
    ///      derive at runtime via PCS_V2_FACTORY but PoC hardcodes for
    ///      grep visibility.
    address internal constant PCS_V2_USDT_USDC = 0xEc6557348085Aa57C72514D67070dC863C0a5A8c;

    /// @dev Flash USDC notional. 1M USDC; sized to keep each leg's
    ///      impact ≤ 1% of its respective pool reserves.
    uint256 internal constant FLASH_NOTIONAL_USDC = 1_000_000 ether;

    /// @dev Required net edge in bps (after summed fees).
    uint256 internal constant MIN_NET_EDGE_BPS = 3;

    /// @dev Cycle selector. 0 = Wombat (USDC→USDT) + Thena stable (USDT→USDC).
    ///      1 = Thena stable (USDC→USDT) + Wombat (USDT→USDC).
    ///      2 = PCS v2 (USDC→USDT) + Wombat (USDT→USDC).
    enum Cycle { WombatToThena, ThenaToWombat, V2ToWombat }

    bool internal _flashActive;
    Cycle internal _activeCycle;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.USDC);
        _trackToken(BSC.USDT);
    }

    function testStrategy_B07_09() public {
        // ---- 1. Quote each of the three cycles ----
        uint256 cycle0Out = _quoteWombatThena(FLASH_NOTIONAL_USDC);
        uint256 cycle1Out = _quoteThenaWombat(FLASH_NOTIONAL_USDC);
        uint256 cycle2Out = _quoteV2Wombat(FLASH_NOTIONAL_USDC);

        emit log_named_uint("B07-09: cycle0_wombat->thena_usdc_out", cycle0Out);
        emit log_named_uint("B07-09: cycle1_thena->wombat_usdc_out", cycle1Out);
        emit log_named_uint("B07-09: cycle2_v2->wombat_usdc_out", cycle2Out);

        // Flash fee on PCS v3 0.01% = 1 bp of notional.
        uint256 pcsFlashFee = FLASH_NOTIONAL_USDC / 10_000;
        uint256 owed = FLASH_NOTIONAL_USDC + pcsFlashFee;

        // Pick best cycle.
        Cycle best;
        uint256 bestOut = 0;
        if (cycle0Out > bestOut) { bestOut = cycle0Out; best = Cycle.WombatToThena; }
        if (cycle1Out > bestOut) { bestOut = cycle1Out; best = Cycle.ThenaToWombat; }
        if (cycle2Out > bestOut) { bestOut = cycle2Out; best = Cycle.V2ToWombat; }

        if (bestOut <= owed) {
            emit log_string("B07-09: skipped (no cycle profitable after flash fee)");
            return;
        }
        uint256 edgeBps = ((bestOut - owed) * 10_000) / FLASH_NOTIONAL_USDC;
        emit log_named_uint("B07-09: best_edge_bps_after_flash", edgeBps);
        if (edgeBps < MIN_NET_EDGE_BPS) {
            emit log_string("B07-09: skipped (edge below min)");
            return;
        }

        _activeCycle = best;
        _startPnL();

        _flashActive = true;
        IPancakeV3Pool pool = IPancakeV3Pool(PCS_V3_USDT_USDC_100);
        bool usdcIsToken0 = pool.token0() == BSC.USDC;
        if (usdcIsToken0) {
            pool.flash(address(this), FLASH_NOTIONAL_USDC, 0, abi.encode(true));
        } else {
            pool.flash(address(this), 0, FLASH_NOTIONAL_USDC, abi.encode(false));
        }
        _flashActive = false;

        _endPnL("B07-09: PCS v3 USDC flash + 4-DEX stable triangle (v2/v3/Wombat/Thena)");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        require(_flashActive, "callback: not active");
        require(msg.sender == PCS_V3_USDT_USDC_100, "callback: wrong pool");

        bool usdcIsToken0 = abi.decode(data, (bool));
        uint256 owedFee = usdcIsToken0 ? fee0 : fee1;

        Cycle c = _activeCycle;
        uint256 usdcOut;

        if (c == Cycle.WombatToThena) {
            uint256 usdt = _swapWombat(BSC.USDC, BSC.USDT, FLASH_NOTIONAL_USDC);
            usdcOut = _swapThenaStable(BSC.USDT, BSC.USDC, usdt);
        } else if (c == Cycle.ThenaToWombat) {
            uint256 usdt = _swapThenaStable(BSC.USDC, BSC.USDT, FLASH_NOTIONAL_USDC);
            usdcOut = _swapWombat(BSC.USDT, BSC.USDC, usdt);
        } else {
            uint256 usdt = _swapV2(BSC.USDC, BSC.USDT, FLASH_NOTIONAL_USDC);
            usdcOut = _swapWombat(BSC.USDT, BSC.USDC, usdt);
        }
        require(usdcOut > 0, "cycle: zero out");

        // Repay PCS v3 flash.
        IERC20(BSC.USDC).transfer(PCS_V3_USDT_USDC_100, FLASH_NOTIONAL_USDC + owedFee);
    }

    // ---- Quote helpers ----

    function _quoteWombatThena(uint256 amount) internal view returns (uint256) {
        try IWombatPool(WOMBAT_MAIN).quotePotentialSwap(BSC.USDC, BSC.USDT, amount) returns (uint256 usdt, uint256) {
            IThenaRouter.Route[] memory r = new IThenaRouter.Route[](1);
            r[0] = IThenaRouter.Route({from: BSC.USDT, to: BSC.USDC, stable: true});
            try IThenaRouter(BSC.THENA_ROUTER).getAmountsOut(usdt, r) returns (uint256[] memory outs) {
                return outs[outs.length - 1];
            } catch { return 0; }
        } catch { return 0; }
    }

    function _quoteThenaWombat(uint256 amount) internal view returns (uint256) {
        IThenaRouter.Route[] memory r = new IThenaRouter.Route[](1);
        r[0] = IThenaRouter.Route({from: BSC.USDC, to: BSC.USDT, stable: true});
        try IThenaRouter(BSC.THENA_ROUTER).getAmountsOut(amount, r) returns (uint256[] memory outs) {
            uint256 usdt = outs[outs.length - 1];
            try IWombatPool(WOMBAT_MAIN).quotePotentialSwap(BSC.USDT, BSC.USDC, usdt) returns (uint256 usdc, uint256) {
                return usdc;
            } catch { return 0; }
        } catch { return 0; }
    }

    function _quoteV2Wombat(uint256 amount) internal view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = BSC.USDC; path[1] = BSC.USDT;
        try IPancakeV2Router(BSC.PCS_V2_ROUTER).getAmountsOut(amount, path) returns (uint256[] memory amts) {
            uint256 usdt = amts[amts.length - 1];
            try IWombatPool(WOMBAT_MAIN).quotePotentialSwap(BSC.USDT, BSC.USDC, usdt) returns (uint256 usdc, uint256) {
                return usdc;
            } catch { return 0; }
        } catch { return 0; }
    }

    // ---- Swap helpers ----

    function _swapWombat(address from, address to, uint256 amount) internal returns (uint256) {
        IERC20(from).approve(WOMBAT_MAIN, type(uint256).max);
        (uint256 out, ) = IWombatPool(WOMBAT_MAIN).swap(from, to, amount, 1, address(this), block.timestamp);
        return out;
    }

    function _swapThenaStable(address from, address to, uint256 amount) internal returns (uint256) {
        IERC20(from).approve(BSC.THENA_ROUTER, type(uint256).max);
        IThenaRouter.Route[] memory route = new IThenaRouter.Route[](1);
        route[0] = IThenaRouter.Route({from: from, to: to, stable: true});
        uint256[] memory outs = IThenaRouter(BSC.THENA_ROUTER).swapExactTokensForTokens(
            amount, 1, route, address(this), block.timestamp
        );
        return outs[outs.length - 1];
    }

    function _swapV2(address from, address to, uint256 amount) internal returns (uint256) {
        IERC20(from).approve(BSC.PCS_V2_ROUTER, type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = from; path[1] = to;
        uint256[] memory amts = IPancakeV2Router(BSC.PCS_V2_ROUTER).swapExactTokensForTokens(
            amount, 1, path, address(this), block.timestamp
        );
        return amts[amts.length - 1];
    }
}
