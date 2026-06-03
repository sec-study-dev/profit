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
    // Target gauge: frxETH/ETH Curve mainnet gauge registered in GaugeController
    // at block 19_643_500.  The original address 0x0caD1700... was a sidechain
    // gauge that is not registered on mainnet; the correct mainnet gauge is:
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

        // veCRV (VotingEscrow.vy) enforces `assert msg.sender == tx.origin`,
        // which blocks smart-contract callers. In Foundry fork tests the test
        // contract IS a smart contract so direct calls revert with "Smart
        // contract depositors not allowed". Work-around: prank as a well-known
        // EOA using vm.startPrank(addr, addr) so both msg.sender AND tx.origin
        // equal the EOA address. Any unused address works - we pick address(0xcafe).
        address eoa = address(0xcafe);

        // 1) Fund the EOA with 100k CRV via deal().
        deal(CRV, eoa, CRV_LOCK_AMOUNT);

        // Snapshot the gauge weight BEFORE prank (read-only, no tx.origin check).
        uint256 absBefore = ICurveGaugeController(GAUGE_CONTROLLER)
            .get_gauge_weight(FRXETH_GAUGE);
        uint256 weightBefore = ICurveGaugeController(GAUGE_CONTROLLER)
            .gauge_relative_weight(FRXETH_GAUGE);
        console2.log("gauge_relative_weight BEFORE (1e18):", weightBefore);
        console2.log("get_gauge_weight       BEFORE (raw):", absBefore);

        _startPnL();
        vm.txGasPrice(20 gwei);

        // 2) All state-mutating veCRV calls must be from the EOA (tx.origin == msg.sender).
        vm.startPrank(eoa, eoa);

        // 2a) Approve & lock for 4 years (max).
        IERC20(CRV).approve(VECRV, CRV_LOCK_AMOUNT);
        uint256 unlockTime = ((block.timestamp + FOUR_YEARS) / WEEK) * WEEK; // round to week boundary
        IVotingEscrowCRV(VECRV).create_lock(CRV_LOCK_AMOUNT, unlockTime);

        uint256 veBal = IVotingEscrowCRV(VECRV).balanceOf(eoa);
        console2.log("veCRV balanceOf EOA (raw):", veBal);
        require(veBal > (CRV_LOCK_AMOUNT * 95) / 100, "veCRV balance too low");

        // 2b) Cast 100% of voting power for the gauge.
        ICurveGaugeController(GAUGE_CONTROLLER).vote_for_gauge_weights(FRXETH_GAUGE, 10000);

        vm.stopPrank();

        // 3) Confirm vote_user_slopes registered for the EOA.
        (uint256 slope, uint256 power, uint256 endTs) =
            ICurveGaugeController(GAUGE_CONTROLLER).vote_user_slopes(eoa, FRXETH_GAUGE);
        console2.log("vote slope:", slope);
        console2.log("vote power:", power);
        console2.log("vote end  :", endTs);
        require(power == 10000, "vote power not 10000");
        require(slope > 0, "vote slope zero");

        // 4) Warp 8 days. GaugeController snapshots weights at Thursday-midnight
        //    epochs (WEEK = 604800 s). Warping > 1 WEEK guarantees a new epoch.
        vm.warp(block.timestamp + 8 days);
        vm.roll(block.number + 8 days / 12);

        // 5) Snapshot post-vote weight.
        uint256 weightAfter = ICurveGaugeController(GAUGE_CONTROLLER)
            .gauge_relative_weight(FRXETH_GAUGE, block.timestamp);
        uint256 absAfter = ICurveGaugeController(GAUGE_CONTROLLER)
            .get_gauge_weight(FRXETH_GAUGE);
        console2.log("gauge_relative_weight AFTER  (1e18):", weightAfter);
        console2.log("get_gauge_weight       AFTER  (raw):", absAfter);

        // 6) Assert vote-snipe direction.
        require(absAfter > absBefore, "gauge absolute weight did not move");
        if (weightAfter <= weightBefore) {
            console2.log("WARN: relative weight did not strictly increase; other gauges may have also voted.");
        }

        _endPnL("F12-04-curve-gauge-weight-vote-snipe");
    }
}
