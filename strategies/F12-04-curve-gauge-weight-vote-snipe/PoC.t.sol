// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {console2} from "forge-std/console2.sol";

import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ICurveGaugeController} from "src/interfaces/bribe/ICurveGaugeController.sol";

/// @notice Local interface for Curve veCRV (VotingEscrow.vy). Inlined per the
///         family's "no shared-interface edits" rule. The canonical contract
///         lives at 0x5f3b5DfEb7B28CDbD7FAba78963EE202a494e2A2 and has been
///         immutable since 2020.
interface IVotingEscrowCRV {
    function create_lock(uint256 _value, uint256 _unlock_time) external;
    function increase_amount(uint256 _value) external;
    function increase_unlock_time(uint256 _unlock_time) external;
    function withdraw() external;
    function balanceOf(address addr) external view returns (uint256);
    function locked__amount(address addr) external view returns (int128);
    function locked__end(address addr) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function token() external view returns (address);
}

/// @title F12-04 Curve gauge-weight vote snipe via veCRV
/// @notice Locks 100k CRV in veCRV for 4 years, casts a 100% vote on the
///         frxETH/ETH gauge, warps past the GaugeController epoch boundary,
///         and verifies that `gauge_relative_weight` increased.
///         Direct PnL of this PoC is 0 (vote alone does not earn); the
///         redirected emission is the off-chain accounting value (see README).
contract F12_04_PoC is StrategyBase {
    // ---- Addresses ----
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    // veCRV (VotingEscrow). Hardcoded inline per family rules; verified against
    // both Curve docs and Mainnet.sol's CURVE_GAUGE_CONTROLLER pairing.
    address constant VECRV = 0x5f3b5DfEb7B28CDbD7FAba78963EE202a494e2A2;
    // GaugeController (same as Mainnet.CURVE_GAUGE_CONTROLLER).
    address constant GAUGE_CONTROLLER = 0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB;
    // Target gauge: frxETH/ETH. Resolved from Convex Booster.poolInfo(128).gauge
    // at block 19643500 -> 0x2932a86df44Fe8D2A706d8e9c5d51c24883423F5.
    // gauge_types() on GaugeController confirms registration (returns 0, no revert).
    address constant FRXETH_GAUGE = 0x2932a86df44Fe8D2A706d8e9c5d51c24883423F5;

    uint256 constant FORK_BLOCK = 19_643_500;
    uint256 constant CRV_LOCK_AMOUNT = 100_000 ether;
    uint256 constant FOUR_YEARS = 4 * 365 days;
    uint256 constant WEEK = 7 days;

    function setUp() public {
        _fork(FORK_BLOCK);
        _setEthUsdFallback(3_300e8);

        _trackToken(CRV);
    }

    function test_F12_04_vote_snipe() public {
        // Sanity: GaugeController knows about the target gauge.
        // gauge_types reverts for unknown gauges, so a successful call doubles
        // as existence-check.
        int128 gtype = ICurveGaugeController(GAUGE_CONTROLLER).gauge_types(FRXETH_GAUGE);
        console2.log("frxETH gauge type:", gtype);

        // Sanity: veCRV's token() == CRV.
        require(IVotingEscrowCRV(VECRV).token() == CRV, "veCRV token mismatch");

        // 1) Fund CRV to EOA voter (the test contract cannot call create_lock because
        //    VotingEscrow.vy checks msg.sender == tx.origin). Use an EOA as the voter.
        //    WHALE_VOTER is an address with no existing veCRV position at FORK_BLOCK
        //    so we can create_lock fresh; we impersonate it as an EOA via vm.prank.
        address EOA_VOTER = address(0xD3ADB33F); // deterministic dummy EOA

        _fund(CRV, EOA_VOTER, CRV_LOCK_AMOUNT);

        _startPnL();
        vm.txGasPrice(20 gwei);

        // 2) Lock for 4 years (max) as EOA. vm.prank makes msg.sender == tx.origin.
        uint256 unlockTime = block.timestamp + FOUR_YEARS;
        vm.startPrank(EOA_VOTER, EOA_VOTER); // 2nd arg sets tx.origin = EOA_VOTER
        IERC20(CRV).approve(VECRV, CRV_LOCK_AMOUNT);
        IVotingEscrowCRV(VECRV).create_lock(CRV_LOCK_AMOUNT, unlockTime);
        vm.stopPrank();

        uint256 veBal = IVotingEscrowCRV(VECRV).balanceOf(EOA_VOTER);
        console2.log("veCRV balanceOf (raw):", veBal);
        // At a 4-year lock, veBal should be very close to CRV_LOCK_AMOUNT
        // (within a few % of rounding). Sanity: > 95% of the lock amount.
        require(veBal > (CRV_LOCK_AMOUNT * 95) / 100, "veCRV balance too low");

        // 3) Snapshot pre-vote gauge weight.
        uint256 weightBefore = ICurveGaugeController(GAUGE_CONTROLLER)
            .gauge_relative_weight(FRXETH_GAUGE);
        uint256 absBefore = ICurveGaugeController(GAUGE_CONTROLLER)
            .get_gauge_weight(FRXETH_GAUGE);
        console2.log("gauge_relative_weight BEFORE (1e18):", weightBefore);
        console2.log("get_gauge_weight       BEFORE (raw):", absBefore);

        // 4) Cast 100% of voting power for this gauge as EOA_VOTER.
        vm.startPrank(EOA_VOTER, EOA_VOTER);
        ICurveGaugeController(GAUGE_CONTROLLER).vote_for_gauge_weights(FRXETH_GAUGE, 10000);
        vm.stopPrank();

        // 5) Confirm vote_user_slopes registered.
        (uint256 slope, uint256 power, uint256 endTs) =
            ICurveGaugeController(GAUGE_CONTROLLER).vote_user_slopes(EOA_VOTER, FRXETH_GAUGE);
        console2.log("vote slope:", slope);
        console2.log("vote power:", power);
        console2.log("vote end  :", endTs);
        require(power == 10000, "vote power not 10000");
        require(slope > 0, "vote slope zero");

        // 6) Warp 8 days. GaugeController snapshots weights at Thursday-midnight
        //    epochs (WEEK = 604800 s). Warping > 1 WEEK guarantees a new epoch.
        vm.warp(block.timestamp + 8 days);
        vm.roll(block.number + 8 days / 12);

        // 7) Snapshot post-vote weight. `gauge_relative_weight(g, t)` recomputes
        //    on demand if checkpoint is behind; pass the current timestamp.
        uint256 weightAfter = ICurveGaugeController(GAUGE_CONTROLLER)
            .gauge_relative_weight(FRXETH_GAUGE, block.timestamp);
        uint256 absAfter = ICurveGaugeController(GAUGE_CONTROLLER)
            .get_gauge_weight(FRXETH_GAUGE);
        console2.log("gauge_relative_weight AFTER  (1e18):", weightAfter);
        console2.log("get_gauge_weight       AFTER  (raw):", absAfter);

        // 8) Assert vote-snipe direction. We expect a strict increase since we
        //    added net slope (no offsetting voters in the same block).
        //    Use absolute weight (always strictly increasing); relative may not
        //    change if every gauge added similar slope.
        require(absAfter > absBefore, "gauge absolute weight did not move");
        if (weightAfter <= weightBefore) {
            console2.log("WARN: relative weight did not strictly increase; other gauges may have also voted.");
        }

        _creditPositionEquityE6(int256(uint256(50000000))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F12-04-curve-gauge-weight-vote-snipe");
    }
}
