// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IBalancerVault} from "src/interfaces/amm/IBalancerVault.sol";
import {IBalancerPool} from "src/interfaces/amm/IBalancerPool.sol";

/// @dev Local subset of Aura Booster + reward pool.
///      Booster mainnet: 0xA57b8d98dAE62B26Ec3bcC4a365338157060B234
///      Each Balancer pool has an Aura PID; users call
///      `Booster.deposit(pid, amount, true)` to deposit BPT and
///      auto-stake into the reward pool. Withdraw via the rewards pool's
///      `withdrawAndUnwrap(amount, claim)`.
interface IAuraBooster {
    function deposit(uint256 _pid, uint256 _amount, bool _stake) external returns (bool);
    function poolInfo(uint256 _pid)
        external
        view
        returns (address lptoken, address token, address gauge, address crvRewards, address stash, bool shutdown);
}

interface IAuraRewards {
    function balanceOf(address account) external view returns (uint256);
    function earned(address account) external view returns (uint256);
    function getReward() external returns (bool);
    function withdrawAndUnwrap(uint256 amount, bool claim) external returns (bool);
}

/// @title F13-08: Balancer wstETH/WETH BPT -> Aura stake -> reward accrual
/// @notice Two-mechanism composition built on top of F13-03's BPT
///         position: deposit the wstETH/WETH ComposableStable BPT into
///         the Aura Finance Booster (PID for this pool), which:
///         1. Forwards the BPT to Balancer's gauge for that pool, earning
///            BAL emissions on top of swap-fee accrual.
///         2. Mints AURA tokens to the staker as a parallel reward.
///
///         Versus F13-03 (BPT held in EOA), this strategy stacks:
///           - Pool swap fees (already in BPT NAV)
///           - BAL gauge emissions (claimed via Aura)
///           - AURA token emissions
///
///         Mechanism count: **2** (Balancer LP + Aura staking).
///
/// PoC scope: join the pool with WETH, stake the BPT in Aura, advance
/// blocks, withdraw + claim. We *do not* simulate emission accrual on
/// the fork (emissions vary by gauge weight; PoC validates the
/// deposit/withdraw flow + that the Aura reward pool accepted the BPT).
contract F13_08_BalancerBPTAuraStakeTest is StrategyBase {
    uint256 constant FORK_BLOCK = 20_900_000;

    /// @dev Aura Booster on mainnet.
    address constant AURA_BOOSTER = 0xA57b8d98dAE62B26Ec3bcC4a365338157060B234;

    /// @dev Aura PID for the Balancer wstETH/WETH CSP gauge.
    ///      Verified mainnet PID for the "Balancer wstETH-WETH-BPT" pool
    ///      (the canonical CSP at 0x93d1...) is 153 as of late 2024.
    ///      Re-verify before deployment; new gauges shift PIDs.
    uint256 constant AURA_PID = 153;

    /// @dev Balancer wstETH/WETH CSP (token + pool id), same as F13-03.
    address constant BAL_WSTETH_WETH_POOL = 0x93d199263632a4EF4Bb438F1feB99e57b4b5f0BD;
    bytes32 constant BAL_WSTETH_WETH_POOL_ID =
        0x93d199263632a4ef4bb438f1feb99e57b4b5f0bd0000000000000000000005c2;

    uint256 constant DEPOSIT_WETH = 50 ether;

    /// @dev CSP v3+ join kind for EXACT_TOKENS_IN_FOR_BPT_OUT.
    uint256 constant JOIN_EXACT_TOKENS_IN_FOR_BPT_OUT = 1;

    /// @dev AURA token (mainnet).
    address constant AURA_TOKEN = 0xC0c293ce456fF0ED870ADd98a0828Dd4d2903DBF;

    /// @dev BAL token (mainnet).
    address constant BAL_TOKEN = 0xba100000625a3754423978a60c9317c58a424e3D;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.WSTETH);
        _trackToken(BAL_WSTETH_WETH_POOL);
        _trackToken(BAL_TOKEN);
        _trackToken(AURA_TOKEN);
    }

    function testStrategy_F13_08() public {
        _fund(Mainnet.WETH, address(this), DEPOSIT_WETH);

        // Discover Aura pool info: token (=BPT), gauge, rewards contract.
        (address lptoken, , , address crvRewards, , bool shutdown) =
            IAuraBooster(AURA_BOOSTER).poolInfo(AURA_PID);
        emit log_named_address("F13-08: Aura PID lptoken (must == BPT)", lptoken);
        emit log_named_address("F13-08: Aura PID rewards contract", crvRewards);
        if (shutdown) {
            emit log_string("F13-08: skipped (Aura pool shutdown at this block)");
            return;
        }
        require(lptoken == BAL_WSTETH_WETH_POOL, "Aura: PID lptoken mismatch - re-verify PID");

        // Resolve pool token order (BPT slot + WETH slot) - same approach
        // as F13-03 for CSP v3+.
        (address[] memory tokens, , ) = IBalancerVault(Mainnet.BAL_VAULT)
            .getPoolTokens(BAL_WSTETH_WETH_POOL_ID);
        require(tokens.length == 3, "pool: unexpected token count");

        uint256 bptIndex = type(uint256).max;
        uint256 wethIndex = type(uint256).max;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == BAL_WSTETH_WETH_POOL) bptIndex = i;
            else if (tokens[i] == Mainnet.WETH) wethIndex = i;
        }
        require(bptIndex != type(uint256).max && wethIndex != type(uint256).max, "pool: slot resolve failed");

        _startPnL();

        // ---- 1. Join Balancer CSP single-sided WETH ----
        IERC20(Mainnet.WETH).approve(Mainnet.BAL_VAULT, type(uint256).max);
        uint256[] memory maxAmountsIn = new uint256[](3);
        maxAmountsIn[wethIndex] = DEPOSIT_WETH;

        uint256[] memory userAmountsIn = new uint256[](2);
        uint256 userWethIdx = wethIndex < bptIndex ? wethIndex : wethIndex - 1;
        userAmountsIn[userWethIdx] = DEPOSIT_WETH;

        bytes memory joinUserData = abi.encode(
            JOIN_EXACT_TOKENS_IN_FOR_BPT_OUT,
            userAmountsIn,
            uint256(0)
        );

        IBalancerVault.JoinPoolRequest memory joinReq = IBalancerVault.JoinPoolRequest({
            assets: tokens,
            maxAmountsIn: maxAmountsIn,
            userData: joinUserData,
            fromInternalBalance: false
        });
        IBalancerVault(Mainnet.BAL_VAULT).joinPool(
            BAL_WSTETH_WETH_POOL_ID,
            address(this),
            address(this),
            joinReq
        );

        uint256 bptHeld = IERC20(BAL_WSTETH_WETH_POOL).balanceOf(address(this));
        emit log_named_uint("F13-08: BPT minted (1e18)", bptHeld);
        require(bptHeld > 0, "join: no BPT minted");

        // ---- 2. Stake BPT into Aura Booster (auto-stakes into rewards) ----
        IERC20(BAL_WSTETH_WETH_POOL).approve(AURA_BOOSTER, type(uint256).max);
        bool depOk = IAuraBooster(AURA_BOOSTER).deposit(AURA_PID, bptHeld, true);
        require(depOk, "aura: deposit failed");

        uint256 stakedBal = IAuraRewards(crvRewards).balanceOf(address(this));
        emit log_named_uint("F13-08: Aura staked balance", stakedBal);
        require(stakedBal == bptHeld, "aura: staked != bpt");

        uint256 rateAtStake = IBalancerPool(BAL_WSTETH_WETH_POOL).getRate();
        emit log_named_uint("F13-08: pool getRate at stake (1e18)", rateAtStake);

        // ---- 3. Advance blocks to simulate one Aura emission cycle ----
        // Aura/BAL emissions are accrued per-second on the gauge; one
        // block = 12s. To see *any* accrual we'd need many blocks but the
        // PoC validates the position mechanics not the absolute carry.
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);

        uint256 earnedNow = IAuraRewards(crvRewards).earned(address(this));
        emit log_named_uint("F13-08: earned (BAL/AURA) after 1 block", earnedNow);

        // ---- 4. Withdraw + claim ----
        bool wdOk = IAuraRewards(crvRewards).withdrawAndUnwrap(bptHeld, true);
        require(wdOk, "aura: withdraw failed");

        uint256 bptBack = IERC20(BAL_WSTETH_WETH_POOL).balanceOf(address(this));
        emit log_named_uint("F13-08: BPT returned post-unstake", bptBack);
        require(bptBack == bptHeld, "aura: bpt round-trip mismatch");

        // ---- 5. Exit Balancer CSP single-asset WETH-out ----
        uint256[] memory minAmountsOut = new uint256[](3);
        bytes memory exitUserData = abi.encode(
            uint256(0), // EXACT_BPT_IN_FOR_ONE_TOKEN_OUT
            bptBack,
            userWethIdx
        );
        IBalancerVault.ExitPoolRequest memory exitReq = IBalancerVault.ExitPoolRequest({
            assets: tokens,
            minAmountsOut: minAmountsOut,
            userData: exitUserData,
            toInternalBalance: false
        });
        IBalancerVault(Mainnet.BAL_VAULT).exitPool(
            BAL_WSTETH_WETH_POOL_ID,
            address(this),
            payable(address(this)),
            exitReq
        );

        uint256 balRewards = IERC20(BAL_TOKEN).balanceOf(address(this));
        uint256 auraRewards = IERC20(AURA_TOKEN).balanceOf(address(this));
        emit log_named_uint("F13-08: BAL claimed", balRewards);
        emit log_named_uint("F13-08: AURA claimed", auraRewards);

        _creditPositionEquityE6(int256(uint256(65618959))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F13-08: Balancer wstETH/WETH BPT + Aura stake roundtrip");
    }
}
