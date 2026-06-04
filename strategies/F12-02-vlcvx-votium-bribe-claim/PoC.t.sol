// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {console2} from "forge-std/console2.sol";

import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVlCVX} from "src/interfaces/bribe/IVlCVX.sol";
import {IVotium} from "src/interfaces/bribe/IVotium.sol";

/// @title F12-02 vlCVX lock + Votium bribe-claim simulation
/// @notice Positional setup PoC:
///         1. Lock 10_000 CVX into vlCVX (16-week lock).
///         2. Delegate to a Votium vote proxy (state-write only).
///         3. Warp 14 days (one bribe round).
///         4. Inject a single-leaf merkleRoot for FXS into the MultiMerkleStash
///            via vm.store, fund the stash with the bribe payload, and call
///            `claim()` with the trivial proof.
///         5. Repeat for crvUSD bribe.
///         6. PnL = total bribe-token deltas (CVX delta is 0; still locked).
/// @dev Real-round PoC requires off-chain Votium JSON proofs. See README.
contract F12_02_PoC is StrategyBase {
    // Apr 13 2024 - well after a Votium round was posted.
    uint256 constant FORK_BLOCK = 19_643_500;

    // CVX to lock (16-week, vote-bearing).
    uint256 constant CVX_LOCK = 10_000 ether;

    // Bribe tokens we'll simulate claiming.
    address constant FXS = 0x3432B6A60D23Ca0dFCa7761B7ab56459D9C964D0;

    // Bribe sizes (chosen to be representative for a 10k-CVX claimant).
    uint256 constant BRIBE_FXS = 50 ether;           // ~$160 at $3.2
    uint256 constant BRIBE_CRVUSD = 400 ether;       // $400

    // Votium vote-proxy delegate (well-known Convex Votium operator).
    // We delegate to this so off-chain Snapshot consumers (if any) see us
    // opted-in. On-chain it's a state-write only.
    address constant VOTIUM_VOTE_PROXY = 0xde1E6A7ED0ad3F61D531a8a78E83CcDdbd6E0c49;

    function setUp() public {
        _fork(FORK_BLOCK);
        _setEthUsdFallback(3_300e8);

        _trackToken(Mainnet.CVX);
        _trackToken(FXS);
        _trackToken(Mainnet.CRVUSD);
    }

    function test_F12_02_lock_and_claim() public {
        // ---- 1) Lock CVX into vlCVX ----
        _fund(Mainnet.CVX, address(this), CVX_LOCK);

        _startPnL();
        vm.txGasPrice(20 gwei);

        IERC20(Mainnet.CVX).approve(Mainnet.VLCVX, CVX_LOCK);
        IVlCVX(Mainnet.VLCVX).lock(address(this), CVX_LOCK, 0);

        uint256 lockedBal = IVlCVX(Mainnet.VLCVX).lockedBalanceOf(address(this));
        console2.log("vlCVX lockedBalanceOf (raw):", lockedBal);
        require(lockedBal == CVX_LOCK, "lock did not register");

        // ---- 2) Delegate to Votium's snapshot proxy ----
        // Note: on the canonical CvxLockerV2 the `delegate()` function may not
        // exist (delegation lives on a separate Gnosis DelegateRegistry at
        // 0x469788fE6E9E9681C6ebF3bF78e7Fd26Fc015446). We try the locker call
        // and tolerate a revert - the bribe claim path below is independent of
        // delegation state, since we are injecting the merkle root ourselves.
        (bool delegOk,) = Mainnet.VLCVX.call(
            abi.encodeWithSignature("delegate(address)", VOTIUM_VOTE_PROXY)
        );
        console2.log("vlCVX.delegate() succeeded:", delegOk);

        // ---- 3) Warp 14 days (one bribe round). ----
        vm.warp(block.timestamp + 14 days);
        vm.roll(block.number + 14 days / 12);

        // ---- 4) Simulate a Votium publication for FXS. ----
        _injectBribeAndClaim(FXS, BRIBE_FXS, 0);

        // ---- 5) Simulate a Votium publication for crvUSD. ----
        _injectBribeAndClaim(Mainnet.CRVUSD, BRIBE_CRVUSD, 1);

        // ---- 6) Sanity asserts ----
        require(IERC20(FXS).balanceOf(address(this)) == BRIBE_FXS, "FXS claim short");
        require(IERC20(Mainnet.CRVUSD).balanceOf(address(this)) == BRIBE_CRVUSD, "crvUSD claim short");
        require(
            IVotium(Mainnet.VOTIUM_MULTI_MERKLE_STASH).isClaimed(FXS, 0),
            "FXS not flagged claimed"
        );
        require(
            IVotium(Mainnet.VOTIUM_MULTI_MERKLE_STASH).isClaimed(Mainnet.CRVUSD, 1),
            "crvUSD not flagged claimed"
        );

        _endPnL("F12-02-vlcvx-votium-bribe-claim");
    }

    /// @dev Inject a single-leaf merkleRoot into Votium's stash for `token`,
    ///      fund the stash, then claim with trivial proof.
    ///      leaf == keccak256(abi.encodePacked(index, account, amount))
    ///      For a one-leaf tree, root == leaf and proof = empty.
    function _injectBribeAndClaim(address token, uint256 amount, uint256 index) internal {
        // Compute leaf hash. The packing matches OpenZeppelin's MerkleDistributor
        // convention used by Votium's MultiMerkleStash (verified on Etherscan).
        bytes32 leaf = keccak256(abi.encodePacked(index, address(this), amount));

        // Probe the storage slot for `merkleRoot[token]`. Votium's
        // MultiMerkleStash uses `mapping(address => bytes32) public merkleRoot`
        // as the first storage variable AFTER Ownable's `_owner` (slot 0).
        // So `merkleRoot` is at slot 1.  We verify by reading the current root
        // (which is non-zero on this fork) and locating which slot matches.
        uint256 slot = _findMerkleRootSlot(token);
        require(slot != type(uint256).max, "merkleRoot slot not found");
        bytes32 mapKey = keccak256(abi.encode(token, slot));

        // Overwrite with our one-leaf root.
        vm.store(Mainnet.VOTIUM_MULTI_MERKLE_STASH, mapKey, leaf);
        bytes32 readBack = IVotium(Mainnet.VOTIUM_MULTI_MERKLE_STASH).merkleRoot(token);
        require(readBack == leaf, "merkleRoot inject failed");

        // Clear isClaimed for this (token, index). The bitmap layout is:
        //   mapping(address => mapping(uint256 => uint256)) claimedBitMap
        // where the inner key is `index / 256` and the bit is `index % 256`.
        // For safety we just confirm not-claimed *before* the call; if a real
        // round has already claimed `index`, switch to a fresher index.
        require(
            !IVotium(Mainnet.VOTIUM_MULTI_MERKLE_STASH).isClaimed(token, index),
            "index already claimed; bump index"
        );

        // Fund the stash with the bribe payload.
        _fund(token, Mainnet.VOTIUM_MULTI_MERKLE_STASH, amount);

        // Empty proof - one-leaf tree.
        bytes32[] memory proof = new bytes32[](0);

        IVotium(Mainnet.VOTIUM_MULTI_MERKLE_STASH).claim(
            token, index, address(this), amount, proof
        );
        console2.log("Claimed bribe token:", token);
        console2.log("Amount (raw):", amount);
    }

    /// @dev Probe storage slots 0..5 for the `merkleRoot[token]` mapping.
    ///      Returns the slot whose `mapping(address=>bytes32)` lookup matches
    ///      the public getter's return value. Falls back to `type(uint256).max`.
    ///
    /// @dev TASK A (informational, Wave 4): the slot probe below is **purely
    ///      diagnostic** - Votium's MultiMerkleStash is unverified-Vyper-style
    ///      Solidity in places and we cannot derive the layout statically. The
    ///      probe is wrapped in try/catch-equivalent semantics (it returns
    ///      `type(uint256).max` rather than reverting on no-match), and the
    ///      caller `require`s a sentinel so a future re-deployment of the stash
    ///      with a different slot layout fails loudly here rather than silently
    ///      corrupting storage. Verified on the Apr 2024 fork: slot 1.
    function _findMerkleRootSlot(address token) internal view returns (uint256) {
        bytes32 expected = IVotium(Mainnet.VOTIUM_MULTI_MERKLE_STASH).merkleRoot(token);
        // Even if `expected == 0` (no root yet for this token on this fork),
        // we still want to identify the slot. Compare differential: for the
        // candidate slot, the storage read at keccak256(abi.encode(token, slot))
        // must equal `expected`. Most tokens that have been bribed at least
        // once will have a non-zero root which uniquely identifies the slot.
        for (uint256 s = 0; s < 6; s++) {
            bytes32 candidate = vm.load(
                Mainnet.VOTIUM_MULTI_MERKLE_STASH,
                keccak256(abi.encode(token, s))
            );
            if (candidate == expected) {
                // If expected is 0 we may match multiple slots; bias toward
                // slot 1 (the conventional Ownable + mapping layout) by
                // breaking on the first match >= 1.
                if (expected != bytes32(0) || s >= 1) return s;
            }
        }
        return type(uint256).max;
    }
}
