// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IWombatPool} from "src/interfaces/bsc/amm/IWombatPool.sol";
import {console2} from "forge-std/console2.sol";

/// @title B15-10 — Venus VAI mint + Pendle PT-USDT/USDe + Wombat stable LP stack
///
/// @notice Triple-protocol *Venus + Pendle + Wombat* stable yield stack:
///         1. **Venus**: supply USDC, mint VAI (Venus's native stablecoin
///            CDP — distinct from any borrow, VAI uses a separate mint
///            module against any Venus collateral).
///         2. **Pendle BSC**: swap VAI → USDT (PCS stable hop) →
///            PT-USDT-26JUN2025 for a fixed-yield stable carry.
///         3. **Wombat**: deposit half the position's USDT-equivalent
///            into the main Wombat 3-stable pool for LP fees + WOM
///            emissions, providing an *anti-correlated* yield source
///            (Wombat earns most when stables wobble, Pendle locks the
///            yield curve flat).
///
/// @dev Distinct from B15-01 (Lista CDP + Pendle + Venus; CDP collateral
///      is slisBNB, not USDC; uses Pendle PT-USDe, not PT-USDT), B15-03
///      (atomic flash w/ sUSDe), B15-05 (Lista CDP + Wombat + PCS basis,
///      no Pendle).  Here VAI is the *credit-extension* mechanism, and
///      Wombat operates *alongside* Pendle (not instead of it).
contract B15_10_VaiPendlePtWombatStackTest is BSCStrategyBase {
    uint256 constant FORK_BLOCK = 42_950_000;

    /// @notice Pendle PT-USDT-26JUN2025 market on BSC. // TODO verify.
    address constant LOCAL_PT_USDT_MARKET = 0x9eC4c502D989F04FfA9312C9D6E3F872EC91A0F9;

    /// @notice Venus VAIController (mints VAI against any Venus account).
    /// @dev    Placeholder; actual address depends on Venus deployment.
    ///         Most BscScan deployments expose VAIController at
    ///         0x0...004B17 — we proxy here and try/catch.
    // TODO: verify exact VAIController address; using a stand-in.
    address constant LOCAL_VAI_CONTROLLER = 0x004CCc0B0dFf18E8c6a73aB1F8eaCC59F0f6Cd45;

    uint256 constant SEED_USDC = 200_000e18;
    uint256 constant VENUS_VAI_MINT_BPS = 6000; // 60 % of USDC collateral value
    uint256 constant PT_ALLOC_BPS = 6000;       // 60 % of VAI proceeds → PT-USDT
    uint256 constant LP_ALLOC_BPS = 4000;       // 40 % → Wombat LP
    uint256 constant HOLD_DAYS = 180;

    // ---- Carry assumptions ----
    uint256 constant VENUS_USDC_SUPPLY_BPS = 300;    // 3.0 %
    uint256 constant VAI_MINT_FEE_BPS = 100;         // 1.0 % flat
    uint256 constant PT_USDT_APR_BPS = 1000;         // 10.0 % fixed
    uint256 constant WOMBAT_STABLE_APR_BPS = 800;    // 8.0 % (fees + WOM)
    uint256 constant PCS_STABLE_HAIRCUT_BPS = 5;     // 5 bp per stable swap

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
        } catch {
            console2.log("BSC_RPC_URL not set; B15-10 runs as offline projection");
        }
        _trackToken(BSC.USDC);
        _trackToken(BSC.USDT);
        _trackToken(BSC.VAI);
        _trackToken(BSC.WOM);
    }

    function testStrategy_B15_10() public {
        _fund(BSC.USDC, address(this), SEED_USDC);
        _startPnL();

        // ---- Leg A: Venus supply USDC + enter market ----
        IERC20(BSC.USDC).approve(BSC.vUSDC, SEED_USDC);
        bool venusSupplyLive;
        try IVToken(BSC.vUSDC).mint(SEED_USDC) returns (uint256 err) {
            venusSupplyLive = (err == 0);
        } catch {
            venusSupplyLive = false;
        }
        if (!venusSupplyLive) {
            // Offline: keep USDC, model the supply by send-to-vUSDC stub.
            // We don't actually burn — the PnL leg below counts USDC delta.
            console2.log("venus_supply_offline_keep_USDC");
        } else {
            console2.log("venus_supply_live_USDC_1e18=", SEED_USDC);
        }

        address[] memory mkts = new address[](1);
        mkts[0] = BSC.vUSDC;
        try IVenusComptroller(BSC.VENUS_COMPTROLLER).enterMarkets(mkts) returns (uint256[] memory) {} catch {}

        // ---- Leg B: Mint VAI against the Venus account ----
        uint256 vaiMint = (SEED_USDC * VENUS_VAI_MINT_BPS) / 10_000;
        bool vaiLive;
        // VAIController.mintVAI(uint256) is the canonical Venus call.
        (bool ok,) = LOCAL_VAI_CONTROLLER.call(abi.encodeWithSignature("mintVAI(uint256)", vaiMint));
        vaiLive = ok;
        if (!vaiLive) {
            _fund(BSC.VAI, address(this), vaiMint);
            console2.log("vai_mint_offline_funded_1e18=", vaiMint);
        } else {
            console2.log("vai_mint_live_1e18=", vaiMint);
        }

        // ---- Leg C: VAI -> USDT (Wombat stable hop, smaller slippage
        //              than PCS stable for VAI on BSC) ----
        uint256 usdtFromVai = _wombatSwap(BSC.VAI, BSC.USDT, vaiMint);
        console2.log("usdt_from_vai_1e18=", usdtFromVai);

        // ---- Leg D: 60 % into Pendle PT-USDT ----
        uint256 ptInUsdt = (usdtFromVai * PT_ALLOC_BPS) / 10_000;
        uint256 ptOut = _swapUsdtForPt(ptInUsdt);
        if (ptOut == 0) {
            // Offline: model PT-USDT at a 4 % entry discount.
            ptOut = (ptInUsdt * (10_000 - 400)) / 10_000;
            IERC20(BSC.USDT).transfer(address(0xdEaD), ptInUsdt);
            // We can't track PT (no constant in BSC.sol) — credit it as
            // USDT held at the PT's locked value at maturity.
            _fund(BSC.USDT, address(this), ptOut);
            console2.log("pendle_offline_pt_proxy_USDT_1e18=", ptOut);
        } else {
            console2.log("pendle_live_pt_acquired_1e18=", ptOut);
        }

        // ---- Leg E: 40 % into Wombat 3-stable LP ----
        uint256 lpInUsdt = (usdtFromVai * LP_ALLOC_BPS) / 10_000;
        IERC20(BSC.USDT).approve(BSC.WOMBAT_MAIN_POOL, lpInUsdt);
        try IWombatPool(BSC.WOMBAT_MAIN_POOL).deposit(
            BSC.USDT, lpInUsdt, 0, address(this), block.timestamp + 1 hours, false
        ) returns (uint256 lp) {
            console2.log("wombat_lp_live_1e18=", lp);
        } catch {
            IERC20(BSC.USDT).transfer(address(0xdEaD), lpInUsdt);
            console2.log("wombat_lp_offline_modelled_1e18=", lpInUsdt);
        }

        // ---- 180-day carry projection ----
        uint256 venusSupplyYield = (SEED_USDC * VENUS_USDC_SUPPLY_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 vaiFee = (vaiMint * VAI_MINT_FEE_BPS) / 10_000; // one-shot fee
        uint256 ptYield = (ptInUsdt * PT_USDT_APR_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 wombatYield = (lpInUsdt * WOMBAT_STABLE_APR_BPS * HOLD_DAYS) / (10_000 * 365);

        _fund(BSC.USDC, address(this), venusSupplyYield);
        _fund(BSC.USDT, address(this), ptYield + wombatYield);
        // Set WOM oracle price for the PnL leg to count emissions.
        _setOraclePrice(BSC.WOM, 1e8);
        _fund(BSC.WOM, address(this), wombatYield / 2);
        // Debit VAI mint fee as VAI burn.
        uint256 vaiBal = IERC20(BSC.VAI).balanceOf(address(this));
        uint256 burnVai = vaiFee > vaiBal ? vaiBal : vaiFee;
        if (burnVai > 0) IERC20(BSC.VAI).transfer(address(0xdEaD), burnVai);

        console2.log("projection_venus_supply_yield_USDC_1e18=", venusSupplyYield);
        console2.log("projection_vai_mint_fee_1e18=", vaiFee);
        console2.log("projection_pt_yield_USDT_1e18=", ptYield);
        console2.log("projection_wombat_yield_USDT_1e18=", wombatYield);

        _endPnL("B15-10: Venus VAI + Pendle PT-USDT + Wombat stable stack");
    }

    // ---- Helpers ----

    function _wombatSwap(address from, address to, uint256 amt) internal returns (uint256 out) {
        if (amt == 0) return 0;
        IERC20(from).approve(BSC.WOMBAT_MAIN_POOL, amt);
        try IWombatPool(BSC.WOMBAT_MAIN_POOL).swap(
            from, to, amt, 0, address(this), block.timestamp + 1 hours
        ) returns (uint256 dy, uint256) {
            out = dy;
        } catch {
            IERC20(from).transfer(address(0xdEaD), amt);
            out = (amt * (10_000 - PCS_STABLE_HAIRCUT_BPS)) / 10_000;
            _fund(to, address(this), out);
        }
    }

    function _swapUsdtForPt(uint256 usdtIn) internal returns (uint256 ptOut) {
        if (usdtIn == 0) return 0;
        IERC20(BSC.USDT).approve(BSC.PENDLE_ROUTER_V4, usdtIn);
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: BSC.USDT,
            netTokenIn: usdtIn,
            tokenMintSy: BSC.USDT,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        IPendleRouter.LimitOrderData memory emptyLimit;
        try IPendleRouter(BSC.PENDLE_ROUTER_V4).swapExactTokenForPt(
            address(this), LOCAL_PT_USDT_MARKET, 0, approx, input, emptyLimit
        ) returns (uint256 _ptOut, uint256, uint256) {
            ptOut = _ptOut;
        } catch {
            ptOut = 0;
        }
    }
}
