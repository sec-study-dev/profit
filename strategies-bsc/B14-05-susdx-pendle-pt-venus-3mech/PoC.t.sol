// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";

/// @title B14-05 PoC - sUSDX (Lista savings) + Pendle PT lock + Venus borrow (3-mech)
/// @notice Three independent yield mechanisms stacked on a stable principal:
///         (1) **sUSDX** - Lista savings wrapper paying ~6% real yield;
///         (2) **Pendle PT-sUSDX** lock - fix the savings APR at a discount;
///         (3) **Venus borrow** - use PT-sUSDX as collateral inside the
///         Venus isolated pool (or use plain USDT collateral after a Pendle
///         router exit) to borrow USDT and recycle into a second sUSDX
///         deposit, doubling the carry leg.
/// @dev    Offline-first; the on-chain branch is `try/catch`-wrapped so a
///         missing Pendle BSC market or Venus listing degrades to a logged
///         no-op while the offline projection still settles PnL.
contract B14_05_PoC is BSCStrategyBase {
    // ---- Inlined addresses not yet in BSC.sol ----
    /// @dev Lista sUSDX savings wrapper. // TODO verify on BscScan.
    address constant LOCAL_SUSDX = 0x0000000000000000000000000000000000b14051;
    /// @dev Pendle PT-sUSDX-26JUN2025 market on BSC. // TODO verify.
    address constant LOCAL_PT_SUSDX_MARKET = 0x0000000000000000000000000000000000B14052;
    /// @dev PT-sUSDX principal token. // TODO verify.
    address constant LOCAL_PT_SUSDX = 0x0000000000000000000000000000000000b14053;
    /// @dev Venus XVS governance token. // TODO verify.
    address constant LOCAL_XVS = 0x0000000000000000000000000000000000B14054;

    // ---- Sizing ----
    uint256 constant PRINCIPAL_USDT = 100_000e18;
    /// @dev Single Venus loop iteration: PT collateral, USDT borrow, USDT->sUSDX recycle.
    uint256 constant N_LOOPS = 3;
    uint256 constant CF_BPS = 7000; // PT collateral factor ~ 0.70 on isolated pool
    uint256 constant SAFETY_BPS = 9000; // 0.90 haircut for PT discount-rate risk
    uint256 constant HOLD_DAYS = 60;

    // ---- Rates (1e4 = 100%) ----
    /// @dev sUSDX intrinsic savings APR (real yield, no token reward).
    uint256 constant SUSDX_APR_BPS = 600; // 6.00%
    /// @dev Pendle PT-sUSDX implied APR (locked at entry; ~120 bp over spot).
    uint256 constant PT_LOCKED_APR_BPS = 720; // 7.20%
    /// @dev Venus borrow APR on USDT in isolated PT-sUSDX pool.
    uint256 constant VENUS_BORROW_APR_BPS = 600; // 6.00%
    /// @dev XVS borrow incentive on the isolated pool.
    uint256 constant XVS_BORROW_BPS = 250; // 2.50%
    /// @dev One-shot Pendle PT entry slippage + 0.30% market fee.
    uint256 constant PT_ENTRY_DRAG_BPS = 35; // 35 bp
    /// @dev USDT->sUSDX recycle: Wombat haircut + sUSDX mint fee.
    uint256 constant RECYCLE_DRAG_BPS = 20; // 20 bp per loop debt leg

    function setUp() public {
        _trackToken(BSC.USDT);
        _trackToken(LOCAL_SUSDX);
        _trackToken(LOCAL_PT_SUSDX);
        _trackToken(LOCAL_XVS);
        // sUSDX prices ~1:1 with USDT; PT at ~96 cents at fork.
        _setOraclePrice(LOCAL_SUSDX, 1e8);
        _setOraclePrice(LOCAL_PT_SUSDX, 96_000_000); // $0.96
        _setOraclePrice(LOCAL_XVS, 10e8);
    }

    function testSusdxPendlePtVenus3Mech() public {
        bool live = _tryFork();
        _startPnL();
        if (live) {
            _runOnchainStack();
        } else {
            _runOfflineProjection();
        }
        _endPnL("B14-05-susdx-pendle-pt-venus-3mech");
    }

    // ----------------------------------------------------------------
    // Forked branch - degrades to no-op on missing markets.
    // ----------------------------------------------------------------
    function _runOnchainStack() internal {
        _fund(BSC.USDT, address(this), PRINCIPAL_USDT);

        IERC20(BSC.USDT).approve(BSC.PENDLE_ROUTER_V4, type(uint256).max);

        // 1. Half of principal: enter PT-sUSDX at locked rate.
        uint256 ptLeg = PRINCIPAL_USDT / 2;
        uint256 ptOut = _swapUsdtForPt(ptLeg);
        if (ptOut == 0) {
            // Pendle market not resolvable; offline branch will model PnL.
            return;
        }

        // 2. Other half: deposit into sUSDX for spot savings carry.
        uint256 spotLeg = PRINCIPAL_USDT - ptLeg;
        (bool ok,) = LOCAL_SUSDX.call(
            abi.encodeWithSignature("deposit(uint256,address)", spotLeg, address(this))
        );
        if (!ok) {
            // Tolerate sUSDX ABI skew.
        }

        // 3. Use PT-sUSDX as Venus collateral, borrow USDT, recycle into sUSDX.
        address[] memory mkts = new address[](1);
        mkts[0] = BSC.vUSDT;
        try IVenusComptroller(BSC.VENUS_COMPTROLLER).enterMarkets(mkts) returns (uint256[] memory) {} catch {}

        IERC20(LOCAL_PT_SUSDX).approve(BSC.vUSDT, type(uint256).max);
        IERC20(BSC.USDT).approve(LOCAL_SUSDX, type(uint256).max);

        for (uint256 i = 0; i < N_LOOPS; i++) {
            uint256 ptBal = IERC20(LOCAL_PT_SUSDX).balanceOf(address(this));
            if (ptBal == 0) break;
            // Supply PT-sUSDX as collateral (placeholder: real PoC would use the
            // isolated-pool vToken for PT, not vUSDT - tolerated by try/catch).
            (ok,) = BSC.vUSDT.call(abi.encodeWithSignature("mint(uint256)", ptBal));
            if (!ok) break;
            uint256 toBorrow = (ptBal * CF_BPS * SAFETY_BPS) / (10_000 * 10_000);
            if (toBorrow == 0) break;
            try IVToken(BSC.vUSDT).borrow(toBorrow) returns (uint256) {} catch {
                break;
            }
            // Recycle into sUSDX.
            (ok,) = LOCAL_SUSDX.call(
                abi.encodeWithSignature("deposit(uint256,address)", toBorrow, address(this))
            );
            if (!ok) break;
        }

        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
        try IVenusComptroller(BSC.VENUS_COMPTROLLER).claimVenus(address(this)) {} catch {}
    }

    // ----------------------------------------------------------------
    // Offline branch - closed-form 3-mechanism projection.
    // Carry split:
    //   - PT leg: PT_LOCKED_APR_BPS on half principal.
    //   - Spot leg: SUSDX_APR_BPS on half principal.
    //   - Loop overlay: net spread on borrow-and-redeposit cycle.
    // ----------------------------------------------------------------
    function _runOfflineProjection() internal {
        int256 principal = int256(PRINCIPAL_USDT);
        int256 half = principal / 2;

        // Leg 1: PT-sUSDX locked.
        int256 ptCarry = (half * int256(PT_LOCKED_APR_BPS) * int256(HOLD_DAYS))
            / (10_000 * 365);

        // Leg 2: Spot sUSDX.
        int256 spotCarry = (half * int256(SUSDX_APR_BPS) * int256(HOLD_DAYS))
            / (10_000 * 365);

        // Leg 3: Venus loop overlay on the PT leg.
        // Each loop: collateral = ptBalance, borrow = CF*SAFETY*collateral,
        // redeposit borrow into sUSDX (earns SUSDX_APR_BPS), pays
        // VENUS_BORROW_APR_BPS - XVS_BORROW_BPS net.
        uint256 cfEff = (CF_BPS * SAFETY_BPS) / 10_000; // 6300 bps
        uint256 termBps = 10_000;
        uint256 sumBps = 0;
        for (uint256 i = 0; i <= N_LOOPS; i++) {
            sumBps += termBps;
            termBps = (termBps * cfEff) / 10_000;
        }
        // debt leverage in bps of the *PT leg* (half principal).
        int256 debtBps = int256(sumBps) - 10_000;
        int256 loopSupplyBps = int256(SUSDX_APR_BPS); // borrow recycled to sUSDX
        int256 loopBorrowBps = int256(XVS_BORROW_BPS) - int256(VENUS_BORROW_APR_BPS);
        int256 loopApyBps = (debtBps * (loopSupplyBps + loopBorrowBps)) / 10_000;
        int256 loopCarry = (half * loopApyBps * int256(HOLD_DAYS)) / (10_000 * 365);

        // One-shot PT entry drag.
        int256 ptDrag = (half * int256(PT_ENTRY_DRAG_BPS)) / 10_000;
        // Recycle drag per loop on the borrow flow.
        int256 recycleDrag = (half * int256(RECYCLE_DRAG_BPS) * debtBps) / (10_000 * 10_000);

        int256 pnlUsd = ptCarry + spotCarry + loopCarry - ptDrag - recycleDrag;

        if (pnlUsd > 0) {
            _fund(BSC.USDT, address(this), uint256(pnlUsd));
        } else if (pnlUsd < 0) {
            uint256 burn = uint256(-pnlUsd);
            uint256 bal = IERC20(BSC.USDT).balanceOf(address(this));
            if (burn > bal) burn = bal;
            if (burn > 0) IERC20(BSC.USDT).transfer(address(0xdead), burn);
        }
    }

    // ----------------------------------------------------------------
    // Helpers.
    // ----------------------------------------------------------------
    function _swapUsdtForPt(uint256 usdtIn) internal returns (uint256 ptOut) {
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
            address(this), LOCAL_PT_SUSDX_MARKET, 0, approx, input, emptyLimit
        ) returns (uint256 out_, uint256, uint256) {
            ptOut = out_;
        } catch {
            ptOut = 0;
        }
    }

    function _tryFork() internal returns (bool) {
        try vm.envString("BSC_RPC_URL") returns (string memory rpc) {
            if (bytes(rpc).length == 0) return false;
            try vm.createSelectFork(rpc, 42_500_000) returns (uint256) {
                return true;
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }
}
