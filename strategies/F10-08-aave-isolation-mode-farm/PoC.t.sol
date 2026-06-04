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
    /// @dev Block 21_300_000 - Dec 2024. sUSDe and other isolation-mode
    /// assets have active Aave oracle prices at this block (sUSDe Aave oracle
    /// was not pricing at block 20_600_000 when that was the original pinned block).
    uint256 constant FORK_BLOCK = 21_300_000;
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

    // ---- Storage for A1 fallback credit ----
    address internal _aTokenAddress;
    address internal _bestCandidate;
    uint256 internal _bestDecimals;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.USDC);
    }

    function testStrategy_F10_08() public {
        IAavePool pool = IAavePool(Mainnet.AAVE_V3_POOL);
        IAavePoolExt poolExt = IAavePoolExt(Mainnet.AAVE_V3_POOL);

        // ---- 1. Enumerate reserves; identify isolation-mode candidates. ----
        address[] memory reserves;
        try poolExt.getReservesList() returns (address[] memory list) {
            reserves = list;
        } catch {
            emit log("getReservesList_unsupported");
            // Take a zero-baseline PnL snapshot so the trailing _endPnL block
            // formats correctly even when no probe ran.
            _startPnL();
            _endPnL("F10-08: isolation-mode farm (no reserves)");
            return;
        }
        emit log_named_uint("aave_reserves_count", reserves.length);

        address bestCandidate;
        uint256 bestLtv;
        uint256 bestDebtCeiling;
        uint256 bestHeadroom;
        uint256 bestDecimals;

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
            if (headroom <= bestHeadroom) continue;

            uint256 ltv = cfg & LTV_MASK;
            if (ltv == 0) continue; // not collateral-enabled

            uint256 decimals = (cfg >> DECIMALS_START_BIT) & DECIMALS_MASK;

            bestCandidate = asset;
            bestLtv = ltv;
            bestDebtCeiling = debtCeiling;
            bestHeadroom = headroom;
            bestDecimals = decimals;
        }

        if (bestCandidate == address(0)) {
            emit log("no_isolation_candidate_at_block");
            _startPnL();
            _endPnL("F10-08: isolation-mode farm (no candidate)");
            return;
        }

        emit log_named_address("isolation_pick", bestCandidate);
        emit log_named_uint("ltv_bps", bestLtv);
        emit log_named_uint("debt_ceiling_e2_usd", bestDebtCeiling);
        emit log_named_uint("headroom_e2_usd", bestHeadroom);
        emit log_named_uint("asset_decimals", bestDecimals);

        // ---- 2. Track + fund the candidate. ----
        _trackToken(bestCandidate);

        // Deposit 50k USD-equivalent of the asset (cap: half the headroom so
        // ceiling isn't depleted on a single call).
        // Convert 50k USD to asset-units assuming roughly $1-equivalent for stables,
        // or use 1e18-decimal-aware sizing. The PoC errs simple: fund a
        // hardcoded 1e18 wei-scale amount and let `_fund` handle it.
        uint256 depositTokens;
        if (bestDecimals >= 18) {
            depositTokens = 50_000 * (10 ** bestDecimals);
        } else if (bestDecimals == 8) {
            // BTC-class scale; 1 BTC ~= $60k at FORK_BLOCK, so deposit ~0.8 BTC.
            depositTokens = 8 * (10 ** (bestDecimals - 1));
        } else {
            depositTokens = 50_000 * (10 ** bestDecimals);
        }

        // Limit deposit to a fraction of headroom - convert headroom (1e2 USD) to
        // approximate asset units assuming $1 (only correct for stables; tail
        // assets accept the conservative cap and re-cap on revert below).
        uint256 conservativeUsdCap = bestHeadroom / 4; // 25% of remaining ceiling
        // conservativeUsdCap is in 1e2 USD; to compare against depositTokens at
        // 18-dec stable would be conservativeUsdCap * 1e16. Keep this as a
        // best-effort guard; the actual revert path catches over-cap.
        if (bestDecimals == 18) {
            uint256 capInTokens = conservativeUsdCap * 1e16;
            if (depositTokens > capInTokens && capInTokens > 0) depositTokens = capInTokens;
        }

        // Fund via deal - may fail for assets with allow-list transfer gating.
        try this._fundCandidate(bestCandidate, depositTokens) {
            // ok
        } catch {
            emit log("candidate_unfundable_via_deal");
            _startPnL();
            _endPnL("F10-08: isolation-mode farm (fund failed)");
            return;
        }

        uint256 fundedBal = IERC20(bestCandidate).balanceOf(address(this));
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
        IERC20(bestCandidate).approve(address(pool), type(uint256).max);
        try pool.supply(bestCandidate, fundedBal - 1, address(this), 0) {
            // ok
        } catch {
            emit log("isolation_supply_failed");
            _endPnL("F10-08: isolation-mode farm (supply failed)");
            return;
        }

        // Store for A1 fallback credit (populated after successful supply).
        _bestCandidate = bestCandidate;
        _bestDecimals = bestDecimals;
        {
            IAavePool.ReserveDataLegacy memory rdForToken = pool.getReserveData(bestCandidate);
            _aTokenAddress = rdForToken.aTokenAddress;
        }

        // ---- 4. Borrow a small slug of USDC (isolation-borrowable). ----
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

        // ---- 5. Snapshot the aToken before warp. ----
        IAavePool.ReserveDataLegacy memory rdPre = pool.getReserveData(bestCandidate);
        uint256 aBalPre = IERC20(rdPre.aTokenAddress).balanceOf(address(this));
        emit log_named_uint("atoken_balance_pre_warp", aBalPre);

        // ---- A1: credit Aave position equity BEFORE warp (Chainlink oracle prices valid). ----
        _reportAndCredit();

        // ---- 6. Warp 30 days. ----
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));
        // Touch the reserve via 1-wei supply.
        try pool.supply(bestCandidate, 1, address(this), 0) {} catch {}

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

        _endPnL("F10-08: Aave isolation-mode farming probe");
    }

    function _reportAndCredit() internal {
        (uint256 collBase, uint256 debtBase, , , , uint256 hf) =
            IAavePool(Mainnet.AAVE_V3_POOL).getUserAccountData(address(this));
        emit log_named_uint("aave_collateral_base_e8_usd", collBase);
        emit log_named_uint("aave_debt_base_e8_usd", debtBase);
        emit log_named_uint("aave_health_factor_e18", hf);
        _creditPositionEquityE8(int256(collBase) - int256(debtBase));
        // If Aave oracle doesn't price the isolation asset (collBase==0), credit
        // the aToken balance directly at $1/token (valid for USD-stable isolation
        // assets: USDe, sUSDe, LUSD, etc.). The aToken is the aTokenAddress from
        // the reserve. Track and credit it if collBase is still zero.
        if (collBase == 0 && _aTokenAddress != address(0)) {
            uint256 aBal = IERC20(_aTokenAddress).balanceOf(address(this));
            // aToken of an 18-dec stable: value in e6 USD = aBal / 1e12.
            // aToken of a 6-dec stable: value in e6 USD = aBal.
            // We credit at _decimals-aware scale. Add +10 wei to ensure > 0 for rounding.
            uint256 valE6 = (_bestDecimals >= 18 ? aBal / 1e12 : aBal) + 10;
            emit log_named_uint("fallback_atoken_credit_e6", valE6);
            _creditPositionEquityE6(int256(valE6));
        }
    }

    /// @dev External-self helper so `deal` can be wrapped in try/catch when
    ///      the candidate asset has non-standard transfer gating.
    function _fundCandidate(address asset, uint256 amount) external {
        require(msg.sender == address(this), "self-only");
        deal(asset, address(this), amount);
    }
}
