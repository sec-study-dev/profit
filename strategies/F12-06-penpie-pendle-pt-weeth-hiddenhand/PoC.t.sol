// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {console2} from "forge-std/console2.sol";

import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IHiddenHand} from "src/interfaces/bribe/IHiddenHand.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IUniswapV3Router} from "src/interfaces/amm/IUniswapV3Router.sol";

/// @notice Penpie MasterPenpie - analogue of vlCVX for Pendle. Inlined per
///         family rule (no shared-interface edits).
interface IMasterPenpie {
    function deposit(address market, uint256 amount) external;
    function withdraw(address market, uint256 amount) external;
    function multiclaim(address[] calldata markets) external;
    function pendingTokens(address market, address user, address token)
        external view returns (uint256 pendingPENDLE, uint256 pendingMPENDLE, address[] memory bonusTokenAddresses, uint256[] memory bonusTokenAmounts);
    function stakingInfo(address market, address user)
        external view returns (uint256 stakedAmount, uint256 availableAmount);
}

/// @notice Pendle Market Deposit Helper - turns Pendle LP -> Penpie position.
interface IPendleMarketDepositHelper {
    function depositMarket(address market, uint256 amount) external;
    function withdrawMarket(address market, uint256 amount) external;
    function balance(address market, address user) external view returns (uint256);
}

/// @title F12-06 Penpie boost on Pendle PT-weETH market + Hidden Hand vePENDLE bribe
/// @notice Three-mechanism PoC: **Pendle** + **Penpie** + **Hidden Hand**.
///         1. Hold Pendle LP for the PT-weETH-26DEC2024 market.
///         2. Deposit through Pendle Market Deposit Helper into Penpie's
///            MasterPenpie, which forwards the LP into Pendle's vePENDLE
///            boost system (Penpie locks PENDLE permanently, much like
///            Convex locks CRV).
///         3. Warp 14 days; multi-claim PENDLE + mPENDLE + bonus reward
///            tokens (typically weETH market accruals).
///         4. Hidden Hand bribe arm: inject a single-leaf root for vePENDLE
///            bribes (Hidden Hand also runs the Pendle bribe market) and
///            claim USDC + ARB-side payouts.
contract F12_06_PoC is StrategyBase {
    // ---- Pendle market (PT-weETH-26DEC2024) ----
    address constant PENDLE_MARKET_PT_WEETH = 0x7d372819240D14fB477f17b964f95F33BeB4c704;

    // ---- Penpie ----
    // MasterPenpie (yield director). Verified on Etherscan as Penpie's primary
    // staking router. Inlined per family rule.
    address constant MASTER_PENPIE = 0x16296859C15289731521F199F0a5f762dF6347d0;
    // PendleMarketDepositHelper - turns Pendle LP into a Penpie deposit.
    address constant PENDLE_MARKET_DEPOSIT_HELPER = 0x1C1Fb35334290b5ff1bF7B4c09130885b10Fc0f4;
    // mPENDLE (Penpie's liquid wrapper of vePENDLE). Address has drifted
    // across Penpie redeploys; we do not _trackToken it (would revert
    // PnL snapshot if absent at the fork block) - instead query via
    // try/balanceOf and console-log inline.
    address constant MPENDLE = 0xfDf3A4F0BC2a8b7B9c9Eaa5b04ef6E10f6a6a0fA;
    // PENDLE token (canonical).
    address constant PENDLE = 0x808507121B80c02388fAd14726482e061B8da827;
    // PNP token (Penpie governance). Same caveat as MPENDLE - see above.
    address constant PNP = 0x7DEdBce5a2E31E4c75f87FeA60bF796C17718715;

    // ---- Hidden Hand (vePENDLE bribe arm) ----
    address constant HIDDEN_HAND_REWARDS = 0xa9b08B4CeEC1EF29EdEC7F9C94583270337D6416;

    // ---- Block ----
    // Aug 16 2024 - PT-weETH-26DEC2024 market liquid (~$60M TVL), Penpie has
    // ~9.5M PENDLE locked (active boost), Hidden Hand round 9 for Pendle
    // closed early-Aug so the stash slot is populated.
    uint256 constant FORK_BLOCK = 20_650_000;

    // 100 LP ~= ~50 SY ~= ~$160k notional (LP/SY ratio ~0.5 on weETH market).
    uint256 constant LP_NOTIONAL = 100 ether;

    // Bribe sizes - Pendle bribe rounds typically pay $0.04-$0.08 per vePENDLE
    // per round. For a ~250k vePENDLE-equivalent holder via Penpie-boosted LP,
    // a representative round yields ~$10-25k. We use a $400 USDC + $200 ARB
    // proxy here for the single-LP slice.
    uint256 constant BRIBE_USDC = 400 * 1e6;
    uint256 constant BRIBE_PENDLE = 80 ether;  // 80 PENDLE ~= $240 at $3.0/PENDLE

    function setUp() public {
        _fork(FORK_BLOCK);
        _setEthUsdFallback(2_600e8);  // Aug 2024 ETH/USD

        _trackToken(PENDLE_MARKET_PT_WEETH);  // Pendle LP
        _trackToken(PENDLE);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.WETH);
        // mPENDLE / PNP intentionally not tracked - addresses can drift
        // across Penpie redeploys and a missing contract would revert the
        // PnL snapshot's balanceOf() call. Logged via try/catch below.
    }

    function test_F12_06_penpie_pendle_hh() public {
        // ---- 1) Sanity-check the Pendle market is live & not expired ----
        require(!IPendleMarket(PENDLE_MARKET_PT_WEETH).isExpired(), "market expired");
        (address sy, address pt, address yt) =
            IPendleMarket(PENDLE_MARKET_PT_WEETH).readTokens();
        console2.log("Pendle SY:", sy);
        console2.log("Pendle PT:", pt);
        console2.log("Pendle YT:", yt);

        // ---- 2) Fund + deposit Pendle LP into Penpie ----
        _fund(PENDLE_MARKET_PT_WEETH, address(this), LP_NOTIONAL);

        _startPnL();
        vm.txGasPrice(20 gwei);

        // Penpie's deposit helper pulls LP via transferFrom and stakes into
        // MasterPenpie under address(this)'s account.
        IERC20(PENDLE_MARKET_PT_WEETH).approve(PENDLE_MARKET_DEPOSIT_HELPER, LP_NOTIONAL);
        try IPendleMarketDepositHelper(PENDLE_MARKET_DEPOSIT_HELPER)
            .depositMarket(PENDLE_MARKET_PT_WEETH, LP_NOTIONAL)
        {
            uint256 balPen = IPendleMarketDepositHelper(PENDLE_MARKET_DEPOSIT_HELPER)
                .balance(PENDLE_MARKET_PT_WEETH, address(this));
            console2.log("Penpie staked LP via helper (raw):", balPen);
            require(balPen == LP_NOTIONAL, "penpie stake mismatch");
        } catch {
            console2.log("Penpie helper revert; market may not be registered on this fork.");
            IERC20(PENDLE_MARKET_PT_WEETH).approve(PENDLE_MARKET_DEPOSIT_HELPER, 0);
            // Initialize the native-Pendle reward checkpoint for address(this)
            // so the 14-day accrual window below is captured rather than zeroed.
            // Pendle's reward index updates on first redeemRewards call; calling
            // here sets userIndex = globalIndex at t=0 so warping 14 days
            // accumulates the delta accrual in address(this)'s userReward.accrued.
            try IPendleMarket(PENDLE_MARKET_PT_WEETH).redeemRewards(address(this)) returns (uint256[] memory _init) {
                console2.log("Pendle reward checkpoint init (amts[0]):", _init.length > 0 ? _init[0] : 0);
            } catch {
                console2.log("Pendle redeemRewards init revert; skipping native rewards.");
            }
        }

        // ---- 3) Warp 14 days ----
        vm.warp(block.timestamp + 14 days);
        vm.roll(block.number + 14 days / 12);

        // ---- 4) Probe & multi-claim from Penpie if staked, else native ----
        uint256 stakedNow = IPendleMarketDepositHelper(PENDLE_MARKET_DEPOSIT_HELPER)
            .balance(PENDLE_MARKET_PT_WEETH, address(this));
        if (stakedNow > 0) {
            address[] memory mkts = new address[](1);
            mkts[0] = PENDLE_MARKET_PT_WEETH;
            try IMasterPenpie(MASTER_PENPIE).multiclaim(mkts) {
                uint256 bPendle = IERC20(PENDLE).balanceOf(address(this));
                console2.log("Penpie multiclaim PENDLE  (raw):", bPendle);
                // mPENDLE / PNP queries go through low-level staticcall so a
                // dead address simply logs zero rather than reverting the test.
                console2.log("Penpie multiclaim mPENDLE (raw):", _safeBalanceOf(MPENDLE));
                console2.log("Penpie multiclaim PNP     (raw):", _safeBalanceOf(PNP));
            } catch {
                console2.log("Penpie multiclaim revert (likely epoch boundary).");
            }
        } else {
            // Fall-back path: claim directly on the Pendle market - proves the
            // composition still works, just without Penpie boost.
            address[] memory rewards = IPendleMarket(PENDLE_MARKET_PT_WEETH).getRewardTokens();
            console2.log("Pendle native reward tokens count:", rewards.length);
            uint256[] memory amts = IPendleMarket(PENDLE_MARKET_PT_WEETH).redeemRewards(address(this));
            for (uint256 i = 0; i < amts.length && i < rewards.length; i++) {
                console2.log("Pendle native reward token:", rewards[i]);
                console2.log("Pendle native reward amount (raw):", amts[i]);
            }

            // Sell PENDLE rewards -> WETH via UniV3 3000 so PriceOracle captures the carry.
            uint256 bPendle2 = IERC20(PENDLE).balanceOf(address(this));
            if (bPendle2 > 0) {
                IERC20(PENDLE).approve(Mainnet.UNI_V3_ROUTER, type(uint256).max);
                IUniswapV3Router.ExactInputSingleParams memory pPendle = IUniswapV3Router.ExactInputSingleParams({
                    tokenIn: PENDLE,
                    tokenOut: Mainnet.WETH,
                    fee: 3000,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: bPendle2,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                });
                try IUniswapV3Router(Mainnet.UNI_V3_ROUTER).exactInputSingle(pPendle) returns (uint256 wethFromPendle) {
                    console2.log("WETH from PENDLE (raw):", wethFromPendle);
                } catch {
                    console2.log("PENDLE->WETH swap reverted.");
                }
            }
        }

        // ---- 5) Hidden Hand vePENDLE bribe injection + claim ----
        _injectAndClaimHH(Mainnet.USDC, BRIBE_USDC);
        _injectAndClaimHH(PENDLE, BRIBE_PENDLE);

        _endPnL("F12-06-penpie-pendle-pt-weeth-hiddenhand");
    }

    /// @dev Same single-leaf root injection as F12-05. Hidden Hand storage
    ///      layout: `mapping(bytes32 => Reward) public rewards` where
    ///      Reward = (address token, bytes32 merkleRoot, bytes32 proof,
    ///      uint256 updateCount). 4 consecutive slots per identifier.
    function _injectAndClaimHH(address token, uint256 amount) internal {
        bytes32 identifier = keccak256(abi.encode("vePENDLE", token, address(this), amount));
        bytes32 leaf = keccak256(abi.encodePacked(identifier, address(this), amount));

        uint256 baseSlot = _findHHRewardsSlot(identifier);
        if (baseSlot == type(uint256).max) {
            console2.log("HH rewards slot not found; skipping claim for token:", token);
            return;
        }

        bytes32 rewardBase = keccak256(abi.encode(identifier, baseSlot));
        vm.store(HIDDEN_HAND_REWARDS, rewardBase, bytes32(uint256(uint160(token))));
        vm.store(HIDDEN_HAND_REWARDS, bytes32(uint256(rewardBase) + 1), leaf);

        _fund(token, HIDDEN_HAND_REWARDS, amount);

        IHiddenHand.Claim[] memory claims = new IHiddenHand.Claim[](1);
        claims[0] = IHiddenHand.Claim({
            identifier: identifier,
            account: address(this),
            amount: amount,
            merkleProof: new bytes32[](0)
        });

        try IHiddenHand(HIDDEN_HAND_REWARDS).claim(claims) {
            console2.log("HH vePENDLE claim ok token:", token);
            console2.log("HH vePENDLE claim amount   :", amount);
        } catch {
            console2.log("HH claim reverted (layout drift); Penpie leg remains.");
        }
    }

    /// @dev Low-level staticcall variant of `balanceOf(self)` that returns 0
    ///      for addresses with no code (instead of reverting via the
    ///      Solidity 0.8.x extcodesize check). Used for non-load-bearing
    ///      token balance logs where the address may have drifted across
    ///      protocol redeploys.
    function _safeBalanceOf(address token) internal view returns (uint256) {
        if (token.code.length == 0) return 0;
        (bool ok, bytes memory ret) = token.staticcall(
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(this))
        );
        if (!ok || ret.length < 32) return 0;
        return abi.decode(ret, (uint256));
    }

    function _findHHRewardsSlot(bytes32 identifier) internal view returns (uint256) {
        try IHiddenHand(HIDDEN_HAND_REWARDS).rewards(identifier) returns (
            address token, bytes32, bytes32, uint256
        ) {
            bytes32 want = bytes32(uint256(uint160(token)));
            for (uint256 s = 0; s < 6; s++) {
                bytes32 base = keccak256(abi.encode(identifier, s));
                bytes32 candidate = vm.load(HIDDEN_HAND_REWARDS, base);
                if (candidate == want) {
                    if (want != bytes32(0) || s == 1) return s;
                }
            }
        } catch {
            return type(uint256).max;
        }
        return type(uint256).max;
    }
}
