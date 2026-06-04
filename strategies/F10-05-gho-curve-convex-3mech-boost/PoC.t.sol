// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IConvexBooster, IConvexBaseRewardPool} from "src/interfaces/bribe/IConvexBooster.sol";

/// @title F10-05 GHO mint + Curve GHO/USDC LP + Convex boost (3-mechanism)
/// @notice Three-mechanism composition:
///         1) Aave V3: supply USDC, borrow GHO at the facilitator rate.
///         2) Curve:   add_liquidity into the GHO/USDC stableswap pool to
///                     capture swap-fee + CRV-gauge yield.
///         3) Convex:  deposit the LP into Booster to inherit the boosted
///                     CRV emissions + Convex's CVX rewards.
///
///         Each leg is wrapped in try/catch so a failure on any one mechanism
///         (e.g. Convex PID missing at this block) emits a log and falls
///         through to the next layer's PnL - the test still surfaces the
///         healthy legs' results.
contract F10_05_GhoCurveConvex3MechBoost is StrategyBase {
    uint256 constant FORK_BLOCK = 20_900_000;

    uint256 constant RATE_MODE_VARIABLE = 2;

    // ---- Inlined addresses (per Wave 4 constraint #3) ----

    /// @notice Curve GHO/USDC NG-stableswap pool (factory deployment).
    ///         coins[0] = GHO (18d), coins[1] = USDC (6d).
    address constant CURVE_GHO_USDC_POOL = 0x635EF0056A597D13863B73825CcA297236578595;

    /// @notice CRV reward token (standard).
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;

    /// @notice Convex Booster - canonical mainnet. Inlined here per Wave 4
    ///         constraint #3 (also matches Mainnet.CONVEX_BOOSTER for cross-ref).
    address constant CVX_BOOSTER = 0xF403C135812408BFbE8713b5A23a04b3D48AAE31;

    /// @notice Notional principal.
    uint256 constant PRINCIPAL_USDC = 1_000_000e6;

    /// @notice USDC reserve to pair with borrowed GHO in the LP.
    uint256 constant LP_USDC_PAIR = 700_000e6;

    /// @notice Target GHO borrow (capped on-chain by availableBorrowsBase).
    uint256 constant TARGET_GHO_BORROW = 700_000e18;

    /// @notice Warp duration - one Convex epoch.
    uint256 constant WARP_DURATION = 14 days;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.GHO);
        _trackToken(CURVE_GHO_USDC_POOL);
        _trackToken(CRV);
        _trackToken(Mainnet.CVX);
    }

    function testStrategy_F10_05() public {
        _fund(Mainnet.USDC, address(this), PRINCIPAL_USDC);

        _startPnL();

        IAavePool pool = IAavePool(Mainnet.AAVE_V3_POOL);

        // ---- 1. Mechanism 1: Aave supply USDC, borrow GHO ----
        IERC20(Mainnet.USDC).approve(address(pool), type(uint256).max);
        uint256 suppliedUsdc = PRINCIPAL_USDC - LP_USDC_PAIR;
        pool.supply(Mainnet.USDC, suppliedUsdc, address(this), 0);

        (, , uint256 availableBase, , , ) = pool.getUserAccountData(address(this));
        // availableBase is 1e8 USD; GHO is 18-dec at $1.
        uint256 capGho = availableBase * 1e10;
        uint256 borrowGho = TARGET_GHO_BORROW;
        if (borrowGho > capGho) borrowGho = capGho;

        bool ghoOk = false;
        try pool.borrow(Mainnet.GHO, borrowGho, RATE_MODE_VARIABLE, 0, address(this)) {
            ghoOk = true;
        } catch {
            emit log("gho_borrow_failed: bucket capacity exhausted at this block");
            _endPnL("F10-05: GHO + Curve + Convex (skipped at Aave leg)");
            return;
        }

        uint256 ghoBal = IERC20(Mainnet.GHO).balanceOf(address(this));
        emit log_named_uint("aave_gho_borrowed", ghoBal);

        // ---- 2. Mechanism 2: Curve GHO/USDC add_liquidity ----
        IERC20(Mainnet.GHO).approve(CURVE_GHO_USDC_POOL, type(uint256).max);
        IERC20(Mainnet.USDC).approve(CURVE_GHO_USDC_POOL, type(uint256).max);

        // Curve NG-stableswap factory pools use [2]-element add_liquidity for 2-coin pools.
        // coin order: [GHO, USDC] as published on the pool.
        uint256 usdcPair = IERC20(Mainnet.USDC).balanceOf(address(this));
        if (usdcPair > LP_USDC_PAIR) usdcPair = LP_USDC_PAIR;

        uint256[2] memory amts;
        amts[0] = ghoBal;
        amts[1] = usdcPair;

        uint256 lpReceived = 0;
        try ICurveStableSwap(CURVE_GHO_USDC_POOL).add_liquidity(amts, 0) returns (uint256 minted) {
            lpReceived = minted;
            emit log_named_uint("curve_lp_minted", lpReceived);
        } catch {
            emit log("curve_add_liquidity_failed: coin order or pool layout mismatch");
            // Fall through to warp / report - GHO debt still accrues, no LP yield.
        }

        // ---- 3. Mechanism 3: Convex Booster stake ----
        // Dynamically discover the PID for this LP token. Convex PIDs can shift
        // when pools are re-registered.
        bool convexOk = false;
        address baseRewardPool;
        uint256 discoveredPid = type(uint256).max;

        if (lpReceived > 0) {
            uint256 nPools = IConvexBooster(CVX_BOOSTER).poolLength();
            // Convex PID space at block 20.9M is ~400; only scan the newest
            // 100 PIDs to find a recent registration without OOG. GHO/USDC was
            // registered in late 2024, well within the most-recent slice.
            uint256 scanStart = nPools;
            uint256 scanFloor = nPools > 100 ? nPools - 100 : 0;
            for (uint256 pid = scanStart; pid > scanFloor; pid--) {
                uint256 idx = pid - 1;
                try IConvexBooster(CVX_BOOSTER).poolInfo(idx) returns (
                    IConvexBooster.PoolInfo memory pi
                ) {
                    if (pi.lptoken == CURVE_GHO_USDC_POOL && !pi.shutdown) {
                        discoveredPid = idx;
                        baseRewardPool = pi.crvRewards;
                        break;
                    }
                } catch {
                    // Some PIDs may revert; skip and continue scan.
                }
            }

            if (discoveredPid != type(uint256).max) {
                IERC20(CURVE_GHO_USDC_POOL).approve(CVX_BOOSTER, type(uint256).max);
                try IConvexBooster(CVX_BOOSTER).deposit(discoveredPid, lpReceived, true) returns (bool ok) {
                    convexOk = ok;
                    if (ok) {
                        emit log_named_uint("convex_pid", discoveredPid);
                        emit log_named_address("convex_base_reward_pool", baseRewardPool);
                    } else {
                        emit log("convex_deposit_returned_false");
                    }
                } catch {
                    emit log("convex_deposit_reverted");
                }
            } else {
                emit log("convex_pid_unavailable_at_block");
            }
        }

        // ---- 4. Warp 14 days (one epoch) ----
        vm.warp(block.timestamp + WARP_DURATION);
        vm.roll(block.number + (WARP_DURATION / 12));

        // ---- 5. Claim Convex rewards ----
        if (convexOk && baseRewardPool != address(0)) {
            uint256 earnedCrv = IConvexBaseRewardPool(baseRewardPool).earned(address(this));
            emit log_named_uint("convex_crv_earned_pre_claim", earnedCrv);
            try IConvexBaseRewardPool(baseRewardPool).getReward(address(this), true) returns (bool) {
                uint256 crvBal = IERC20(CRV).balanceOf(address(this));
                uint256 cvxBal = IERC20(Mainnet.CVX).balanceOf(address(this));
                emit log_named_uint("crv_claimed", crvBal);
                emit log_named_uint("cvx_claimed", cvxBal);
            } catch {
                emit log("convex_getReward_failed");
            }

            // Withdraw LP back from Convex for clean PnL accounting.
            try IConvexBaseRewardPool(baseRewardPool).withdrawAndUnwrap(lpReceived, false) returns (bool) {
                // ok
            } catch {
                emit log("convex_withdraw_failed");
            }
        }

        // ---- 6. Touch Aave reserve to crystallise indices ----
        // Re-supply any leftover USDC; if all USDC was used in LP pairing this may revert.
        uint256 leftoverUsdc = IERC20(Mainnet.USDC).balanceOf(address(this));
        if (leftoverUsdc >= 1) {
            try pool.supply(Mainnet.USDC, leftoverUsdc, address(this), 0) {} catch {}
        }

        // ---- 7. Report position state & A1 equity credit (BEFORE any further state changes) ----
        _reportAndCredit();

        // Report LP balance still held (if Convex leg failed).
        emit log_named_uint("residual_lp_balance", IERC20(CURVE_GHO_USDC_POOL).balanceOf(address(this)));

        _endPnL("F10-05: GHO mint + Curve GHO/USDC + Convex boost (3-mech)");
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
