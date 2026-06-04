// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IConvexBooster, IConvexBaseRewardPool} from "src/interfaces/bribe/IConvexBooster.sol";

/// @notice Curve NG-stableswap uses dynamic-length arrays; not captured in ICurveStableSwap.
interface ICurveNG {
    function add_liquidity(uint256[] calldata amounts, uint256 min_mint_amount) external returns (uint256);
    function remove_liquidity(uint256 lp_amount, uint256[] calldata min_amounts) external returns (uint256[] memory);
    function get_virtual_price() external view returns (uint256);
    function coins(uint256 i) external view returns (address);
}

/// @title F10-05 GHO mint + Curve GHO/crvUSD LP + Convex boost (3-mechanism)
/// @notice Three-mechanism composition:
///         1) Aave V3: supply USDC, borrow GHO at the facilitator rate.
///         2) Curve:   add_liquidity into the GHO/crvUSD NG-stableswap pool to
///                     capture swap-fee + CRV-gauge yield.
///         3) Convex:  deposit the LP into Booster to inherit the boosted
///                     CRV emissions + Convex's CVX rewards.
///
///         Each leg is wrapped in try/catch so a failure on any one mechanism
///         (e.g. Convex PID missing at this block) emits a log and falls
///         through to the next layer's PnL - the test still surfaces the
///         healthy legs' results.
///
///         Unwind: Convex withdraw -> Curve remove_liquidity -> repay GHO -> withdraw USDC.
contract F10_05_GhoCurveConvex3MechBoost is StrategyBase {
    uint256 constant FORK_BLOCK = 20_900_000;

    uint256 constant RATE_MODE_VARIABLE = 2;

    // ---- Inlined addresses (per Wave 4 constraint #3) ----

    /// @notice Curve GHO/crvUSD NG-stableswap pool (factory deployment).
    ///         Verified on-chain: coins[0] = GHO (18d), coins[1] = crvUSD (18d).
    address constant CURVE_GHO_CRVUSD_POOL = 0x635EF0056A597D13863B73825CcA297236578595;

    /// @notice CRV reward token (standard).
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;

    /// @notice Convex Booster - canonical mainnet.
    address constant CVX_BOOSTER = 0xF403C135812408BFbE8713b5A23a04b3D48AAE31;

    /// @notice Notional principal.
    uint256 constant PRINCIPAL_USDC = 1_000_000e6;

    /// @notice crvUSD to pair with borrowed GHO (funded via deal as yield source).
    uint256 constant CRVUSD_LP_PAIR = 500_000e18;

    /// @notice Target GHO borrow (capped on-chain by availableBorrowsBase).
    uint256 constant TARGET_GHO_BORROW = 500_000e18;

    /// @notice Warp duration - one Convex epoch.
    uint256 constant WARP_DURATION = 14 days;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.GHO);
        _trackToken(CURVE_GHO_CRVUSD_POOL);
        _trackToken(CRV);
        _trackToken(Mainnet.CVX);
    }

    function testStrategy_F10_05() public {
        _fund(Mainnet.USDC, address(this), PRINCIPAL_USDC);
        _fund(Mainnet.CRVUSD, address(this), CRVUSD_LP_PAIR);

        _startPnL();

        IAavePool pool = IAavePool(Mainnet.AAVE_V3_POOL);

        // ---- 1. Mechanism 1: Aave supply USDC, borrow GHO ----
        IERC20(Mainnet.USDC).approve(address(pool), type(uint256).max);
        pool.supply(Mainnet.USDC, PRINCIPAL_USDC, address(this), 0);

        uint256 borrowGho = TARGET_GHO_BORROW;
        {
            (, , uint256 availableBase, , , ) = pool.getUserAccountData(address(this));
            uint256 capGho = availableBase * 1e10;
            if (borrowGho > capGho) borrowGho = capGho;
        }

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

        // ---- 2. Mechanism 2: Curve GHO/crvUSD add_liquidity (NG-stableswap) ----
        ICurveNG curvePool = ICurveNG(CURVE_GHO_CRVUSD_POOL);
        IERC20(Mainnet.GHO).approve(CURVE_GHO_CRVUSD_POOL, type(uint256).max);
        IERC20(Mainnet.CRVUSD).approve(CURVE_GHO_CRVUSD_POOL, type(uint256).max);

        // coins[0]=GHO, coins[1]=crvUSD (confirmed on-chain at this block).
        uint256[] memory amts = new uint256[](2);
        amts[0] = ghoBal;
        amts[1] = IERC20(Mainnet.CRVUSD).balanceOf(address(this));

        uint256 lpReceived = 0;
        try curvePool.add_liquidity(amts, 0) returns (uint256 minted) {
            lpReceived = minted;
            emit log_named_uint("curve_lp_minted", lpReceived);
        } catch {
            emit log("curve_add_liquidity_failed");
        }

        // ---- 3. Mechanism 3: Convex Booster stake ----
        bool convexOk = false;
        address baseRewardPool;
        uint256 discoveredPid = type(uint256).max;

        if (lpReceived > 0) {
            discoveredPid = _findConvexPid(CVX_BOOSTER, CURVE_GHO_CRVUSD_POOL);
            if (discoveredPid != type(uint256).max) {
                (,,,address crvRewards,) = _getPoolInfo(CVX_BOOSTER, discoveredPid);
                baseRewardPool = crvRewards;
                IERC20(CURVE_GHO_CRVUSD_POOL).approve(CVX_BOOSTER, type(uint256).max);
                try IConvexBooster(CVX_BOOSTER).deposit(discoveredPid, lpReceived, true) returns (bool ok) {
                    convexOk = ok;
                    if (ok) {
                        emit log_named_uint("convex_pid", discoveredPid);
                        emit log_named_address("convex_base_reward_pool", baseRewardPool);
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
            _claimAndUnstakeConvex(baseRewardPool, lpReceived);
        }

        // ---- 6. Remove Curve liquidity ----
        uint256 lpBal = IERC20(CURVE_GHO_CRVUSD_POOL).balanceOf(address(this));
        if (lpBal > 0) {
            uint256[] memory minOut = new uint256[](2);
            try curvePool.remove_liquidity(lpBal, minOut) returns (uint256[] memory) {
                emit log_named_uint("gho_from_lp", IERC20(Mainnet.GHO).balanceOf(address(this)));
                emit log_named_uint("crvusd_from_lp", IERC20(Mainnet.CRVUSD).balanceOf(address(this)));
            } catch {
                emit log("curve_remove_liquidity_failed");
            }
        }

        // ---- 7. Repay GHO debt, withdraw USDC ----
        {
            uint256 ghoBal2 = IERC20(Mainnet.GHO).balanceOf(address(this));
            if (ghoBal2 > 0) {
                IERC20(Mainnet.GHO).approve(address(pool), ghoBal2);
                try pool.repay(Mainnet.GHO, ghoBal2, RATE_MODE_VARIABLE, address(this)) {} catch {}
            }
        }
        try pool.withdraw(Mainnet.USDC, type(uint256).max, address(this)) {} catch {}

        // ---- 8. Report ----
        _reportAavePosition(pool);
        emit log_named_uint("crv_balance", IERC20(CRV).balanceOf(address(this)));
        emit log_named_uint("cvx_balance", IERC20(Mainnet.CVX).balanceOf(address(this)));
        emit log_named_uint("residual_lp_balance", IERC20(CURVE_GHO_CRVUSD_POOL).balanceOf(address(this)));

        _endPnL("F10-05: GHO mint + Curve GHO/crvUSD + Convex boost (3-mech)");
    }

    function _findConvexPid(address booster, address lpToken) internal returns (uint256) {
        uint256 nPools = IConvexBooster(booster).poolLength();
        uint256 scanStart = nPools;
        uint256 scanFloor = nPools > 100 ? nPools - 100 : 0;
        for (uint256 pid = scanStart; pid > scanFloor; pid--) {
            uint256 idx = pid - 1;
            try IConvexBooster(booster).poolInfo(idx) returns (IConvexBooster.PoolInfo memory pi) {
                if (pi.lptoken == lpToken && !pi.shutdown) {
                    return idx;
                }
            } catch {}
        }
        return type(uint256).max;
    }

    function _getPoolInfo(address booster, uint256 pid) internal view returns (
        address lptoken, address token, address gauge, address crvRewards, bool shutdown
    ) {
        IConvexBooster.PoolInfo memory pi = IConvexBooster(booster).poolInfo(pid);
        return (pi.lptoken, pi.token, pi.gauge, pi.crvRewards, pi.shutdown);
    }

    function _claimAndUnstakeConvex(address baseRewardPool, uint256 lpReceived) internal {
        uint256 earnedCrv = IConvexBaseRewardPool(baseRewardPool).earned(address(this));
        emit log_named_uint("convex_crv_earned_pre_claim", earnedCrv);
        try IConvexBaseRewardPool(baseRewardPool).getReward(address(this), true) returns (bool) {
            emit log_named_uint("crv_claimed", IERC20(CRV).balanceOf(address(this)));
            emit log_named_uint("cvx_claimed", IERC20(Mainnet.CVX).balanceOf(address(this)));
        } catch {
            emit log("convex_getReward_failed");
        }
        try IConvexBaseRewardPool(baseRewardPool).withdrawAndUnwrap(lpReceived, false) returns (bool) {
            // ok
        } catch {
            emit log("convex_withdraw_failed");
        }
    }

    function _reportAavePosition(IAavePool pool) internal {
        (uint256 totalCollBase, uint256 totalDebtBase, , , , uint256 hf) =
            pool.getUserAccountData(address(this));
        emit log_named_uint("aave_collateral_base_e8_usd", totalCollBase);
        emit log_named_uint("aave_debt_base_e8_usd", totalDebtBase);
        emit log_named_int(
            "aave_equity_base_e8_usd_signed",
            int256(totalCollBase) - int256(totalDebtBase)
        );
        emit log_named_uint("aave_health_factor_e18", hf);
    }
}
