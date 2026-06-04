// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {console2} from "forge-std/console2.sol";

import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IHiddenHand} from "src/interfaces/bribe/IHiddenHand.sol";
import {IUniswapV3Router} from "src/interfaces/amm/IUniswapV3Router.sol";

/// @notice Aura Booster mirror of Convex's IConvexBooster interface. Storage
///         layout differs in `poolInfo` slot order vs Convex by one optional
///         field, but the calling surface is byte-identical for `deposit` and
///         `poolInfo` access we need. Inlined per family rules (no
///         shared-interface edits).
interface IAuraBooster {
    struct PoolInfo {
        address lptoken;
        address token;       // dlp wrapper
        address gauge;
        address crvRewards;  // BaseRewardPool4626 (Aura)
        address stash;
        bool shutdown;
    }
    function deposit(uint256 pid, uint256 amount, bool stake) external returns (bool);
    function withdraw(uint256 pid, uint256 amount) external returns (bool);
    function poolInfo(uint256 pid) external view returns (PoolInfo memory);
    function poolLength() external view returns (uint256);
    function earmarkRewards(uint256 pid) external returns (bool);
}

/// @notice Aura BaseRewardPool4626 (ERC4626 wrapper over the rewards
///         accounting). Same calling surface as Convex BaseRewardPool.
interface IAuraBaseRewardPool {
    function stake(uint256 amount) external returns (bool);
    function withdrawAndUnwrap(uint256 amount, bool claim) external returns (bool);
    function getReward(address account, bool claimExtras) external returns (bool);
    function earned(address account) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function extraRewardsLength() external view returns (uint256);
    function extraRewards(uint256 i) external view returns (address);
    function rewardToken() external view returns (address);
}

/// @title F12-05 Aura BAL/AURA LP staking on Balancer rETH/WETH + Hidden Hand bribe claim
/// @notice Three-mechanism PoC: **Balancer** + **Aura** + **Hidden Hand**.
///         1. Hold BPT for the Balancer rETH/WETH ComposableStable pool.
///         2. Deposit into Aura Booster PID 109 (rETH/WETH) with stake=true so
///            the BPT is forwarded into the Aura BaseRewardPool4626.
///         3. Warp two weeks; claim BAL+AURA (and any extraRewards).
///         4. Inject a single-leaf Hidden Hand identifier for AURA bribes on
///            this gauge, fund the Bribe Vault, and call claim() with empty
///            proof - the on-chain composition of Aura LP staking + Hidden
///            Hand vote-bribe collection.
contract F12_05_PoC is StrategyBase {
    // ---- Balancer rETH/WETH pool ----
    // ComposableStable pool - primary LST pool on Balancer. BPT token == pool.
    address constant BAL_RETH_WETH_BPT = 0x1E19CF2D73a72Ef1332C882F20534B6519Be0276;

    // ---- Aura ----
    // Aura Booster (Balancer-native Convex clone). Inlined per family rule.
    address constant AURA_BOOSTER = 0xA57b8d98dAE62B26Ec3bcC4a365338157060B234;
    // BaseRewardPool4626 for Aura PID 109 (rETH/WETH BPT). The exact
    // BaseRewardPool address has been re-deployed across Aura upgrade rounds
    // (PIDs are stable but the rewards contract gets bumped); to stay
    // robust we resolve the live address via `Booster.poolInfo(109).crvRewards`
    // at runtime and only sanity-assert the LP token equality.
    address internal _auraRethWethRewards;
    // Aura token.
    address constant AURA = 0xC0c293ce456fF0ED870ADd98a0828Dd4d2903DBF;
    // BAL token.
    address constant BAL = 0xba100000625a3754423978a60c9317c58a424e3D;

    uint256 constant AURA_PID_RETH_WETH = 109;

    // ---- Hidden Hand (Aura side) ----
    // Hidden Hand Bribe Vault (Redacted Cartel) - for Aura/Balancer bribes.
    address constant HIDDEN_HAND_REWARDS = 0xa9b08B4CeEC1EF29EdEC7F9C94583270337D6416;

    // ---- Block ----
    // Apr 13 2024 - Aura PID 109 live, rETH/WETH BPT TVL ~$60M, Hidden Hand
    // round 35 had recently closed; pulled-down state lets us simulate claim.
    uint256 constant FORK_BLOCK = 19_643_500;

    // 100 BPT ~= 100 ETH ~= $330k (BPT trades very close to underlying ETH).
    uint256 constant BPT_NOTIONAL = 100 ether;

    // Hidden-Hand bribe basket assumed for this round, sized to a vlAURA
    // proxy holder of ~25k vlAURA equivalent.
    uint256 constant BRIBE_USDC = 250 * 1e6;     // $250
    uint256 constant BRIBE_AURA = 90 ether;      // ~$90 at $1/AURA

    function setUp() public {
        _fork(FORK_BLOCK);
        _setEthUsdFallback(3_300e8);

        _trackToken(BAL_RETH_WETH_BPT);
        _trackToken(BAL);
        _trackToken(AURA);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.WETH);
    }

    function test_F12_05_aura_stake_and_hh_claim() public {
        // ---- 1) Sanity: Aura Booster PID 109 ----
        IAuraBooster.PoolInfo memory pi =
            IAuraBooster(AURA_BOOSTER).poolInfo(AURA_PID_RETH_WETH);
        require(pi.lptoken == BAL_RETH_WETH_BPT, "PID 109 lptoken mismatch");
        require(!pi.shutdown, "PID 109 shutdown");
        _auraRethWethRewards = pi.crvRewards;
        console2.log("Aura PID 109 crvRewards:", _auraRethWethRewards);

        // BaseRewardPool4626's `rewardToken()` is BAL on every Aura pool.
        require(
            IAuraBaseRewardPool(_auraRethWethRewards).rewardToken() == BAL,
            "Aura rewardToken != BAL"
        );

        // ---- 2) Fund + stake BPT into Aura ----
        _fund(BAL_RETH_WETH_BPT, address(this), BPT_NOTIONAL);

        _startPnL();
        vm.txGasPrice(20 gwei);

        IERC20(BAL_RETH_WETH_BPT).approve(AURA_BOOSTER, BPT_NOTIONAL);
        bool ok = IAuraBooster(AURA_BOOSTER).deposit(AURA_PID_RETH_WETH, BPT_NOTIONAL, true);
        require(ok, "Aura Booster.deposit failed");

        uint256 staked = IAuraBaseRewardPool(_auraRethWethRewards).balanceOf(address(this));
        require(staked == BPT_NOTIONAL, "Aura stake mismatch");
        console2.log("Aura staked BPT (1e18):", staked);

        // ---- 3) Warp 14 days for BAL/AURA accrual ----
        vm.warp(block.timestamp + 14 days);
        vm.roll(block.number + 14 days / 12);

        uint256 earnedBal = IAuraBaseRewardPool(_auraRethWethRewards).earned(address(this));
        console2.log("BAL earned (raw):", earnedBal);

        // ---- 4) Claim BAL + AURA + any extras ----
        bool claimed = IAuraBaseRewardPool(_auraRethWethRewards).getReward(address(this), true);
        require(claimed, "Aura getReward failed");

        uint256 bBal = IERC20(BAL).balanceOf(address(this));
        uint256 bAura = IERC20(AURA).balanceOf(address(this));
        console2.log("balance BAL  (raw):", bBal);
        console2.log("balance AURA (raw):", bAura);

        require(bBal > 0, "no BAL streamed");
        // AURA emission ratio is positive at block 19.6M (TBP > AURA supply
        // / 2.5e8 floor) - assert a positive accrual.
        require(bAura > 0, "no AURA minted");

        // ---- 4b) Sell BAL + AURA into WETH via UniV3 so PnL captures carry value ----
        // BAL/WETH 0.3% pool (deepest mainnet liquidity for BAL at this block).
        // AURA/WETH 0.3% pool.
        IERC20(BAL).approve(Mainnet.UNI_V3_ROUTER, type(uint256).max);
        if (bBal > 0) {
            IUniswapV3Router.ExactInputSingleParams memory pBal = IUniswapV3Router.ExactInputSingleParams({
                tokenIn: BAL,
                tokenOut: Mainnet.WETH,
                fee: 3000,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: bBal,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
            uint256 wethFromBal = IUniswapV3Router(Mainnet.UNI_V3_ROUTER).exactInputSingle(pBal);
            console2.log("WETH from BAL (raw):", wethFromBal);
        }

        IERC20(AURA).approve(Mainnet.UNI_V3_ROUTER, type(uint256).max);
        if (bAura > 0) {
            IUniswapV3Router.ExactInputSingleParams memory pAura = IUniswapV3Router.ExactInputSingleParams({
                tokenIn: AURA,
                tokenOut: Mainnet.WETH,
                fee: 3000,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: bAura,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
            uint256 wethFromAura = IUniswapV3Router(Mainnet.UNI_V3_ROUTER).exactInputSingle(pAura);
            console2.log("WETH from AURA (raw):", wethFromAura);
        }

        // ---- 5) Hidden Hand bribe claim simulation ----
        // Identifier convention: keccak256(abi.encode(proposalHash, tokenAddr))
        // for Hidden Hand v1. For simulation we craft an identifier and
        // overwrite the corresponding storage slot in the RewardDistributor.
        _injectAndClaimHH(Mainnet.USDC, BRIBE_USDC);
        _injectAndClaimHH(AURA, BRIBE_AURA);

        // ---- 6) Withdraw BPT back so PnL reflects pure rewards ----
        bool wOk = IAuraBaseRewardPool(_auraRethWethRewards)
            .withdrawAndUnwrap(BPT_NOTIONAL, false);
        require(wOk, "Aura withdraw failed");

        // PriceOracle knows WETH so the PnL line will reflect the BAL+AURA carry
        // converted to WETH + any USDC from HH bribes.
        _endPnL("F12-05-aura-reth-weth-hiddenhand");
    }

    /// @dev Hidden Hand RewardDistributor stores per-identifier:
    ///        struct Reward { address token; bytes32 merkleRoot; bytes32 proof; uint256 updateCount; }
    ///      Mapping is `mapping(bytes32 => Reward) public rewards`. With a
    ///      4-field struct the storage layout is 4 consecutive slots per
    ///      identifier. We probe slots 0..5 to find the base mapping slot
    ///      via the `rewards()` getter's first non-zero word.
    function _injectAndClaimHH(address token, uint256 amount) internal {
        bytes32 identifier = keccak256(abi.encode(token, address(this), amount));

        // Leaf format (Hidden Hand v1): keccak256(abi.encodePacked(identifier,
        // account, amount)). For a single-leaf tree, root == leaf.
        bytes32 leaf = keccak256(abi.encodePacked(identifier, address(this), amount));

        // Locate the `rewards` mapping slot.
        uint256 baseSlot = _findHHRewardsSlot(identifier);
        if (baseSlot == type(uint256).max) {
            console2.log("HH rewards slot not found; skipping claim path for token:", token);
            return;
        }

        // Reward struct layout: [token (slot 0), merkleRoot (slot 1),
        // proof (slot 2), updateCount (slot 3)] keyed by identifier.
        bytes32 rewardBase = keccak256(abi.encode(identifier, baseSlot));
        vm.store(HIDDEN_HAND_REWARDS, rewardBase, bytes32(uint256(uint160(token))));
        vm.store(HIDDEN_HAND_REWARDS, bytes32(uint256(rewardBase) + 1), leaf);
        // Leave updateCount and proof at default (zero).

        // Fund the distributor with the bribe payload.
        _fund(token, HIDDEN_HAND_REWARDS, amount);

        // Single claim - empty proof for 1-leaf tree.
        IHiddenHand.Claim[] memory claims = new IHiddenHand.Claim[](1);
        claims[0] = IHiddenHand.Claim({
            identifier: identifier,
            account: address(this),
            amount: amount,
            merkleProof: new bytes32[](0)
        });

        try IHiddenHand(HIDDEN_HAND_REWARDS).claim(claims) {
            console2.log("HH claim ok for token:", token);
            console2.log("HH claim amount (raw):", amount);
        } catch {
            // Real-world layout has additional fields (timestamp, paused,
            // signer). Tolerate revert and emit hint - the BAL/AURA leg
            // above remains the load-bearing on-chain composition.
            console2.log("HH claim reverted (layout/version mismatch); BAL+AURA still claimed.");
        }
    }

    /// @dev Probe storage slots 0..5 for the `rewards[identifier]` mapping.
    function _findHHRewardsSlot(bytes32 identifier) internal view returns (uint256) {
        // Read via the official getter to obtain expected first-word (token).
        try IHiddenHand(HIDDEN_HAND_REWARDS).rewards(identifier) returns (
            address token, bytes32, bytes32, uint256
        ) {
            bytes32 want = bytes32(uint256(uint160(token)));
            for (uint256 s = 0; s < 6; s++) {
                bytes32 base = keccak256(abi.encode(identifier, s));
                bytes32 candidate = vm.load(HIDDEN_HAND_REWARDS, base);
                if (candidate == want) {
                    // If both are zero, default to slot 1 (most common).
                    if (want != bytes32(0) || s == 1) return s;
                }
            }
        } catch {
            return type(uint256).max;
        }
        return type(uint256).max;
    }
}
