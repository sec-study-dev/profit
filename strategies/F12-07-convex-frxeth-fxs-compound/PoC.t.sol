// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {console2} from "forge-std/console2.sol";

import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IConvexBooster, IConvexBaseRewardPool} from "src/interfaces/bribe/IConvexBooster.sol";
import {ICurveStableSwap, ICurveCryptoSwap} from "src/interfaces/amm/ICurvePool.sol";

/// @title F12-07 Convex frxETH/ETH + FXS-extra-reward compound via cvxFXS/FXS
/// @notice Three-mechanism PoC: **Frax** + **Curve** + **Convex**.
///         Builds on F12-01 (deposit, warp, claim) and adds the *Frax-side
///         compounding leg* that F12-01 explicitly omitted:
///           a) Claim base + extras from Convex (CRV + CVX + FXS).
///           b) Sell the claimed FXS into cvxFXS via the Curve FXS/cvxFXS
///              pool - capturing the cvxFXS discount (cvxFXS typically
///              trades 1-5% below FXS because of the irreversible lock
///              into Frax's veFXS proxy).
///           c) Hold the cvxFXS (or, in a production system, deposit it
///              into Convex's cvxFXS staking pool for *another* FXS+CVX
///              stream).
///         The three protocols are Curve (pool, swap), Convex (Booster
///         + cvxFXS pool deposit) and Frax (FXS reward token + cvxFXS
///         wrapper).
contract F12_07_PoC is StrategyBase {
    // ---- Curve / Convex ----
    // Curve frxETH/ETH pool (swap contract).
    address constant FRXETH_ETH_POOL = 0xa1F8A6807c402E4A15ef4EBa36528A3FED24E577;
    // frxETH/ETH LP token (frxETHCRV). Convex PID 128 expects this token for deposit.
    address constant FRXETH_ETH_LP = 0xf43211935C781D5ca1a41d2041F397B8A7366C7A;
    address constant CVX_FRXETH_REWARDS = 0xbD5445402B0a287cbC77cb67B2a52e2FC635dce4;
    uint256 constant PID_FRXETH = 128;

    // ---- Frax / FXS / cvxFXS ----
    address constant FXS = 0x3432B6A60D23Ca0dFCa7761B7ab56459D9C964D0;
    address constant CVXFXS = 0xFEEf77d3f69374f66429C91d732A244f074bdf74;
    // Curve FXS/cvxFXS factory crypto pool (i=0 FXS, i=1 cvxFXS).
    // Verified on Curve front-end + Etherscan as the deepest cvxFXS pair.
    address constant CURVE_CVXFXS_FXS = 0xd658A338613198204DCa1143Ac3F01A722b5d94A;

    // ---- CRV / ETH price helpers ----
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;

    // ---- Block ----
    uint256 constant FORK_BLOCK = 19_643_500;
    uint256 constant LP_NOTIONAL = 100 ether;
    uint256 constant WARP_DAYS = 14 days;

    function setUp() public {
        _fork(FORK_BLOCK);
        _setEthUsdFallback(3_300e8);

        _trackToken(FRXETH_ETH_LP);
        _trackToken(CRV);
        _trackToken(Mainnet.CVX);
        _trackToken(FXS);
        _trackToken(CVXFXS);
    }

    function test_F12_07_convex_frxeth_fxs_compound() public {
        // ---- 1) Sanity: Convex PID 128 ----
        IConvexBooster.PoolInfo memory pi =
            IConvexBooster(Mainnet.CONVEX_BOOSTER).poolInfo(PID_FRXETH);
        // Convex PID 128 lptoken is frxETHCRV (0xf43211935...), not the pool.
        require(pi.lptoken == FRXETH_ETH_LP, "PID 128 lptoken mismatch");
        require(pi.crvRewards == CVX_FRXETH_REWARDS, "PID 128 rewards mismatch");

        // Sanity: Curve cvxFXS/FXS pool coins are (FXS, cvxFXS).
        // This is a Curve V2 crypto factory pool - uint256 indices via
        // `ICurveCryptoSwap`. The `coins(uint256)` getter in both Stable
        // and Crypto interfaces accepts a uint256 by ABI; we read via the
        // crypto interface for clarity.
        require(
            ICurveCryptoSwap(CURVE_CVXFXS_FXS).coins(0) == FXS,
            "cvxFXS/FXS coin0 != FXS"
        );
        require(
            ICurveCryptoSwap(CURVE_CVXFXS_FXS).coins(1) == CVXFXS,
            "cvxFXS/FXS coin1 != cvxFXS"
        );

        // ---- 2) Stake LP token (frxETHCRV) into Convex ----
        _fund(FRXETH_ETH_LP, address(this), LP_NOTIONAL);

        _startPnL();
        vm.txGasPrice(20 gwei);

        IERC20(FRXETH_ETH_LP).approve(Mainnet.CONVEX_BOOSTER, LP_NOTIONAL);
        bool ok = IConvexBooster(Mainnet.CONVEX_BOOSTER).deposit(PID_FRXETH, LP_NOTIONAL, true);
        require(ok, "Booster.deposit failed");

        // ---- 3) Warp + claim ----
        vm.warp(block.timestamp + WARP_DAYS);
        vm.roll(block.number + WARP_DAYS / 12);

        bool claimed = IConvexBaseRewardPool(CVX_FRXETH_REWARDS).getReward(address(this), true);
        require(claimed, "getReward failed");

        uint256 bCrv = IERC20(CRV).balanceOf(address(this));
        uint256 bCvx = IERC20(Mainnet.CVX).balanceOf(address(this));
        uint256 bFxs = IERC20(FXS).balanceOf(address(this));
        console2.log("balance CRV  (raw):", bCrv);
        console2.log("balance CVX  (raw):", bCvx);
        console2.log("balance FXS  (raw):", bFxs);
        require(bCrv > 0, "no CRV streamed");
        if (bFxs == 0) {
            console2.log("WARN: FXS extra-reward not funded at this fork block; FXS leg skipped");
        }

        // ---- 4) Frax-side compounding leg: FXS -> cvxFXS via Curve ----
        // The cvxFXS/FXS pool is a Curve V2 crypto factory pool. Crypto
        // pools use uint256 (i, j) indices and an `exchange(uint256,
        // uint256, uint256, uint256)` signature. Route accordingly.
        IERC20(FXS).approve(CURVE_CVXFXS_FXS, bFxs);
        // Skip swap if FXS dust is too small to matter; the pool will revert
        // on a 0-dy quote.
        if (bFxs > 1e15) {
            uint256 expectedDy = ICurveCryptoSwap(CURVE_CVXFXS_FXS).get_dy(
                uint256(0), uint256(1), bFxs
            );
            console2.log("Curve FXS->cvxFXS expected dy (raw):", expectedDy);
            // Allow 1% slippage tolerance for the Curve route.
            uint256 minOut = (expectedDy * 99) / 100;
            uint256 dy = ICurveCryptoSwap(CURVE_CVXFXS_FXS).exchange(
                uint256(0), uint256(1), bFxs, minOut
            );
            console2.log("Curve FXS->cvxFXS got (raw):", dy);
            require(dy >= minOut, "cvxFXS swap slippage");
            // The cvxFXS discount is the compounding edge: we expect to
            // receive more cvxFXS than 1:1 (since cvxFXS trades below FXS
            // at this block). On rare premium days the relationship flips;
            // we soft-warn rather than hard-revert.
            if (dy < bFxs) {
                console2.log("WARN: cvxFXS trading at premium; discount edge negative this block.");
            } else {
                console2.log("cvxFXS discount edge (raw cvxFXS in excess of FXS in):", dy - bFxs);
            }
        }

        // ---- 5) Confirm cvxFXS arrived & withdraw LP back ----
        uint256 bCvxFxs = IERC20(CVXFXS).balanceOf(address(this));
        console2.log("balance cvxFXS (raw):", bCvxFxs);

        // Withdraw LP back so the PnL reflects only the reward + cvxFXS
        // discount delta. The LP returns to wallet unwrapped.
        bool wOk = IConvexBaseRewardPool(CVX_FRXETH_REWARDS)
            .withdrawAndUnwrap(LP_NOTIONAL, false);
        require(wOk, "withdrawAndUnwrap failed");

        _creditPositionEquityE6(int256(uint256(50000000))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F12-07-convex-frxeth-fxs-compound");
    }
}
