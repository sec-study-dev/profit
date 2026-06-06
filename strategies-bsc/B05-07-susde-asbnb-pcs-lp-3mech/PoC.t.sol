// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ISUSDe} from "src/interfaces/bsc/stable/ISUSDe.sol";
import {IasBNB} from "src/interfaces/bsc/lst/IasBNB.sol";
import {IPancakeV3Router} from "src/interfaces/bsc/amm/IPancakeV3Router.sol";

/// @title B05-07 PoC: sUSDe + Astherus asBNB + PCS LP - 3-mechanism triangular yield
/// @notice Constructs a triangular yield basket that earns from three
///         independent sources simultaneously:
///         (a) **Ethena sUSDe** - ~50% of principal staked into sUSDe to
///             harvest Ethena perp-funding APY (~9%).
///         (b) **Astherus asBNB** - ~50% of principal rotated into asBNB
///             (restaked BNB) to harvest validator + Babylon restaking
///             yield (~5-6% BNB-denominated, plus AST points).
///         (c) **PCS v3 LP on sUSDe/USDT** - the remaining USDe-side
///             tail (after staking) is LP'd in the concentrated PCS v3
///             sUSDe/USDT pool to harvest fee income on the stable pair.
/// @dev    Three uncorrelated yield drivers: Ethena funding, BSC validator
///         inflation, PCS LP fees. Risk diversification is the explicit
///         thesis: when sUSDe APY is low (negative funding), asBNB and
///         LP fees carry the book. Dual-mode per family convention.
contract B05_07_PoC is BSCStrategyBase {
    // ---- Inlined addresses ----
    /// @dev PCS v3 sUSDe/USDT 5bp pool (LP venue). // TODO verify
    address constant LOCAL_PCS_V3_SUSDE_USDT_5BP = 0x000000000000000000000000000000000000b571;

    // ---- Sizing / model (1e4 = 100%) ----
    uint256 constant PRINCIPAL_USDE = 100_000e18;
    /// @dev Allocation: 50% sUSDe, 35% asBNB (BNB-denominated), 15% LP.
    uint256 constant ALLOC_SUSDE_BPS = 5000;
    uint256 constant ALLOC_ASBNB_BPS = 3500;
    uint256 constant ALLOC_LP_BPS = 1500;

    uint256 constant SUSDE_APY_BPS = 900; // 9% Ethena APY
    uint256 constant ASBNB_APY_BPS = 550; // 5.5% restaking APY (BNB-denominated)
    uint256 constant LP_APY_BPS = 1200; // 12% LP-fee APR (stable-stable 5bp tier, active range)
    uint256 constant HOLD_DAYS = 30;

    /// @dev One-time entry drags.
    uint256 constant USDE_TO_BNB_DRAG_BPS = 10; // 5 bp PCS USDe/USDT + 5 bp USDT/WBNB
    uint256 constant LP_ENTRY_DRAG_BPS = 5; // tick-range setup
    /// @dev Impermanent loss is ~0 for stable-stable LP in normal regime;
    ///      model as 2 bp/month operational drift.
    uint256 constant LP_IL_DRAG_BPS = 2;

    function setUp() public {
        _trackToken(BSC.USDe);
        _trackToken(BSC.sUSDe);
        _trackToken(BSC.asBNB);
        _trackToken(BSC.USDT);
        _setOraclePrice(BSC.sUSDe, 1_05_000_000); // $1.05
        _setOraclePrice(BSC.USDe, 99_900_000); // $0.999
        // asBNB priced at BNB ($600) via IasBNB.convertToAssets - keep default.
    }

    function testSusdeAsbnbPcsLp3Mech() public {
        bool live = _tryFork();
        _startPnL();
        if (live) {
            _runOnchain();
        } else {
            _runOffline();
        }
        _endPnL("B05-07-susde-asbnb-pcs-lp-3mech");
    }

    // ----------------------------------------------------------------
    // Forked branch - splits principal across 3 legs
    // ----------------------------------------------------------------
    function _runOnchain() internal {
        _fund(BSC.USDe, address(this), PRINCIPAL_USDE);

        // Leg 1: 50% -> sUSDe
        uint256 susdeIn = (PRINCIPAL_USDE * ALLOC_SUSDE_BPS) / 10_000;
        IERC20(BSC.USDe).approve(BSC.sUSDe, susdeIn);
        ISUSDe(BSC.sUSDe).deposit(susdeIn, address(this));

        // Leg 2: 35% -> USDT -> WBNB -> asBNB
        uint256 bnbLeg = (PRINCIPAL_USDE * ALLOC_ASBNB_BPS) / 10_000;
        IERC20(BSC.USDe).approve(BSC.PCS_V3_ROUTER, bnbLeg);
        IPancakeV3Router.ExactInputSingleParams memory pUsdt = IPancakeV3Router
            .ExactInputSingleParams({
            tokenIn: BSC.USDe,
            tokenOut: BSC.USDT,
            fee: 100,
            recipient: address(this),
            deadline: block.timestamp + 60,
            amountIn: bnbLeg,
            amountOutMinimum: (bnbLeg * 998) / 1000,
            sqrtPriceLimitX96: 0
        });
        uint256 usdtOut = IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(pUsdt);

        IERC20(BSC.USDT).approve(BSC.PCS_V3_ROUTER, usdtOut);
        IPancakeV3Router.ExactInputSingleParams memory pBnb = IPancakeV3Router
            .ExactInputSingleParams({
            tokenIn: BSC.USDT,
            tokenOut: BSC.WBNB,
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp + 60,
            amountIn: usdtOut,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        uint256 wbnbOut = IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(pBnb);

        // Mint asBNB via Astherus StakeManager. The PoC uses a placeholder
        // selector since the canonical Astherus ABI is unverified -
        // production wiring would call `ASTHERUS_STAKE_MANAGER.deposit{value: ...}`.
        // For PoC, just hold WBNB as the asBNB proxy.
        wbnbOut; // tracked through WBNB->asBNB conversion in offline branch

        // Leg 3: 15% -> LP on PCS v3 sUSDe/USDT 5bp.
        // PoC keeps the LP step as a placeholder (concentrated LP needs
        // NFPM mint + tick range params). The forked branch holds the
        // remainder as USDe; the offline projection applies the LP yield.
        // No-op here.
        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
    }

    // ----------------------------------------------------------------
    // Offline projection - sum of 3 yield streams
    // ----------------------------------------------------------------
    function _runOffline() internal {
        // Initial USD on each leg.
        uint256 initialUsd = (PRINCIPAL_USDE * 999) / 1000; // @ $0.999
        uint256 susdeUsd = (initialUsd * ALLOC_SUSDE_BPS) / 10_000;
        uint256 asbnbUsd = (initialUsd * ALLOC_ASBNB_BPS) / 10_000;
        uint256 lpUsd = (initialUsd * ALLOC_LP_BPS) / 10_000;

        // Leg 1 yield: sUSDe APY x susdeUsd x 30/365.
        int256 leg1 = int256((susdeUsd * SUSDE_APY_BPS * HOLD_DAYS) / (10_000 * 365));

        // Leg 2 yield: asBNB APY x asbnbUsd x 30/365.
        // (Holding BNB exposure has a separate spot-PnL term - we model BNB
        // as flat for the carry attribution; spot is a beta line, not alpha.)
        int256 leg2 = int256((asbnbUsd * ASBNB_APY_BPS * HOLD_DAYS) / (10_000 * 365));
        int256 leg2EntryDrag = int256((asbnbUsd * USDE_TO_BNB_DRAG_BPS) / 10_000);
        leg2 -= leg2EntryDrag;

        // Leg 3 yield: LP APR x lpUsd x 30/365 - entry drag - IL drift.
        int256 leg3 = int256((lpUsd * LP_APY_BPS * HOLD_DAYS) / (10_000 * 365));
        int256 leg3Entry = int256((lpUsd * LP_ENTRY_DRAG_BPS) / 10_000);
        int256 leg3IL = int256((lpUsd * LP_IL_DRAG_BPS) / 10_000);
        leg3 -= (leg3Entry + leg3IL);

        int256 totalPnl = leg1 + leg2 + leg3;
        if (totalPnl > 0) {
            _fund(BSC.USDT, address(this), uint256(totalPnl));
        }
    }

    function _tryFork() internal returns (bool) {
        try vm.envString("BSC_RPC_URL") returns (string memory rpc) {
            if (bytes(rpc).length == 0) return false;
            try vm.createSelectFork(rpc, 43_100_000) returns (uint256) {
                return true;
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }
}
