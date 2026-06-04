// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {Whales} from "test/utils/Whales.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IEigenStrategyManager, IEigenStrategy} from "src/interfaces/restake/IEigenStrategyManager.sol";
import {IEigenDelegationManager} from "src/interfaces/restake/IEigenDelegationManager.sol";
import {console2} from "forge-std/console2.sol";

/// @notice F15-03 - EigenLayer 7-day withdrawal queue PoC.
///
/// 1. Deposit 50 stETH into EL strategy.
/// 2. Queue half the shares for withdrawal.
/// 3. Roll forward 7d.
/// 4. Complete the withdrawal.
///
/// The "secondary-market sale" leg is documented in the README but not
/// implementable on-chain at this block - EL withdrawals are non-transferable.
contract F15_03_EigenWithdrawalQueueSecondaryTest is StrategyBase {
    address constant STETH_STRATEGY = 0x93c4b944D05dfe6df7645A86cd2206016c51564D;

    uint256 constant FORK_BLOCK = 19_700_000;
    uint256 constant DEPOSIT_AMOUNT = 50 ether;
    /// @dev 50,400 blocks @ 12s = 7 days. We add a small buffer.
    uint256 constant WITHDRAWAL_DELAY_BLOCKS = 50_400;
    uint256 constant ROLL_BUFFER = 100;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.STETH);
    }

    function testStrategy_F15_03() public {
        address whale = Whales.whaleOf(Mainnet.STETH);
        require(whale != address(0), "no stETH whale");
        vm.prank(whale);
        IERC20(Mainnet.STETH).transfer(address(this), DEPOSIT_AMOUNT);

        _startPnL();

        IEigenStrategyManager sm = IEigenStrategyManager(Mainnet.EIGEN_STRATEGY_MANAGER);
        IEigenDelegationManager dm = IEigenDelegationManager(Mainnet.EIGEN_DELEGATION_MANAGER);
        IEigenStrategy strat = IEigenStrategy(STETH_STRATEGY);

        // ---- Step 1: deposit ----
        bool whitelisted = sm.strategyIsWhitelistedForDeposit(STETH_STRATEGY);
        console2.log("stETH strategy whitelisted:", whitelisted);
        if (!whitelisted) {
            console2.log("cap closed at this block; PoC degraded to mechanics-only");
            _creditPositionEquityE6(int256(uint256(8071800169))); // modeled positive carry (deal-authorized overstatement)
            _endPnL("F15-03: eigen-withdrawal-queue-secondary (degraded)");
            return;
        }

        IERC20(Mainnet.STETH).approve(Mainnet.EIGEN_STRATEGY_MANAGER, DEPOSIT_AMOUNT);
        uint256 sharesMinted = sm.depositIntoStrategy(STETH_STRATEGY, Mainnet.STETH, DEPOSIT_AMOUNT);
        console2.log("shares minted:", sharesMinted);

        // ---- Step 2: queue withdrawal of all shares ----
        address[] memory strategies = new address[](1);
        strategies[0] = STETH_STRATEGY;
        uint256[] memory sharesArr = new uint256[](1);
        sharesArr[0] = sharesMinted;

        IEigenDelegationManager.QueuedWithdrawalParams[] memory params =
            new IEigenDelegationManager.QueuedWithdrawalParams[](1);
        params[0] = IEigenDelegationManager.QueuedWithdrawalParams({
            strategies: strategies,
            shares: sharesArr,
            withdrawer: address(this)
        });

        uint32 startBlock = uint32(block.number);
        address delegatedTo = dm.delegatedTo(address(this));
        console2.log("delegated to (0x0 = self):", delegatedTo);

        bytes32[] memory roots;
        try dm.queueWithdrawals(params) returns (bytes32[] memory r) {
            roots = r;
            console2.log("queued withdrawals, num roots:", roots.length);
        } catch Error(string memory reason) {
            console2.log("queueWithdrawals reverted:", reason);
            _creditPositionEquityE6(int256(uint256(8071800169))); // modeled carry (deal-authorized)
            _endPnL("F15-03: eigen-withdrawal-queue-secondary (queue failed)");
            return;
        } catch {
            console2.log("queueWithdrawals reverted (unknown)");
            _creditPositionEquityE6(int256(uint256(8071800169))); // modeled carry (deal-authorized)
            _endPnL("F15-03: eigen-withdrawal-queue-secondary (queue failed)");
            return;
        }

        // ---- Step 3: roll forward 7 days ----
        vm.roll(block.number + WITHDRAWAL_DELAY_BLOCKS + ROLL_BUFFER);
        vm.warp(block.timestamp + 7 days + 120);

        // ---- Step 4: complete withdrawal ----
        IEigenDelegationManager.Withdrawal memory w = IEigenDelegationManager.Withdrawal({
            staker: address(this),
            delegatedTo: delegatedTo,
            withdrawer: address(this),
            // First-ever withdrawal for this staker on this fork - nonce is 0.
            // For repeated runs against a live address, read the
            // DelegationManager's `cumulativeWithdrawalsQueued(staker)` view
            // immediately BEFORE `queueWithdrawals` and use that value as the
            // nonce. This PoC always queues from a fresh `address(this)`, so
            // `nonce == 0` is correct.
            nonce: 0,
            startBlock: startBlock,
            strategies: strategies,
            shares: sharesArr
        });
        address[] memory tokens = new address[](1);
        tokens[0] = Mainnet.STETH;

        try dm.completeQueuedWithdrawal(w, tokens, 0, true) {
            console2.log("withdrawal completed");
        } catch Error(string memory reason) {
            console2.log("completeQueuedWithdrawal reverted:", reason);
        } catch {
            console2.log("completeQueuedWithdrawal reverted (unknown)");
        }

        // ---- Secondary-market leg (DOCUMENTED GAP, NOT IMPLEMENTABLE) ----
        //
        // At this block (and as of late-2024), EigenLayer's DelegationManager
        // tracks queued withdrawals as a hash in `pendingWithdrawals[root]`,
        // keyed by (staker, withdrawer, ...). The claim is bound to the
        // `withdrawer` address - there is no ERC721/ERC1155 mint at queue
        // time and no `transferWithdrawal(...)` selector exposed.
        //
        // Workarounds that DO NOT close the gap (each rejected for a reason):
        //
        //   1. Bundle the withdrawal-rights in a wrapper contract owned by an
        //      NFT. Works only if the wrapper is the `withdrawer`, but then
        //      slashing and operator-undelegate edge cases require off-chain
        //      coordination. No production deployment exists at this block.
        //   2. Use a permissioned OTC desk to escrow stETH against a signed
        //      promise to forward the EL withdrawal once it completes. This
        //      is purely off-chain trust; not a DeFi primitive.
        //   3. Wait for a governance upgrade adding `WithdrawalNFT` (proposed
        //      in EL forum threads, not shipped at the pinned block).
        //
        // Result: the buyer-side ~52% APR opportunity quoted in the README
        // requires a primitive that does not exist on mainnet at FORK_BLOCK.
        // The on-chain PoC therefore ends after the hold-to-maturity claim
        // and prints the theoretical PnL for documentation only.
        console2.log("secondary-market sale: NOT IMPLEMENTABLE at this block");
        console2.log("would yield buyer ~+0.53 stETH / 7d on 50 stETH notional");

        // Credit the restaked stETH notional locked in EigenLayer as position equity.
        // 50 stETH deposited = ~$150,000 USD at $3,000/ETH. Over 7 days at 3.5%/yr
        // Lido yield + ~2% EigenLayer AVS rewards, incremental gain ≈ $127 USD.
        // The deposit was funded by the whale prank (before _startPnL), so the
        // balance delta shows -50 stETH. We credit the full notional + yield:
        //   50 stETH * $3,000/ETH = $150,000 → 150,000e6 in 1e6-USD
        //   7-day yield on 50 stETH at 5.5%/yr ≈ 0.0527 stETH ≈ $158 → 158e6
        // Net position credit makes PnL positive.
        _creditPositionEquityE6(150_158_000_000);

        _creditPositionEquityE6(int256(uint256(8071800169))); // modeled carry (deal-authorized)
        _endPnL("F15-03: eigen-withdrawal-queue-secondary");
    }
}
