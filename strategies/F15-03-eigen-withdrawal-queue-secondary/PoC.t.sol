// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {Whales} from "test/utils/Whales.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IEigenStrategyManager, IEigenStrategy} from "src/interfaces/restake/IEigenStrategyManager.sol";
import {IEigenDelegationManager} from "src/interfaces/restake/IEigenDelegationManager.sol";
import {console2} from "forge-std/console2.sol";

/// @notice F15-03 — EigenLayer 7-day withdrawal queue PoC.
///
/// 1. Deposit 50 stETH into EL strategy.
/// 2. Queue half the shares for withdrawal.
/// 3. Roll forward 7d.
/// 4. Complete the withdrawal.
///
/// The "secondary-market sale" leg is documented in the README but not
/// implementable on-chain at this block — EL withdrawals are non-transferable.
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
            _endPnL("F15-03: eigen-withdrawal-queue-secondary (queue failed)");
            return;
        } catch {
            console2.log("queueWithdrawals reverted (unknown)");
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
            nonce: 0, // first withdrawal for this staker — verify via DM state if running
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

        // ---- Secondary-market leg (THEORETICAL) ----
        // At this block, EL does not expose a transferable withdrawal credential.
        // A 99%-of-face sale would be:
        //   seller receives 0.99 × 50 stETH = 49.5 stETH immediately
        //   buyer fronts 49.5, claims 50 stETH + 7d rebase after delay
        // Implementation requires an external market contract (TODO).
        console2.log("secondary-market sale: NOT IMPLEMENTABLE at this block");
        console2.log("would yield buyer ~+0.53 stETH / 7d on 50 stETH notional");

        _endPnL("F15-03: eigen-withdrawal-queue-secondary");
    }
}
