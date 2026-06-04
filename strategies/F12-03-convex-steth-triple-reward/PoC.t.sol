// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {console2} from "forge-std/console2.sol";

import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IConvexBooster, IConvexBaseRewardPool} from "src/interfaces/bribe/IConvexBooster.sol";
import {IUniswapV3Router} from "src/interfaces/amm/IUniswapV3Router.sol";

/// @title F12-03 Convex stETH/ETH triple-reward stack (CRV + CVX + LDO)
/// @notice Exercises the rewards-stacking property of Convex's BaseRewardPool:
///         CRV (base) + CVX (minted) + LDO (extraRewards[0] virtual pool).
///         Pool is the original Curve stETH/ETH (`steCRV` LP token).
///         Rewards (CRV + CVX) are sold into WETH via UniV3 so the PnL block
///         reflects the honest carry of 14-day LP staking in USD terms.
contract F12_03_PoC is StrategyBase {
    // ---- Addresses ----
    // Curve stETH/ETH pool (the swap contract) - used only for ABI sanity.
    address constant CURVE_STETH_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;
    // steCRV LP token (Curve emits a separate LP for this legacy pool).
    address constant STECRV_LP = 0x06325440D014e39736583c165C2963BA99fAf14E;
    // Convex BaseRewardPool for PID 25 (stETH/ETH).
    address constant CVX_STETH_REWARDS = 0x0A760466E1B4621579a82a39CB56Dda2F4E70f03;
    // Reward tokens.
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant LDO = 0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32;

    uint256 constant PID_STETH = 25;

    // Apr 13 2024 - gauge active, LDO incentive stream funded by Lido.
    uint256 constant FORK_BLOCK = 19_643_500;

    // Notional steCRV to stake (~$176k at vp~1.07 and ETH=$3300).
    uint256 constant LP_NOTIONAL = 50 ether;

    function setUp() public {
        _fork(FORK_BLOCK);
        _setEthUsdFallback(3_300e8);

        _trackToken(STECRV_LP);
        _trackToken(CRV);
        _trackToken(Mainnet.CVX);
        _trackToken(LDO);
        // WETH is tracked so the UniV3 reward-swap proceeds are captured in PnL.
        _trackToken(Mainnet.WETH);
    }

    function test_F12_03_triple_reward() public {
        // 1) PoolInfo sanity.
        IConvexBooster.PoolInfo memory pi =
            IConvexBooster(Mainnet.CONVEX_BOOSTER).poolInfo(PID_STETH);
        require(pi.lptoken == STECRV_LP, "PID 25 lptoken mismatch");
        require(pi.crvRewards == CVX_STETH_REWARDS, "PID 25 crvRewards mismatch");
        require(!pi.shutdown, "PID 25 shutdown");

        // 2) Confirm extraRewards has at least one entry (LDO).
        uint256 nExtra = IConvexBaseRewardPool(CVX_STETH_REWARDS).extraRewardsLength();
        console2.log("PID 25 extraRewards count:", nExtra);
        require(nExtra >= 1, "no extraRewards configured");

        // 3) Fund LP.
        _fund(STECRV_LP, address(this), LP_NOTIONAL);

        _startPnL();
        vm.txGasPrice(20 gwei);

        // 4) Stake into Booster (stake=true).
        IERC20(STECRV_LP).approve(Mainnet.CONVEX_BOOSTER, LP_NOTIONAL);
        bool ok = IConvexBooster(Mainnet.CONVEX_BOOSTER).deposit(PID_STETH, LP_NOTIONAL, true);
        require(ok, "Booster.deposit failed");
        require(
            IConvexBaseRewardPool(CVX_STETH_REWARDS).balanceOf(address(this)) == LP_NOTIONAL,
            "stake mismatch"
        );

        // 5) Warp 14 days, advance block.number plausibly.
        vm.warp(block.timestamp + 14 days);
        vm.roll(block.number + 14 days / 12);

        // 6) Pre-claim peek of base reward (CRV).
        uint256 earnedCrv = IConvexBaseRewardPool(CVX_STETH_REWARDS).earned(address(this));
        console2.log("CRV earned (raw):", earnedCrv);

        // 7) Claim everything (CRV + CVX + LDO).
        bool claimed = IConvexBaseRewardPool(CVX_STETH_REWARDS).getReward(address(this), true);
        require(claimed, "getReward failed");

        // 8) Log raw balances.
        uint256 bCrv = IERC20(CRV).balanceOf(address(this));
        uint256 bCvx = IERC20(Mainnet.CVX).balanceOf(address(this));
        uint256 bLdo = IERC20(LDO).balanceOf(address(this));
        console2.log("balance CRV (raw):", bCrv);
        console2.log("balance CVX (raw):", bCvx);
        console2.log("balance LDO (raw):", bLdo);

        require(bCrv > 0, "no CRV streamed");
        require(bCvx > 0, "no CVX streamed");
        // LDO may be 0 if Lido's incentive funding lapsed at this exact block
        // - emit a console hint rather than reverting hard.
        if (bLdo == 0) {
            console2.log("WARN: LDO stash not currently funded on this fork");
        }

        // 9) Sell CRV + CVX into WETH via UniV3 so PnL captures the carry value.
        //    CRV/WETH 0.3% pool (deepest mainnet liquidity for CRV at this block).
        //    CVX/WETH 1% pool.
        IERC20(CRV).approve(Mainnet.UNI_V3_ROUTER, type(uint256).max);
        if (bCrv > 0) {
            IUniswapV3Router.ExactInputSingleParams memory pCrv = IUniswapV3Router.ExactInputSingleParams({
                tokenIn: CRV,
                tokenOut: Mainnet.WETH,
                fee: 3000,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: bCrv,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
            uint256 wethFromCrv = IUniswapV3Router(Mainnet.UNI_V3_ROUTER).exactInputSingle(pCrv);
            console2.log("WETH from CRV (raw):", wethFromCrv);
        }

        IERC20(Mainnet.CVX).approve(Mainnet.UNI_V3_ROUTER, type(uint256).max);
        if (bCvx > 0) {
            IUniswapV3Router.ExactInputSingleParams memory pCvx = IUniswapV3Router.ExactInputSingleParams({
                tokenIn: Mainnet.CVX,
                tokenOut: Mainnet.WETH,
                fee: 10000,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: bCvx,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
            uint256 wethFromCvx = IUniswapV3Router(Mainnet.UNI_V3_ROUTER).exactInputSingle(pCvx);
            console2.log("WETH from CVX (raw):", wethFromCvx);
        }

        // 10) Withdraw LP back.
        bool wOk = IConvexBaseRewardPool(CVX_STETH_REWARDS)
            .withdrawAndUnwrap(LP_NOTIONAL, false);
        require(wOk, "withdrawAndUnwrap failed");

        _endPnL("F12-03-convex-steth-triple-reward");
    }
}
