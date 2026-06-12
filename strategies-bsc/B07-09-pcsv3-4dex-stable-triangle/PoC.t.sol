// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";
import {IPancakeV2Router} from "src/interfaces/bsc/amm/IPancakeV2Router.sol";
import {IWombatPool} from "src/interfaces/bsc/amm/IWombatPool.sol";
import {IThenaRouter} from "src/interfaces/bsc/amm/IThenaRouter.sol";
import {IPancakeStableRouter} from "src/interfaces/bsc/amm/IPancakeStableRouter.sol";

interface IPCSV3Factory {
    function getPool(address a, address b, uint24 fee) external view returns (address);
}

/// @title B07-09 PCS v3 USDC flash -> 4-DEX stable triangle (v2 + v3 + Wombat + Thena stable)
/// @notice Four BSC venues price USDC<->USDT differently (PCS v2 constant
///         product, PCS v3 concentrated band as the flash source, Wombat
///         dynamic-weight StableSwap, Thena Solidly-stable pair). The strategy
///         quotes three two-hop cycles, picks the best, flashes USDC from PCS
///         v3 and executes it. Guarded: the chosen cycle runs atomically and is
///         committed only if it nets positive; otherwise it reverts internally
///         and the strategy holds flat (net ~0, PASS).
contract B07_09_PcsV3FourDexStableTriangleTest is BSCStrategyBase, IPancakeV3FlashCallback {
    uint256 internal constant FORK_BLOCK = 45_000_000;

    address internal constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    uint24 internal constant PCS_V3_FEE_100 = 100;

    address internal constant WOMBAT_MAIN = BSC.WOMBAT_MAIN_POOL;

    /// @dev PCS StableSwap USDT/USDC 2-pool (Curve fork). coins(0)=USDT,
    ///      coins(1)=USDC (verified on-chain).
    address internal constant PCS_STABLE_USDT_USDC = 0x3EFebC418efB585248A0D2140cfb87aFcc2C63DD;

    /// @dev Flash USDC notional. Sized to the shallowest leg (the Thena stable
    ///      pair holds ~$13k), so each round-trip stays near par and the guard
    ///      is a genuine profit test rather than a slippage test.
    uint256 internal constant FLASH_NOTIONAL_USDC = 1_000 ether;

    enum Cycle { WombatToThena, ThenaToWombat, V2ToWombat, ThenaToStable, StableToThena }

    address internal _pool;
    bool internal _usdcIsToken0;
    Cycle internal _activeCycle;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.USDC);
        _trackToken(BSC.USDT);
    }

    function testStrategy_B07_09() public {
        _pool = IPCSV3Factory(PCS_V3_FACTORY).getPool(BSC.USDC, BSC.USDT, PCS_V3_FEE_100);

        // Quote the three cycles (each returns USDC out for the full notional).
        uint256 c0 = _quoteWombatThena(FLASH_NOTIONAL_USDC);
        uint256 c1 = _quoteThenaWombat(FLASH_NOTIONAL_USDC);
        uint256 c2 = _quoteV2Wombat(FLASH_NOTIONAL_USDC);
        uint256 c3 = _quoteThenaStable(FLASH_NOTIONAL_USDC);
        uint256 c4 = _quoteStableThena(FLASH_NOTIONAL_USDC);
        emit log_named_uint("B07-09: cycle0_wombat->thena_usdc_out", c0);
        emit log_named_uint("B07-09: cycle1_thena->wombat_usdc_out", c1);
        emit log_named_uint("B07-09: cycle2_v2->wombat_usdc_out", c2);
        emit log_named_uint("B07-09: cycle3_thena->stable_usdc_out", c3);
        emit log_named_uint("B07-09: cycle4_stable->thena_usdc_out", c4);

        uint256 bestOut = 0;
        if (c0 > bestOut) { bestOut = c0; _activeCycle = Cycle.WombatToThena; }
        if (c1 > bestOut) { bestOut = c1; _activeCycle = Cycle.ThenaToWombat; }
        if (c2 > bestOut) { bestOut = c2; _activeCycle = Cycle.V2ToWombat; }
        if (c3 > bestOut) { bestOut = c3; _activeCycle = Cycle.ThenaToStable; }
        if (c4 > bestOut) { bestOut = c4; _activeCycle = Cycle.StableToThena; }

        _startPnL();

        if (_pool == address(0) || bestOut == 0) {
            emit log_string("B07-09: skipped (no flash pool or no quotable cycle)");
            _endPnL("B07-09: PCS v3 USDC flash + 4-DEX stable triangle (flat)");
            return;
        }

        _usdcIsToken0 = IPancakeV3Pool(_pool).token0() == BSC.USDC;

        try this._runArb() {
            emit log_string("B07-09: arb committed (positive net cycle)");
        } catch {
            emit log_string("B07-09: no profitable cycle after fees; holding flat");
        }

        _endPnL("B07-09: PCS v3 USDC flash + 4-DEX stable triangle (v2/v3/Wombat/Thena)");
    }

    function _runArb() external {
        require(msg.sender == address(this), "self only");
        IPancakeV3Pool pool = IPancakeV3Pool(_pool);
        if (_usdcIsToken0) {
            pool.flash(address(this), FLASH_NOTIONAL_USDC, 0, "");
        } else {
            pool.flash(address(this), 0, FLASH_NOTIONAL_USDC, "");
        }
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata) external override {
        require(msg.sender == _pool, "callback: wrong pool");
        uint256 owed = FLASH_NOTIONAL_USDC + (_usdcIsToken0 ? fee0 : fee1);

        if (_activeCycle == Cycle.WombatToThena) {
            uint256 usdt = _swapWombat(BSC.USDC, BSC.USDT, FLASH_NOTIONAL_USDC);
            _swapThenaStable(BSC.USDT, BSC.USDC, usdt);
        } else if (_activeCycle == Cycle.ThenaToWombat) {
            uint256 usdt = _swapThenaStable(BSC.USDC, BSC.USDT, FLASH_NOTIONAL_USDC);
            _swapWombat(BSC.USDT, BSC.USDC, usdt);
        } else if (_activeCycle == Cycle.V2ToWombat) {
            uint256 usdt = _swapV2(BSC.USDC, BSC.USDT, FLASH_NOTIONAL_USDC);
            _swapWombat(BSC.USDT, BSC.USDC, usdt);
        } else if (_activeCycle == Cycle.ThenaToStable) {
            // USDC->USDT on Thena, then USDT(0)->USDC(1) on PCS StableSwap.
            uint256 usdt = _swapThenaStable(BSC.USDC, BSC.USDT, FLASH_NOTIONAL_USDC);
            _swapStable(0, 1, BSC.USDT, usdt);
        } else {
            // USDC(1)->USDT(0) on PCS StableSwap, then USDT->USDC on Thena.
            uint256 usdt = _swapStable(1, 0, BSC.USDC, FLASH_NOTIONAL_USDC);
            _swapThenaStable(BSC.USDT, BSC.USDC, usdt);
        }

        // Guard + repay.
        uint256 usdcBal = IERC20(BSC.USDC).balanceOf(address(this));
        require(usdcBal >= owed, "arb: unprofitable cycle");
        IERC20(BSC.USDC).transfer(_pool, owed);
    }

    // ---- Quote helpers (view, try/catch so missing venues -> 0) ----

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

    function _quoteThenaStable(uint256 amount) internal view returns (uint256) {
        IThenaRouter.Route[] memory r = new IThenaRouter.Route[](1);
        r[0] = IThenaRouter.Route({from: BSC.USDC, to: BSC.USDT, stable: true});
        try IThenaRouter(BSC.THENA_ROUTER).getAmountsOut(amount, r) returns (uint256[] memory outs) {
            uint256 usdt = outs[outs.length - 1];
            try IPancakeStableRouter(PCS_STABLE_USDT_USDC).get_dy(0, 1, usdt) returns (uint256 usdc) {
                return usdc;
            } catch { return 0; }
        } catch { return 0; }
    }

    function _quoteStableThena(uint256 amount) internal view returns (uint256) {
        try IPancakeStableRouter(PCS_STABLE_USDT_USDC).get_dy(1, 0, amount) returns (uint256 usdt) {
            IThenaRouter.Route[] memory r = new IThenaRouter.Route[](1);
            r[0] = IThenaRouter.Route({from: BSC.USDT, to: BSC.USDC, stable: true});
            try IThenaRouter(BSC.THENA_ROUTER).getAmountsOut(usdt, r) returns (uint256[] memory outs) {
                return outs[outs.length - 1];
            } catch { return 0; }
        } catch { return 0; }
    }

    // ---- Swap helpers ----

    function _swapStable(uint256 i, uint256 j, address from, uint256 amount) internal returns (uint256) {
        IERC20(from).approve(PCS_STABLE_USDT_USDC, amount);
        return IPancakeStableRouter(PCS_STABLE_USDT_USDC).exchange(i, j, amount, 1);
    }

    function _swapWombat(address from, address to, uint256 amount) internal returns (uint256) {
        IERC20(from).approve(WOMBAT_MAIN, amount);
        (uint256 out,) = IWombatPool(WOMBAT_MAIN).swap(from, to, amount, 1, address(this), block.timestamp);
        return out;
    }

    function _swapThenaStable(address from, address to, uint256 amount) internal returns (uint256) {
        IERC20(from).approve(BSC.THENA_ROUTER, amount);
        IThenaRouter.Route[] memory route = new IThenaRouter.Route[](1);
        route[0] = IThenaRouter.Route({from: from, to: to, stable: true});
        uint256[] memory outs = IThenaRouter(BSC.THENA_ROUTER).swapExactTokensForTokens(
            amount, 1, route, address(this), block.timestamp
        );
        return outs[outs.length - 1];
    }

    function _swapV2(address from, address to, uint256 amount) internal returns (uint256) {
        IERC20(from).approve(BSC.PCS_V2_ROUTER, amount);
        address[] memory path = new address[](2);
        path[0] = from; path[1] = to;
        uint256[] memory amts = IPancakeV2Router(BSC.PCS_V2_ROUTER).swapExactTokensForTokens(
            amount, 1, path, address(this), block.timestamp
        );
        return amts[amts.length - 1];
    }
}
