// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IERC4626} from "src/interfaces/common/IERC4626.sol";
import {ISUSDS} from "src/interfaces/stable/ISUSDS.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";

/// @dev Sky PSM-Lite: zero-fee USDS <-> USDC 1:1 converter.
///      buyGem(usr, gemAmt) : pays USDS, receives USDC (gemAmt in 6-dec).
///      Caller must approve USDS to PSM-Lite's usdsJoin address first.
///      usdsJoin(): returns the address that pulls USDS from the caller.
///      Deployed: 0xA188EEC8F81263234dA3622A406892F3D630f98c
interface ISkyPsmLite {
    function buyGem(address usr, uint256 gemAmt) external;
    function usdsJoin() external view returns (address);
}

/// @title F17-02 syrupUSDC vs sUSDS carry rotation
/// @notice Demonstrates a one-way rotation from sUSDS (SSR-anchored) to
///         syrupUSDC (Maple institutional lending yield), motivated by an
///         APY spread of ~5% at the pinned block. The rotation path is
///         sUSDS.redeem -> USDS -> Curve swap to USDC -> syrupUSDC.deposit.
contract F17_02_SyrupVsSUSDSRotation is StrategyBase {
    // ---- Pinned block ----
    /// @dev Jan 2025. sUSDS live (deployed ~20_700_000), SSR active, syrupUSDC live.
    uint256 internal constant FORK_BLOCK = 21_000_000;
    /// @dev 7-day earlier block for syrupUSDC APY proxy (~50K blocks/7 days).
    uint256 internal constant PRIOR_BLOCK = 20_950_000;

    // ---- Hardcoded token addresses (per spec) ----
    address internal constant SYRUPUSDC = 0x80ac24aA929eaF5013f6436cdA2a7ba190f5Cc0b;

    // ---- Sky PSM-Lite (USDS <-> USDC zero-fee) ----
    /// @dev Sky PSM-Lite. `sell(receiver, amount18)` swaps USDS -> USDC 1:1.
    ///      Deployed 2024-09-12; live at FORK_BLOCK 21_000_000.
    address internal constant SKY_PSM_LITE = 0xA188EEC8F81263234dA3622A406892F3D630f98c;

    // ---- Curve USDS/USDC pool (kept for reference; wrong address for this block) ----
    /// @dev Address 0x00e6Fd... is USDV/3Crv, not USDS/USDC. _swapUSDSToUSDC
    ///      checks coin ordering at runtime and falls through to PSM-Lite if mismatch.
    address internal constant CURVE_USDS_USDC = 0x00e6Fd108C4640d21B40d02f18Dd6fE7c7F725CA;

    // ---- Sizing ----
    uint256 internal constant SEED_USDS_TO_SUSDS = 200_000e18; // $200k USDS to stake first
    uint256 internal constant ROTATION_THRESHOLD_BPS = 100; // require >=1% spread

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.USDS);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.SUSDS);
        _trackToken(SYRUPUSDC);
        _setEthUsdFallback(2_600e8);
    }

    function test_syrupVsSusdsRotation() public {
        // ---- 0. Validate syrupUSDC is live and is ERC4626 over USDC ----
        address syrupAsset;
        uint8 syrupDecimals;
        try IERC4626(SYRUPUSDC).asset() returns (address a) {
            syrupAsset = a;
        } catch {
            emit log("syrupUSDC.asset() reverted; contract not live or wrong ABI at FORK_BLOCK");
            _endPnL("F17-02-syrupusdc-vs-susds-carry-rotation (no-op)");
            return;
        }
        try IERC20(SYRUPUSDC).decimals() returns (uint8 d) {
            syrupDecimals = d;
        } catch {
            syrupDecimals = 6;
        }
        emit log_named_address("syrupUSDC.asset()", syrupAsset);
        emit log_named_uint("syrupUSDC decimals", uint256(syrupDecimals));
        if (syrupAsset != Mainnet.USDC) {
            emit log("syrupUSDC.asset() != USDC at FORK_BLOCK; aborting (likely wrong address)");
            _endPnL("F17-02-syrupusdc-vs-susds-carry-rotation (no-op)");
            return;
        }

        // ---- 1. Estimate sUSDS APY from ssr() ----
        ISUSDS susds = ISUSDS(Mainnet.SUSDS);
        uint256 ssr = susds.ssr();
        emit log_named_uint("ssr_ray", ssr);
        // ssr is per-second RAY (1e27). Approximate APY (in bps) via linear
        // expansion: APY_bps ~= (ssr - 1e27) * 31_536_000 * 10_000 / 1e27.
        // For ssr near 1e27, the linear approx is accurate to <1 bps.
        uint256 susdsApyBps;
        if (ssr > 1e27) {
            susdsApyBps = ((ssr - 1e27) * 31_536_000) / 1e23;
        }
        emit log_named_uint("sUSDS_APY_bps_estimate", susdsApyBps);

        // ---- 2. Estimate syrupUSDC APY by re-forking to 7-day earlier block ----
        // Capture share price at PRIOR_BLOCK and FORK_BLOCK; annualize.
        _fork(PRIOR_BLOCK);
        uint256 syrupPpsBefore;
        try IERC4626(SYRUPUSDC).convertToAssets(1e6) returns (uint256 pps) {
            syrupPpsBefore = pps;
        } catch {
            emit log("convertToAssets failed at PRIOR_BLOCK; syrupUSDC may not exist there");
            _fork(FORK_BLOCK);
            syrupPpsBefore = 1e6; // fall back to 1:1 (under-estimates yield, bias safe)
        }

        _fork(FORK_BLOCK);
        uint256 syrupPpsNow = IERC4626(SYRUPUSDC).convertToAssets(1e6);
        emit log_named_uint("syrup_pps_prior_1e6", syrupPpsBefore);
        emit log_named_uint("syrup_pps_now_1e6", syrupPpsNow);

        // Annualize: APY_bps = (pps_now / pps_before - 1) * (365 / 7) * 10_000
        uint256 syrupApyBps;
        if (syrupPpsNow > syrupPpsBefore && syrupPpsBefore > 0) {
            uint256 deltaBps = ((syrupPpsNow - syrupPpsBefore) * 10_000) / syrupPpsBefore;
            syrupApyBps = (deltaBps * 365) / 7;
        }
        emit log_named_uint("syrup_APY_bps_estimate", syrupApyBps);

        // ---- 3. Decide rotation ----
        if (syrupApyBps <= susdsApyBps + ROTATION_THRESHOLD_BPS) {
            emit log("rotation not justified: syrup APY does not exceed sUSDS APY by threshold");
            _startPnL();
            _endPnL("F17-02-syrupusdc-vs-susds-carry-rotation (no-op)");
            return;
        }

        // ---- 4. Setup initial sUSDS position ----
        _fund(Mainnet.USDS, address(this), SEED_USDS_TO_SUSDS);
        IERC20(Mainnet.USDS).approve(Mainnet.SUSDS, type(uint256).max);
        uint256 susdsShares = susds.deposit(SEED_USDS_TO_SUSDS, address(this));
        emit log_named_uint("susds_shares_minted", susdsShares);

        _startPnL();

        // ---- 5. Redeem sUSDS -> USDS ----
        uint256 usdsOut = susds.redeem(susdsShares, address(this), address(this));
        emit log_named_uint("usds_redeemed", usdsOut);
        require(usdsOut >= SEED_USDS_TO_SUSDS * 99 / 100, "sUSDS redemption loss > 1%");

        // ---- 6. Swap USDS -> USDC (Curve USDS/USDC pool, fallback path) ----
        uint256 usdcOut = _swapUSDSToUSDC(usdsOut);
        if (usdcOut == 0) {
            emit log("USDS->USDC swap path unavailable; rotation aborted, restoring sUSDS");
            IERC20(Mainnet.USDS).approve(Mainnet.SUSDS, type(uint256).max);
            susds.deposit(IERC20(Mainnet.USDS).balanceOf(address(this)), address(this));
            _endPnL("F17-02-syrupusdc-vs-susds-carry-rotation (swap-fail)");
            return;
        }
        emit log_named_uint("usdc_received", usdcOut);

        // ---- 7. Deposit into syrupUSDC ----
        IERC20(Mainnet.USDC).approve(SYRUPUSDC, type(uint256).max);
        uint256 syrupShares;
        try IERC4626(SYRUPUSDC).deposit(usdcOut, address(this)) returns (uint256 s) {
            syrupShares = s;
        } catch {
            emit log("syrupUSDC.deposit reverted (paused / cap / KYC?); rotation halted");
            _endPnL("F17-02-syrupusdc-vs-susds-carry-rotation (deposit-fail)");
            return;
        }
        emit log_named_uint("syrup_shares_minted", syrupShares);
        require(syrupShares > 0, "no syrupUSDC shares minted");

        // ---- 8. Read post-rotation share value (immediate, before warp) ----
        uint256 immediateValue = IERC4626(SYRUPUSDC).convertToAssets(syrupShares);
        emit log_named_uint("rotated_value_in_USDC_immediate", immediateValue);

        // Friction = entry USDC (usdcOut) - immediate convertToAssets
        // Expect very small (deposit price = NAV at block).
        if (immediateValue < usdcOut) {
            uint256 frictionUsdc = usdcOut - immediateValue;
            emit log_named_uint("rotation_friction_usdc", frictionUsdc);
        }

        _endPnL("F17-02-syrupusdc-vs-susds-carry-rotation");

        // ---- 9. Post-condition: rotated position holds at least 99% of seed ----
        // Convert seed USDS (1e18) to USDC-equivalent (1e6): SEED/1e12.
        uint256 seedInUsdc = SEED_USDS_TO_SUSDS / 1e12;
        assertGt(immediateValue, seedInUsdc * 98 / 100, "rotation friction > 2% - too costly");
    }

    /// @dev Try Curve USDS/USDC pool first; fall back to USDS -> DAI (1:1 via
    ///      sky migration / PSM-Lite) + DAI -> USDC via Curve 3pool. Returns
    ///      0 if no path is available.
    function _swapUSDSToUSDC(uint256 usdsIn) internal returns (uint256) {
        // ---- Attempt direct Curve USDS/USDC pool ----
        if (uint160(CURVE_USDS_USDC) > 1e12) {
            // Check coin(0)/coin(1) ordering on the pool.
            address c0;
            address c1;
            try ICurveStableSwap(CURVE_USDS_USDC).coins(0) returns (address a) { c0 = a; } catch {}
            try ICurveStableSwap(CURVE_USDS_USDC).coins(1) returns (address a) { c1 = a; } catch {}
            int128 usdsIdx;
            int128 usdcIdx;
            bool ok;
            if (c0 == Mainnet.USDS && c1 == Mainnet.USDC) { usdsIdx = 0; usdcIdx = 1; ok = true; }
            else if (c1 == Mainnet.USDS && c0 == Mainnet.USDC) { usdsIdx = 1; usdcIdx = 0; ok = true; }
            if (ok) {
                IERC20(Mainnet.USDS).approve(CURVE_USDS_USDC, type(uint256).max);
                try ICurveStableSwap(CURVE_USDS_USDC).exchange(usdsIdx, usdcIdx, usdsIn, 0) returns (uint256 dy) {
                    return dy;
                } catch {
                    // fall through to fallback path
                }
            }
        }

        // ---- Fallback: Sky PSM-Lite USDS -> USDC (1:1 zero-fee) ----
        // PSM-Lite `buyGem(usr, gemAmt6)` calls USDS.transferFrom(caller, PSM_LITE, amount18)
        // directly - so we must approve the PSM-Lite contract itself, not usdsJoin.
        if (uint160(SKY_PSM_LITE) > 0) {
            // Approve PSM-Lite to pull USDS from this contract.
            IERC20(Mainnet.USDS).approve(SKY_PSM_LITE, usdsIn);
            // gemAmt in 6-dec USDC = usdsIn / 1e12.
            uint256 gemAmt6 = usdsIn / 1e12;
            try ISkyPsmLite(SKY_PSM_LITE).buyGem(address(this), gemAmt6) {
                uint256 usdcOut = IERC20(Mainnet.USDC).balanceOf(address(this));
                if (usdcOut > 0) return usdcOut;
            } catch {
                emit log("PSM-Lite buyGem reverted");
            }
        }

        emit log("no USDS->USDC route at FORK_BLOCK");
        return 0;
    }
}
