// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ISUSDS} from "src/interfaces/stable/ISUSDS.sol";

/// @notice Sky DaiUsds wrapper interface (zero-fee 1:1 DAI<->USDS).
interface IDaiUsds {
    function daiToUsds(address usr, uint256 wad) external;
    function usdsToDai(address usr, uint256 wad) external;
}

/// @title F04-05 - DaiUsds wrapper round-trip + sUSDS deposit slippage probe
/// @notice Two-mechanism stack (DaiUsds wrapper + sUSDS ERC-4626). The PoC's job
///         is to *measure* whether the headline "zero-fee 1:1" DAI<->USDS path
///         and the ERC-4626 share rounding ever introduce wei-level loss when
///         compounded with a multi-step round trip. This is the foundation
///         under every other F04 strategy: if these primitives are not truly
///         loss-less, the larger loops bleed silently.
///
/// Round trips probed (all in a single tx, no warp):
///   1. DAI -> USDS -> DAI (pure wrapper round-trip).
///   2. DAI -> USDS -> sUSDS shares -> USDS -> DAI (4626 mint+burn round-trip).
///   3. USDS -> sUSDS -> warp 60 days -> sUSDS -> USDS (rate accrual sanity).
///
/// Assertions:
///   - (1) and (2) at t = 0 lose at most `MAX_ROUND_TRIP_LOSS_WEI` (=1 wei) per
///         conversion in either direction. Sky's DaiUsds is structurally
///         supposed to be exact 1:1, but 4626 rounds shares down at deposit
///         and assets down at redeem so a 1-2 wei loss per cycle is expected.
///   - (3) the post-warp sUSDS redeem yields strictly *more* USDS than was
///         deposited at the same nominal share count (drip works).
contract F04_05_DaiUsdsRoundTrip is StrategyBase {
    address internal constant LOCAL_DAI_USDS = 0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A;

    uint256 internal constant FORK_BLOCK = 21_500_000;
    uint256 internal constant PROBE = 1_000_000e18;
    uint256 internal constant WARP_SECONDS = 60 days;
    // Tight tolerance - anything more than this means the wrapper is taking a
    // fee or the 4626 is reporting bad shares.
    uint256 internal constant MAX_ROUND_TRIP_LOSS_WEI = 2;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.USDS);
        _trackToken(Mainnet.SUSDS);
        _setEthUsdFallback(3_400e8);
    }

    // --- (1) Pure wrapper round-trip ---
    function test_daiUsdsPureRoundTrip() public {
        IDaiUsds wrapper = IDaiUsds(LOCAL_DAI_USDS);

        _fund(Mainnet.DAI, address(this), PROBE);
        IERC20(Mainnet.DAI).approve(LOCAL_DAI_USDS, type(uint256).max);
        IERC20(Mainnet.USDS).approve(LOCAL_DAI_USDS, type(uint256).max);

        uint256 daiStart = IERC20(Mainnet.DAI).balanceOf(address(this));
        wrapper.daiToUsds(address(this), PROBE);
        uint256 usdsMid = IERC20(Mainnet.USDS).balanceOf(address(this));
        // Wrapper is canonical 1:1 - must mint exactly PROBE USDS.
        assertEq(usdsMid, PROBE, "daiToUsds not exact 1:1");

        wrapper.usdsToDai(address(this), usdsMid);
        uint256 daiEnd = IERC20(Mainnet.DAI).balanceOf(address(this));
        emit log_named_uint("dai_start", daiStart);
        emit log_named_uint("dai_end_after_RT", daiEnd);
        // Must be exactly conserved.
        assertEq(daiEnd, daiStart, "DAI/USDS round-trip non-conservative");
    }

    // --- (2) Wrapper + sUSDS 4626 round-trip at t=0 (no warp) ---
    function test_daiUsdsSUsdsZeroWarpRoundTrip() public {
        IDaiUsds wrapper = IDaiUsds(LOCAL_DAI_USDS);
        ISUSDS susds = ISUSDS(Mainnet.SUSDS);

        _fund(Mainnet.DAI, address(this), PROBE);
        IERC20(Mainnet.DAI).approve(LOCAL_DAI_USDS, type(uint256).max);
        IERC20(Mainnet.USDS).approve(LOCAL_DAI_USDS, type(uint256).max);
        IERC20(Mainnet.USDS).approve(address(susds), type(uint256).max);

        uint256 daiStart = IERC20(Mainnet.DAI).balanceOf(address(this));
        _startPnL();

        // DAI -> USDS
        wrapper.daiToUsds(address(this), PROBE);
        uint256 usdsAfterWrap = IERC20(Mainnet.USDS).balanceOf(address(this));
        // USDS -> sUSDS (mint)
        uint256 shares = susds.deposit(usdsAfterWrap, address(this));
        require(shares > 0, "no shares minted");
        emit log_named_uint("shares_minted", shares);

        // sUSDS -> USDS (immediate redeem, no warp)
        uint256 usdsBack = susds.redeem(shares, address(this), address(this));
        emit log_named_uint("usds_back", usdsBack);
        // 4626 round-down on deposit means usdsBack <= usdsAfterWrap.
        // Tolerate small wei loss.
        assertLe(usdsAfterWrap - usdsBack, MAX_ROUND_TRIP_LOSS_WEI, "4626 round-trip too lossy");

        // USDS -> DAI
        wrapper.usdsToDai(address(this), usdsBack);
        uint256 daiEnd = IERC20(Mainnet.DAI).balanceOf(address(this));
        uint256 lossWei = daiStart > daiEnd ? daiStart - daiEnd : 0;
        emit log_named_uint("total_loss_wei_no_warp", lossWei);
        assertLe(lossWei, MAX_ROUND_TRIP_LOSS_WEI, "DAI->USDS->sUSDS->USDS->DAI lost > 2 wei");

        _endPnL("F04-05-daiusds-roundtrip-zerowarp");
    }

    // --- (3) sUSDS rate-accrual probe across 60d ---
    function test_susdsRateAccrual() public {
        IDaiUsds wrapper = IDaiUsds(LOCAL_DAI_USDS);
        ISUSDS susds = ISUSDS(Mainnet.SUSDS);

        _fund(Mainnet.DAI, address(this), PROBE);
        IERC20(Mainnet.DAI).approve(LOCAL_DAI_USDS, type(uint256).max);
        IERC20(Mainnet.USDS).approve(LOCAL_DAI_USDS, type(uint256).max);
        IERC20(Mainnet.USDS).approve(address(susds), type(uint256).max);

        // Snapshot SSR + chi.
        uint256 ssrBefore = susds.ssr();
        uint192 chiBefore = susds.chi();
        emit log_named_uint("ssr_RAY_per_sec", ssrBefore);
        emit log_named_uint("chi_before", uint256(chiBefore));
        require(ssrBefore > 1e27, "SSR must be > 1 RAY (otherwise no yield)");

        _startPnL();

        wrapper.daiToUsds(address(this), PROBE);
        uint256 usdsIn = IERC20(Mainnet.USDS).balanceOf(address(this));
        uint256 shares = susds.deposit(usdsIn, address(this));

        // Warp + drip.
        vm.warp(block.timestamp + WARP_SECONDS);
        susds.drip();
        uint192 chiAfter = susds.chi();
        emit log_named_uint("chi_after", uint256(chiAfter));
        assertGt(chiAfter, chiBefore, "chi did not advance after warp+drip");

        uint256 usdsOut = susds.redeem(shares, address(this), address(this));
        emit log_named_uint("usds_in", usdsIn);
        emit log_named_uint("usds_out_post_warp", usdsOut);
        // Strict growth: post-warp redeem must yield more USDS than was deposited.
        assertGt(usdsOut, usdsIn, "no SSR yield over 60d");

        // Sanity bound: at SSR ~12% (mid-2024 high) a 60d hold = ~1.97% gain.
        // At SSR ~6.5% (late 2024) -> ~1.07%. Lower bound: must beat 0.4%
        // (corresponds to ~2.5% SSR floor).
        uint256 gainBps = ((usdsOut - usdsIn) * 10_000) / usdsIn;
        emit log_named_uint("gain_bps_over_60d", gainBps);
        assertGt(gainBps, 40, "SSR yield over 60d < 0.4% - SSR effectively off");
        // Upper-bound sanity: more than 5% over 60d would imply SSR > 32% APR.
        assertLt(gainBps, 500, "implied APR > 30% - fork param drift?");

        // Wrap back to DAI to harvest in canonical denomination.
        wrapper.usdsToDai(address(this), usdsOut);
        uint256 daiHarvested = IERC20(Mainnet.DAI).balanceOf(address(this));
        emit log_named_uint("dai_harvested", daiHarvested);
        assertGt(daiHarvested, PROBE, "round trip lost vs unlevered SSR");

        _endPnL("F04-05-daiusds-roundtrip-warp");
    }
}
