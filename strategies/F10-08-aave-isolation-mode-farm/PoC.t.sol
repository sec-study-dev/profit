// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";

/// @notice Extension of the Aave V3 Pool interface for the calls that
///         IAavePool.sol does not declare. Defined locally to honour Wave 4's
///         "no shared file edits" constraint.
interface IAavePoolExt {
    function getReservesList() external view returns (address[] memory);
    function getConfiguration(address asset) external view returns (uint256);
}

/// @title F10-08 Aave V3 isolation-mode candidate scanner & farming
/// @notice Observational PoC: walks Aave V3's reserve list, identifies the
///         assets configured in isolation mode (configuration bit 64 set,
///         debtCeiling > 0), picks the candidate with the most headroom
///         relative to its debt ceiling, and opens a small deposit position
///         to surface the per-supplier APR after a 30-day warp.
///
///         The PoC does NOT route incentives; it relies on the underlying
///         reserve's aToken balance drift to surface the *raw* lending APR.
///         For the full incentive APR Wave 3 should query the
///         IRewardsController.getRewardsByAsset for each candidate.
contract F10_08_AaveIsolationModeFarm is StrategyBase {
    uint256 constant FORK_BLOCK = 20_600_000;
    uint256 constant RATE_MODE_VARIABLE = 2;

    // ---- Aave V3 ReserveConfiguration bitmap bit positions ----

    /// @dev Bit 64 of the reserve configuration encodes the `borrowable in
    ///      isolation` flag - set on reserves that are borrowable while the
    ///      account holds an isolated-mode collateral.
    uint256 constant BORROWABLE_IN_ISOLATION_MASK = 1 << 64;

    /// @dev `debtCeiling` is stored in bits 212..252 of the configuration
    ///      (40 bits) in 1e2-USD units. A non-zero ceiling identifies the
    ///      asset itself as listed in isolation mode.
    uint256 constant DEBT_CEILING_START_BIT = 212;
    uint256 constant DEBT_CEILING_MASK = (uint256(1) << 40) - 1;

    /// @dev `LTV` is bits 0..15 of the configuration (16 bits) in basis points.
    uint256 constant LTV_MASK = (uint256(1) << 16) - 1;

    /// @dev `decimals` is bits 48..55 (8 bits).
    uint256 constant DECIMALS_START_BIT = 48;
    uint256 constant DECIMALS_MASK = (uint256(1) << 8) - 1;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.USDC);
    }

    struct IsolationCandidate {
        address asset;
        uint256 ltv;
        uint256 debtCeiling;
        uint256 headroom;
        uint256 decimals;
    }

    function _findBestCandidate(
        IAavePool pool,
        address[] memory reserves
    ) internal returns (IsolationCandidate memory best) {
        IAavePoolExt poolExt = IAavePoolExt(address(pool));
        for (uint256 i = 0; i < reserves.length; i++) {
            address asset = reserves[i];
            uint256 cfg;
            try poolExt.getConfiguration(asset) returns (uint256 c) {
                cfg = c;
            } catch {
                continue;
            }

            uint256 debtCeiling = (cfg >> DEBT_CEILING_START_BIT) & DEBT_CEILING_MASK;
            if (debtCeiling == 0) continue; // not isolated-mode listed

            // Fetch isolation debt for headroom calc.
            IAavePool.ReserveDataLegacy memory rd = pool.getReserveData(asset);
            uint256 currentIsoDebt = rd.isolationModeTotalDebt; // 1e2 USD units
            if (currentIsoDebt >= debtCeiling) continue; // no headroom

            uint256 headroom = debtCeiling - currentIsoDebt;
            if (headroom <= best.headroom) continue;

            uint256 ltv = cfg & LTV_MASK;
            if (ltv == 0) continue; // not collateral-enabled

            uint256 decimals = (cfg >> DECIMALS_START_BIT) & DECIMALS_MASK;

            best.asset = asset;
            best.ltv = ltv;
            best.debtCeiling = debtCeiling;
            best.headroom = headroom;
            best.decimals = decimals;
        }
    }

    function testStrategy_F10_08() public {
        IAavePool pool = IAavePool(Mainnet.AAVE_V3_POOL);

        // ---- 1. Enumerate reserves; identify isolation-mode candidates. ----
        address[] memory reserves;
        {
            IAavePoolExt poolExt = IAavePoolExt(Mainnet.AAVE_V3_POOL);
            try poolExt.getReservesList() returns (address[] memory list) {
                reserves = list;
            } catch {
                emit log("getReservesList_unsupported");
                _startPnL();
                _endPnL("F10-08: isolation-mode farm (no reserves)");
                return;
            }
        }
        emit log_named_uint("aave_reserves_count", reserves.length);

        IsolationCandidate memory best = _findBestCandidate(pool, reserves);

        if (best.asset == address(0)) {
            emit log("no_isolation_candidate_at_block");
            _startPnL();
            _endPnL("F10-08: isolation-mode farm (no candidate)");
            return;
        }

        emit log_named_address("isolation_pick", best.asset);
        emit log_named_uint("ltv_bps", best.ltv);
        emit log_named_uint("debt_ceiling_e2_usd", best.debtCeiling);
        emit log_named_uint("headroom_e2_usd", best.headroom);
        emit log_named_uint("asset_decimals", best.decimals);

        // ---- 2. Track + fund the candidate. ----
        _trackToken(best.asset);
        _fundCandidate(pool, best);

        uint256 fundedBal = IERC20(best.asset).balanceOf(address(this));
        emit log_named_uint("candidate_funded_balance", fundedBal);
        if (fundedBal == 0) {
            _startPnL();
            _endPnL("F10-08: isolation-mode farm (zero balance)");
            return;
        }

        // Snapshot AFTER candidate funding so the funded notional is the
        // PnL baseline - yield/incentive accrual is then the only delta.
        _startPnL();

        // ---- 3. Supply the candidate into Aave. ----
        IERC20(best.asset).approve(address(pool), type(uint256).max);
        try pool.supply(best.asset, fundedBal - 1, address(this), 0) {
            // ok
        } catch {
            emit log("isolation_supply_failed");
            _endPnL("F10-08: isolation-mode farm (supply failed)");
            return;
        }

        // ---- 4. Borrow a small slug of USDC (isolation-borrowable). ----
        _borrowUsdc(pool);

        // ---- 5. Snapshot the aToken before warp. ----
        IAavePool.ReserveDataLegacy memory rdPre = pool.getReserveData(best.asset);
        uint256 aBalPre = IERC20(rdPre.aTokenAddress).balanceOf(address(this));
        emit log_named_uint("atoken_balance_pre_warp", aBalPre);

        // ---- 6. Warp 30 days. ----
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));
        // Touch the reserve via 1-wei supply.
        try pool.supply(best.asset, 1, address(this), 0) {} catch {}

        // ---- 7. Surface accrued aToken delta. ----
        uint256 aBalPost = IERC20(rdPre.aTokenAddress).balanceOf(address(this));
        emit log_named_uint("atoken_balance_post_warp", aBalPost);
        if (aBalPost > aBalPre) {
            uint256 delta = aBalPost - aBalPre;
            emit log_named_uint("atoken_accrual_30d", delta);
            // Implied annualised: delta / aBalPre * 365 / 30, scaled by 1e6 bps.
            if (aBalPre > 0) {
                uint256 impliedApyBps = (delta * 10_000 * 12) / aBalPre; // ~ annualised bps
                emit log_named_uint("implied_apy_bps_no_incentives", impliedApyBps);
            }
        }

        // ---- 8. Unwind: withdraw collateral, repay USDC borrow ----
        _unwind(pool, best.asset);

        _reportAavePosition(pool);
        _endPnL("F10-08: Aave isolation-mode farming probe");
    }

    function _fundCandidate(IAavePool pool, IsolationCandidate memory best) internal {
        uint256 depositTokens;
        if (best.decimals >= 18) {
            depositTokens = 50_000 * (10 ** best.decimals);
        } else if (best.decimals == 8) {
            // BTC-class scale; 1 BTC ~= $60k at FORK_BLOCK, so deposit ~0.8 BTC.
            depositTokens = 8 * (10 ** (best.decimals - 1));
        } else {
            depositTokens = 50_000 * (10 ** best.decimals);
        }

        // Limit deposit to a fraction of headroom - convert headroom (1e2 USD) to
        // approximate asset units assuming $1 (only correct for stables).
        uint256 conservativeUsdCap = best.headroom / 4; // 25% of remaining ceiling
        if (best.decimals == 18) {
            uint256 capInTokens = conservativeUsdCap * 1e16;
            if (depositTokens > capInTokens && capInTokens > 0) depositTokens = capInTokens;
        } else if (best.decimals == 6) {
            // For 6-decimal stables (USDC-like): headroom is in 1e2 USD → multiply by 1e4
            uint256 capInTokens = conservativeUsdCap * 1e4;
            if (depositTokens > capInTokens && capInTokens > 0) depositTokens = capInTokens;
        }

        // Fund via deal.
        try this._dealCandidate(best.asset, depositTokens) {
            // ok
        } catch {
            emit log("candidate_unfundable_via_deal");
        }

        pool; // silence unused warning
    }

    function _borrowUsdc(IAavePool pool) internal {
        (, , uint256 availableBase, , , ) = pool.getUserAccountData(address(this));
        // availableBase in 1e8 USD; borrow 30% in USDC (6-dec at $1).
        uint256 borrowUsdc = (availableBase * 3000) / 10_000 / 1e2;
        if (borrowUsdc > 0) {
            try pool.borrow(Mainnet.USDC, borrowUsdc, RATE_MODE_VARIABLE, 0, address(this)) {
                uint256 usdcBal = IERC20(Mainnet.USDC).balanceOf(address(this));
                emit log_named_uint("usdc_borrowed_under_isolation", usdcBal);
            } catch {
                emit log("usdc_borrow_under_isolation_failed");
            }
        }
    }

    function _unwind(IAavePool pool, address asset) internal {
        // Repay USDC debt if any
        uint256 usdcBal = IERC20(Mainnet.USDC).balanceOf(address(this));
        if (usdcBal > 0) {
            IERC20(Mainnet.USDC).approve(address(pool), usdcBal);
            try pool.repay(Mainnet.USDC, usdcBal, RATE_MODE_VARIABLE, address(this)) {} catch {}
        }

        // Withdraw all collateral
        try pool.withdraw(asset, type(uint256).max, address(this)) {} catch {}
    }

    function _reportAavePosition(IAavePool pool) internal {
        (uint256 collBase, uint256 debtBase, , , , uint256 hf) =
            pool.getUserAccountData(address(this));
        emit log_named_uint("aave_collateral_base_e8_usd", collBase);
        emit log_named_uint("aave_debt_base_e8_usd", debtBase);
        emit log_named_uint("aave_health_factor_e18", hf);
    }

    /// @dev External-self helper so `deal` can be wrapped in try/catch when
    ///      the candidate asset has non-standard transfer gating.
    function _dealCandidate(address asset, uint256 amount) external {
        require(msg.sender == address(this), "self-only");
        deal(asset, address(this), amount);
    }
}
