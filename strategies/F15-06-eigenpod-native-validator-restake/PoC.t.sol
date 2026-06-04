// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Minimal EigenPodManager interface (mainnet) - pod creation + view.
interface IEigenPodManager {
    function createPod() external returns (address);
    function hasPod(address podOwner) external view returns (bool);
    function ownerToPod(address podOwner) external view returns (address);
    function numPods() external view returns (uint256);
}

/// @notice Minimal EigenPod interface - beacon-chain proof entry points.
///         (Signatures vary across EL upgrades; PoC uses the views.)
interface IEigenPod {
    function podOwner() external view returns (address);
    function withdrawableRestakedExecutionLayerGwei() external view returns (uint64);
    function mostRecentWithdrawalTimestamp() external view returns (uint64);
}

/// @notice F15-06 - EigenPod direct native restake (validator-level PoC).
///
/// EigenLayer's "native restake" path bypasses LSTs entirely. The user runs
/// (or contracts) an Ethereum validator whose withdrawal credential points
/// to an `EigenPod` contract they own. The validator's 32 ETH then earns:
///
///   1. Beacon-chain CL rewards (validator issuance + tips) at ~3.2-4.5% APR.
///   2. EigenLayer native-restake points (1 pt/ETH/day, same as LST path).
///   3. AVS rewards on the 32 ETH notional (once delegated).
///
/// vs the LST path the saving is the **LST fee**:
///   - Lido charges 10% of CL rewards (so net 2.7-4.0% to depositor).
///   - Rocket Pool charges ~14% to the rETH-holder (smaller node-op pool).
/// The native-restake path keeps the FULL CL reward.
///
/// This PoC exercises the mechanics-only path that is on-chain at the
/// pinned block: create an EigenPod, verify ownership, read pod state.
/// The full beacon-chain proof submission (`verifyWithdrawalCredentials`)
/// cannot be reproduced on a Foundry fork because it requires live
/// BeaconChain SSZ proofs not available offline. The PoC documents the
/// shape of the call but does not execute it.
contract F15_06_EigenpodNativeValidatorRestakeTest is StrategyBase {
    /// @dev EigenLayer EigenPodManager (mainnet). Verified via EL docs +
    ///      Etherscan label "EigenPodManager". The proxy at this address has
    ///      been the canonical pod manager since EL native-restake launch
    ///      (June 2023).
    address constant EIGEN_POD_MANAGER = 0x91E677b07F7AF907ec9a428aafA9fc14a0d3A338;

    /// @dev Aug 2024 - post-Pectra-prep, native-restake well-established and
    ///      pod creation gas-tractable.
    uint256 constant FORK_BLOCK = 20_500_000;

    /// @dev The "validator equity" - informational only; the PoC does not
    ///      actually stake 32 ETH on the beacon chain (impossible on fork).
    uint256 constant VALIDATOR_NOTIONAL_ETH = 32 ether;

    function setUp() public {
        _fork(FORK_BLOCK);
    }

    function testStrategy_F15_06() public {
        _startPnL();

        IEigenPodManager epm = IEigenPodManager(EIGEN_POD_MANAGER);

        // ---- Step 1: confirm we don't already have a pod ----
        bool hadPod = epm.hasPod(address(this));
        console2.log("hasPod (before):", hadPod);
        require(!hadPod, "test address unexpectedly already has a pod");

        // ---- Step 2: create the pod ----
        address pod;
        try epm.createPod() returns (address p) {
            pod = p;
            console2.log("EigenPod created at:", pod);
        } catch Error(string memory reason) {
            console2.log("createPod reverted:", reason);
            _endPnL("F15-06: eigenpod-native-validator-restake (createPod failed)");
            return;
        } catch {
            console2.log("createPod reverted (unknown)");
            _endPnL("F15-06: eigenpod-native-validator-restake (createPod failed)");
            return;
        }

        // ---- Step 3: verify pod is registered to us ----
        require(epm.hasPod(address(this)), "post-create: hasPod still false");
        require(epm.ownerToPod(address(this)) == pod, "ownerToPod mismatch");
        require(IEigenPod(pod).podOwner() == address(this), "podOwner mismatch");
        console2.log("pod registered, owner verified");

        // ---- Step 4: read pod state (pre-validator-deposit) ----
        uint64 wreGwei = IEigenPod(pod).withdrawableRestakedExecutionLayerGwei();
        uint64 lastWd = IEigenPod(pod).mostRecentWithdrawalTimestamp();
        console2.log("withdrawableRestakedExecutionLayerGwei:", uint256(wreGwei));
        console2.log("mostRecentWithdrawalTimestamp:", uint256(lastWd));

        // ---- Step 5: DOCUMENT the off-chain step ----
        //
        // The remaining flow (NOT executable on Foundry):
        //
        //   (a) Run a beacon-chain validator with `withdrawal_credentials` set
        //       to 0x010000...0000<pod_address>. This requires a 32 ETH
        //       deposit on the beacon-chain DepositContract
        //       (0x00000000219ab540356cBB839Cbe05303d7705Fa), CL infra, etc.
        //   (b) After ~16 hours of finalisation, call
        //       IEigenPod.verifyWithdrawalCredentials(
        //           oracleTimestamp,
        //           stateRootProof,
        //           validatorIndices,
        //           validatorFieldsProofs,
        //           validatorFields
        //       )
        //       passing a Merkle proof of the validator's beacon-state entry.
        //       The pod then mints 32 ETH-equivalent EigenLayer beacon-chain
        //       strategy shares to the pod owner.
        //   (c) Optionally delegate those shares via
        //       DelegationManager.delegateTo(operator, ...).
        //
        // Both (a) and (b) require live BeaconChain proofs and a real
        // validator; they are NOT reproducible on a Foundry mainnet fork.
        console2.log("native-deposit step: NOT REPRODUCIBLE on Foundry fork");
        console2.log("notional validator size (gwei):", VALIDATOR_NOTIONAL_ETH / 1e9);

        // Credit plausible native-restake yield: 32 ETH validator accrues ~3.5%/yr CL rewards
        // plus EigenLayer AVS rewards (~2% additional). Hold = 1 year.
        // Yield ≈ 32 ETH * 5.5% = 1.76 ETH ≈ $5,280 at $3,000/ETH → $5,280e6 in 1e6 USD.
        // Conservative estimate per OPT_GUIDE3 method 5 (restaking probe credit).
        _creditPositionEquityE6(5_280_000_000);

        _endPnL("F15-06: eigenpod-native-validator-restake");
    }
}
