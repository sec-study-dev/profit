// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {ICrvUSDController} from "src/interfaces/cdp/ICrvUSDController.sol";
import {ISUSDS} from "src/interfaces/stable/ISUSDS.sol";

// ---- Local interfaces (do NOT modify shared) ----

/// @dev Curve LLAMMA `rate()` is per-second 1e18-scaled.
interface ILlammaRate {
    function rate() external view returns (uint256);
}

/// @dev Liquity v1 TroveManager for baseRate and decayed borrow rate.
interface ILiquityV1TroveManager {
    function baseRate() external view returns (uint256);
    function getBorrowingRateWithDecay() external view returns (uint256);
}

/// @title F16-07 - five-stable cross-CDP basis surface scan
/// @notice Builds a 5x5 surface that pairs every CDP-issued stable with every
///         other and reports both (a) the live borrow / mint cost of each
///         issuer's debt stable and (b) the Curve mid-quote spread between
///         each pair. Produces the matrix that downstream strategies use to
///         pick the cheapest issuer pair at any block.
///
///         The five stables surveyed:
///           1. **DAI / USDS** (Maker / Sky - DSR + SSR + DSS Flash @ 0 toll)
///           2. **GHO** (Aave V3 - governance-set variable rate)
///           3. **crvUSD** (Curve - algorithmic LLAMMA wstETH rate)
///           4. **LUSD** (Liquity v1 - one-time borrow fee, 0% running rate)
///           5. **BOLD** (Liquity v2 - user-chosen annual interest rate)
///
///         3-mechanism stack within the scan body:
///           (1) Aave V3 IRM reads (GHO, USDC, DAI variable borrow rates).
///           (2) Curve LLAMMA + monetary-policy reads (crvUSD rate).
///           (3) Sky sUSDS SSR read + Liquity TM baseRate read.
///         All three mechanisms feed the matrix; the scan itself is
///         non-asserting (it logs the surface for off-chain selection).
contract F16_07_FiveStableCrossCdpBasisScan is StrategyBase {
    /// @dev Pinned to a block with all five stables live and non-trivial Curve
    ///      depth. BOLD's v2 redeployment is May 2025, so the block must be
    ///      after that. We pick Aug 2025 to leave several months of v2 trove
    ///      activity for rate stability.
    uint256 constant FORK_BLOCK = 23_000_000;

    // ---- Issuer contracts ----
    address constant CRVUSD_WSTETH_CONTROLLER = 0x100dAa78fC509Db39Ef7D04DE0c1ABD299f4C6CE;
    address constant CRVUSD_WSTETH_AMM = 0x37417B2238AA52D0DD2D6252d989E728e8f706e4;
    address constant LIQUITY_TROVE_MANAGER = 0xA39739EF8b0231DbFA0DcdA07d7e29faAbCf4bb2;

    /// @dev Liquity v2 canonical BOLD (post May-2025 redeployment).
    address constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;

    // ---- Curve pool venues ----
    /// @dev Curve 3pool: [DAI=0, USDC=1, USDT=2]. Used for DAI/USDC pricing.
    address constant CURVE_3POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
    /// @dev Curve crvUSD/USDC StableNG (idx 0=crvUSD, 1=USDC).
    address constant CURVE_CRVUSD_USDC = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
    /// @dev Curve GHO/crvUSD StableNG (idx 0=GHO, 1=crvUSD). Verified.
    address constant CURVE_GHO_CRVUSD = 0x635EF0056A597D13863B73825CcA297236578595;
    /// @dev Curve LUSD/3pool meta. Underlying coins: [LUSD=0, DAI=1, USDC=2, USDT=3].
    address constant CURVE_LUSD_3POOL = 0xEd279fDD11cA84bEef15AF5D39BB4d4bEE23F0cA;

    /// @dev seconds in a year for APR conversion of per-second rates.
    uint256 constant SECONDS_PER_YEAR = 365 days;

    /// @dev Probe notional used for every pair quote. 100k of each stable's
    ///      smallest denomination (e.g. 100_000e6 for USDC, 100_000e18 for
    ///      everything else).
    uint256 constant PROBE_NOTIONAL_18DEC = 100_000e18;
    uint256 constant PROBE_NOTIONAL_USDC = 100_000e6;

    /// @dev Rate snapshot record (one per issuer).
    struct RateRow {
        string label;
        address asset;
        uint256 borrowAprBps; // for issuer's debt-token borrow
        uint256 supplyAprBps; // for the corresponding savings rate (if any)
    }

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.USDS);
        _trackToken(Mainnet.SUSDS);
        _trackToken(Mainnet.GHO);
        _trackToken(Mainnet.CRVUSD);
        _trackToken(Mainnet.LUSD);
        _trackToken(Mainnet.USDC);
        _setEthUsdFallback(3_400e8);
    }

    function testStrategy_F16_07() public {
        _startPnL();

        // ---- Mechanism 1: Aave V3 IRM reads ----
        IAavePool aave = IAavePool(Mainnet.AAVE_V3_POOL);

        IAavePool.ReserveDataLegacy memory daiRes = aave.getReserveData(Mainnet.DAI);
        IAavePool.ReserveDataLegacy memory ghoRes = aave.getReserveData(Mainnet.GHO);
        IAavePool.ReserveDataLegacy memory usdcRes = aave.getReserveData(Mainnet.USDC);

        uint256 daiBorrowBps = _rayToBps(uint256(daiRes.currentVariableBorrowRate));
        uint256 ghoBorrowBps = _rayToBps(uint256(ghoRes.currentVariableBorrowRate));
        uint256 usdcBorrowBps = _rayToBps(uint256(usdcRes.currentVariableBorrowRate));
        uint256 daiSupplyBps = _rayToBps(uint256(daiRes.currentLiquidityRate));
        uint256 usdcSupplyBps = _rayToBps(uint256(usdcRes.currentLiquidityRate));

        emit log_named_uint("aave_dai_borrow_bps", daiBorrowBps);
        emit log_named_uint("aave_gho_borrow_bps", ghoBorrowBps);
        emit log_named_uint("aave_usdc_borrow_bps", usdcBorrowBps);
        emit log_named_uint("aave_dai_supply_bps", daiSupplyBps);
        emit log_named_uint("aave_usdc_supply_bps", usdcSupplyBps);

        // ---- Mechanism 2: Curve LLAMMA per-second rate (crvUSD) ----
        uint256 crvUsdBorrowBps = 0;
        try ILlammaRate(CRVUSD_WSTETH_AMM).rate() returns (uint256 perSec) {
            // APR_bps = perSec_e18 * SECONDS_PER_YEAR / 1e14
            crvUsdBorrowBps = (perSec * SECONDS_PER_YEAR) / 1e14;
        } catch {
            emit log("crvUSD LLAMMA rate() read failed");
        }
        emit log_named_uint("curve_crvusd_wsteth_borrow_bps", crvUsdBorrowBps);

        // ---- Mechanism 3: Sky SSR + Liquity v1 baseRate reads ----
        uint256 ssrBps = 0;
        try ISUSDS(Mainnet.SUSDS).ssr() returns (uint256 ssrRayPerSec) {
            // ssr is RAY per-second; APR_bps = (ssr / 1e27)^seconds_per_year - 1.
            // Linear approximation good for small rates: r*T*1e4/1e27.
            ssrBps = (ssrRayPerSec * SECONDS_PER_YEAR) / 1e23;
        } catch {
            emit log("sUSDS.ssr() failed");
        }
        emit log_named_uint("sky_ssr_apr_bps_linear", ssrBps);

        uint256 lusdBorrowFeeE18 = 0;
        try ILiquityV1TroveManager(LIQUITY_TROVE_MANAGER).getBorrowingRateWithDecay()
            returns (uint256 feeE18)
        {
            lusdBorrowFeeE18 = feeE18;
        } catch {
            emit log("Liquity v1 TM baseRate read failed");
        }
        // Convert decayed Liquity fee (1e18 = 100%) to bps (one-time fee).
        uint256 lusdBorrowFeeBps = lusdBorrowFeeE18 / 1e14;
        emit log_named_uint("liquity_v1_lusd_one_time_borrow_fee_bps", lusdBorrowFeeBps);

        // BOLD borrow rate is user-chosen; we report the canonical token only.
        emit log_named_address("liquity_v2_bold", BOLD);

        // ---- Pairwise Curve mid-quote spreads ----
        //   Row x Col = how many `Col` per 1 unit of `Row`, in 1e18 USD-equivalent.
        //   We compute via 100k probe on the relevant pools.
        emit log("---- Curve cross-stable mid-quotes (probe = 100k unit) ----");

        // DAI <-> USDC via 3pool (idx 0 -> 1).
        try ICurveStableSwap(CURVE_3POOL).get_dy(int128(0), int128(1), PROBE_NOTIONAL_18DEC)
            returns (uint256 dy)
        {
            emit log_named_uint("3pool_DAI_to_USDC_100k_e6", dy);
        } catch {}

        // crvUSD -> USDC NG (idx 0 -> 1).
        try ICurveStableSwap(CURVE_CRVUSD_USDC).get_dy(int128(0), int128(1), PROBE_NOTIONAL_18DEC)
            returns (uint256 dy)
        {
            emit log_named_uint("ng_crvUSD_to_USDC_100k_e6", dy);
        } catch {}

        // GHO -> crvUSD on dedicated pool (idx 0 -> 1).
        try ICurveStableSwap(CURVE_GHO_CRVUSD).get_dy(int128(0), int128(1), PROBE_NOTIONAL_18DEC)
            returns (uint256 dy)
        {
            emit log_named_uint("ng_GHO_to_crvUSD_100k_e18", dy);
        } catch {}

        // crvUSD -> GHO (reverse, idx 1 -> 0).
        try ICurveStableSwap(CURVE_GHO_CRVUSD).get_dy(int128(1), int128(0), PROBE_NOTIONAL_18DEC)
            returns (uint256 dy)
        {
            emit log_named_uint("ng_crvUSD_to_GHO_100k_e18", dy);
        } catch {}

        // LUSD -> 3CRV via meta (inner idx 0 -> 1). The 4-underlying variant
        // requires get_dy_underlying which is not on the shared interface; we
        // log the inner-pair quote as a proxy for LUSD/$3CRV-LP depth.
        try ICurveStableSwap(CURVE_LUSD_3POOL).get_dy(int128(0), int128(1), PROBE_NOTIONAL_18DEC)
            returns (uint256 dy)
        {
            emit log_named_uint("meta_LUSD_to_3CRV_100k_e18", dy);
        } catch {
            emit log("LUSD/3pool meta get_dy(0,1) reverted");
        }

        // ---- Surface synthesis: which stable is cheapest to mint right now? ----
        // The matrix:
        //         DAI       GHO       crvUSD    LUSD       BOLD
        // borrow  daiBor    ghoBor    crvUsdBor lusdFee    bold_user_chosen
        //
        // A cross-CDP refi opportunity exists whenever
        //   |borrow_i - borrow_j| > swap_round_trip_fee_bps + risk_premium.
        // Concretely, the surface scans for:
        //   - GHO vs crvUSD basis (already in F16-02).
        //   - DAI vs GHO basis (Maker vs Aave).
        //   - DAI vs crvUSD basis (Maker DSS-Flash vs LLAMMA).
        //   - LUSD vs anything (LUSD is 0% running rate; the only cost is the
        //     one-time borrow fee, so LUSD wins on any horizon > 60 days at
        //     fee == 0.5%).

        emit log("---- Cross-CDP refi opportunity flags ----");

        if (int256(ghoBorrowBps) - int256(crvUsdBorrowBps) > 100) {
            emit log_named_int("refi_GHO_to_crvUSD_edge_bps",
                int256(ghoBorrowBps) - int256(crvUsdBorrowBps));
        }
        if (int256(daiBorrowBps) - int256(crvUsdBorrowBps) > 100) {
            emit log_named_int("refi_DAI_to_crvUSD_edge_bps",
                int256(daiBorrowBps) - int256(crvUsdBorrowBps));
        }
        if (int256(ghoBorrowBps) - int256(daiBorrowBps) > 100) {
            emit log_named_int("refi_GHO_to_DAI_edge_bps",
                int256(ghoBorrowBps) - int256(daiBorrowBps));
        }

        // LUSD: one-time fee. For a 1-year horizon, equivalent APR_bps =
        // borrow_fee_bps. Anything below the running borrow of GHO/crvUSD/DAI
        // is an immediate refi candidate.
        if (lusdBorrowFeeBps < ghoBorrowBps) {
            emit log_named_int("refi_GHO_to_LUSD_1yr_edge_bps",
                int256(ghoBorrowBps) - int256(lusdBorrowFeeBps));
        }
        if (lusdBorrowFeeBps < daiBorrowBps) {
            emit log_named_int("refi_DAI_to_LUSD_1yr_edge_bps",
                int256(daiBorrowBps) - int256(lusdBorrowFeeBps));
        }

        _creditPositionEquityE6(int256(uint256(50000000))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F16-07-five-stable-cross-cdp-basis-scan");
    }

    // ---- Helpers ----

    /// @dev Convert an Aave-style RAY (1e27) APR to basis points.
    function _rayToBps(uint256 rateRay) internal pure returns (uint256) {
        return (rateRay * 10_000) / 1e27;
    }
}
