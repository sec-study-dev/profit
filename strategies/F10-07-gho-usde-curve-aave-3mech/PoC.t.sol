// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";

/// @title F10-07 GHO mint + Curve GHO/USDe LP + Aave USDe borrow short (3-mechanism)
/// @notice Three-mechanism composition for a USDe-hedged GHO carry:
///         1) Aave V3 - GHO facilitator borrow (long GHO).
///         2) Curve GHO/USDe pool - LP for fee + CRV yield.
///         3) Aave V3 - USDe borrow against the *same* USDC collateral
///            (short USDe), used to hedge the USDe leg of the LP.
///
///         All Curve pool addresses are wrapped in try/catch - at the pinned
///         block the GHO/USDe pool may be the factory NG-stableswap
///         deployment whose address has historically shifted. The PoC reads
///         the pool's `coins(0)` / `coins(1)` to identify the canonical
///         ordering and emits a `pool_unavailable` log if neither
///         configuration matches.
contract F10_07_GhoUsdeCurveAave3Mech is StrategyBase {
    uint256 constant FORK_BLOCK = 20_800_000;

    uint256 constant RATE_MODE_VARIABLE = 2;

    // ---- Inlined Curve pool addresses (per Wave 4 constraint #3) ----

    /// @notice Curve GHO/USDe factory NG-stableswap pool (verified Q4 2024).
    ///         Address pulled from Curve registry; coin order discovered on-chain.
    address constant CURVE_GHO_USDE_POOL = 0x670a72e6D22b0956C0D2573288F82DCc5d6E3a61;

    /// @notice Curve USDC/USDe pool (used to detour USDC -> USDe for LP pairing).
    ///         Verified address; coin order [USDe, USDC] with int128 indices.
    address constant CURVE_USDC_USDE_POOL = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72;

    // ---- Notional sizing ----
    uint256 constant PRINCIPAL_USDC = 1_000_000e6;
    uint256 constant TARGET_GHO_BORROW = 500_000e18;
    uint256 constant TARGET_USDE_BORROW = 200_000e18;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.GHO);
        _trackToken(Mainnet.USDE);
        _trackToken(CURVE_GHO_USDE_POOL);
    }

    function testStrategy_F10_07() public {
        _fund(Mainnet.USDC, address(this), PRINCIPAL_USDC);

        _startPnL();

        IAavePool pool = IAavePool(Mainnet.AAVE_V3_POOL);

        // ---- Mechanism A: Aave supply USDC ----
        IERC20(Mainnet.USDC).approve(address(pool), type(uint256).max);
        // Keep 1 wei back for the touch tx.
        pool.supply(Mainnet.USDC, PRINCIPAL_USDC - 1, address(this), 0);

        // ---- Mechanism A.1: Borrow GHO (long leg) ----
        (, , uint256 availableBase, , , ) = pool.getUserAccountData(address(this));
        uint256 capGho = availableBase * 1e10;
        uint256 borrowGho = TARGET_GHO_BORROW;
        if (borrowGho > capGho) borrowGho = capGho;

        bool ghoOk = false;
        try pool.borrow(Mainnet.GHO, borrowGho, RATE_MODE_VARIABLE, 0, address(this)) {
            ghoOk = true;
        } catch {
            emit log("gho_borrow_failed");
        }

        if (!ghoOk) {
            vm.warp(block.timestamp + 30 days);
            vm.roll(block.number + (30 days / 12));
            _endPnL("F10-07: GHO+Curve+USDe-short (no GHO)");
            return;
        }

        uint256 ghoBal = IERC20(Mainnet.GHO).balanceOf(address(this));
        emit log_named_uint("gho_borrowed", ghoBal);

        // ---- Mechanism A.2: Borrow USDe (short hedge leg) ----
        (, , uint256 availableBase2, , , ) = pool.getUserAccountData(address(this));
        // USDe is 18-dec at $1. Cap = availableBase * 1e10 (same math as GHO).
        uint256 capUsde = availableBase2 * 1e10;
        uint256 borrowUsde = TARGET_USDE_BORROW;
        if (borrowUsde > capUsde) borrowUsde = capUsde;

        bool usdeOk = false;
        try pool.borrow(Mainnet.USDE, borrowUsde, RATE_MODE_VARIABLE, 0, address(this)) {
            usdeOk = true;
            uint256 usdeBal = IERC20(Mainnet.USDE).balanceOf(address(this));
            emit log_named_uint("usde_borrowed_hedge", usdeBal);
        } catch {
            emit log("usde_borrow_failed: cap or reserve mismatch");
        }

        // ---- Mechanism B: Pair half of GHO with USDe (from hedge borrow) into Curve LP ----
        // Use the borrowed USDe directly as the USDe leg of the LP.
        // Note: this leaves the USDe debt open (the hedge); the LP is composed
        // of GHO (half borrowed) and USDe (from hedge borrow). The remaining
        // half-GHO stays on balance to fund GHO debt service.
        uint256 ghoForLp = ghoBal / 2;
        uint256 usdeForLp = IERC20(Mainnet.USDE).balanceOf(address(this));

        // Inspect pool coin ordering - at this block coins(0) should be USDe
        // or GHO depending on factory-deployment convention.
        bool lpOk = false;
        uint256 lpMinted = 0;

        if (ghoForLp > 0 && usdeForLp > 0) {
            address coin0;
            address coin1;
            try ICurveStableSwap(CURVE_GHO_USDE_POOL).coins(0) returns (address c0) {
                coin0 = c0;
            } catch {}
            try ICurveStableSwap(CURVE_GHO_USDE_POOL).coins(1) returns (address c1) {
                coin1 = c1;
            } catch {}

            emit log_named_address("pool_coin0", coin0);
            emit log_named_address("pool_coin1", coin1);

            IERC20(Mainnet.GHO).approve(CURVE_GHO_USDE_POOL, type(uint256).max);
            IERC20(Mainnet.USDE).approve(CURVE_GHO_USDE_POOL, type(uint256).max);

            uint256[2] memory amts;
            if (coin0 == Mainnet.GHO && coin1 == Mainnet.USDE) {
                amts[0] = ghoForLp;
                amts[1] = usdeForLp;
            } else if (coin0 == Mainnet.USDE && coin1 == Mainnet.GHO) {
                amts[0] = usdeForLp;
                amts[1] = ghoForLp;
            } else {
                emit log("pool_coin_layout_mismatch");
            }

            if (amts[0] > 0 || amts[1] > 0) {
                try ICurveStableSwap(CURVE_GHO_USDE_POOL).add_liquidity(amts, 0) returns (uint256 minted) {
                    lpMinted = minted;
                    lpOk = true;
                    emit log_named_uint("curve_gho_usde_lp_minted", lpMinted);
                } catch {
                    emit log("curve_add_liquidity_failed");
                }
            }
        }

        // ---- Warp 30 days ----
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));

        // Touch reserve.
        deal(Mainnet.USDC, address(this), 1);
        pool.supply(Mainnet.USDC, 1, address(this), 0);

        // ---- Report position state & A1 equity credit ----
        _reportAndCredit();

        // Report LP virtual_price drift - surfaces fee accrual.
        try ICurveStableSwap(CURVE_GHO_USDE_POOL).get_virtual_price() returns (uint256 vp) {
            emit log_named_uint("curve_pool_virtual_price_post_warp", vp);
        } catch {
            emit log("virtual_price_unreadable");
        }

        // Sanity-flag the composition.
        emit log_named_uint("mech_a_aave_gho_ok", ghoOk ? 1 : 0);
        emit log_named_uint("mech_a_aave_usde_ok", usdeOk ? 1 : 0);
        emit log_named_uint("mech_b_curve_lp_ok", lpOk ? 1 : 0);

        _endPnL("F10-07: GHO + Curve GHO/USDe + Aave USDe short (3-mech)");
    }

    function _reportAndCredit() internal {
        (uint256 totalCollBase, uint256 totalDebtBase, , , , uint256 hf) =
            IAavePool(Mainnet.AAVE_V3_POOL).getUserAccountData(address(this));
        emit log_named_uint("aave_collateral_base_e8_usd", totalCollBase);
        emit log_named_uint("aave_debt_base_e8_usd", totalDebtBase);
        emit log_named_int(
            "aave_equity_base_e8_usd_signed",
            int256(totalCollBase) - int256(totalDebtBase)
        );
        emit log_named_uint("aave_health_factor_e18", hf);
        _creditPositionEquityE8(int256(totalCollBase) - int256(totalDebtBase));
    }
}
