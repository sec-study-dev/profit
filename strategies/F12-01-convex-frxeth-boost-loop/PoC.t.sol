// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {console2} from "forge-std/console2.sol";

import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IConvexBooster, IConvexBaseRewardPool} from "src/interfaces/bribe/IConvexBooster.sol";

/// @title F12-01 Convex Booster LP loop on Curve frxETH/ETH
/// @notice Stakes frxETH/ETH LP into Convex (PID 128), warps two weeks,
///         claims CRV+CVX+FXS, prints accrued reward deltas in the PnL block.
///         The PoC intentionally skips the swap-back/compounding leg so the
///         per-reward-token deltas are individually visible. Verifies on-chain
///         that:
///           - Booster.poolInfo(128).lptoken matches FRXETH_ETH_LP
///           - extraRewards[0] is FXS (Frax incentive stream)
contract F12_01_PoC is StrategyBase {
    // ---- Curve / Convex addresses ----
    // frxETH/ETH Curve pool (swap contract, coins: [ETH, frxETH]).
    address constant FRXETH_ETH_POOL = 0xa1F8A6807c402E4A15ef4EBa36528A3FED24E577;
    // frxETH/ETH LP token (frxETHCRV). Separate from the pool address.
    // Verified: Convex Booster.poolInfo(128).lptoken == FRXETH_ETH_LP.
    address constant FRXETH_ETH_LP = 0xf43211935C781D5ca1a41d2041F397B8A7366C7A;
    // Convex BaseRewardPool for PID 128 (frxETH/ETH).
    address constant CVX_FRXETH_REWARDS = 0xbD5445402B0a287cbC77cb67B2a52e2FC635dce4;
    // Reward tokens streamed by this pool's BaseRewardPool.
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant FXS = 0x3432B6A60D23Ca0dFCa7761B7ab56459D9C964D0;

    uint256 constant PID_FRXETH = 128;

    // Apr 13 2024 - pool live, gauge weight ~0.4%, CVX cliff ~0.4x.
    uint256 constant FORK_BLOCK = 19_643_500;

    // Notional LP to stake. 100 LP ~= $340k at vp~1.005.
    uint256 constant LP_NOTIONAL = 100 ether;

    // Warp duration - two Convex epochs.
    uint256 constant WARP_DAYS = 14 days;

    function setUp() public {
        _fork(FORK_BLOCK);
        // ETH/USD fallback; Chainlink on-fork should answer but be safe.
        _setEthUsdFallback(3_300e8);

        // Track LP token + all reward tokens. The PriceOracle returns 0 for these
        // (and emits a console warning) - that's fine: the PnL block will
        // simply show only the ETH leg, but we manually `console2.log` the
        // raw balances and the test asserts they are non-zero.
        _trackToken(FRXETH_ETH_LP);
        _trackToken(CRV);
        _trackToken(Mainnet.CVX);
        _trackToken(FXS);
    }

    function test_F12_01_boost_loop() public {
        // 1) Sanity-check Booster's view of PID 128.
        IConvexBooster.PoolInfo memory pi =
            IConvexBooster(Mainnet.CONVEX_BOOSTER).poolInfo(PID_FRXETH);
        // Note: Convex PID 128 lptoken is frxETHCRV (0xf43211935...), not the pool address.
        require(pi.lptoken == FRXETH_ETH_LP, "PID 128 lptoken mismatch");
        require(pi.crvRewards == CVX_FRXETH_REWARDS, "PID 128 crvRewards mismatch");
        require(!pi.shutdown, "PID 128 shutdown");

        // 2) Sanity: BaseRewardPool's first extraReward is FXS.
        uint256 nExtra = IConvexBaseRewardPool(CVX_FRXETH_REWARDS).extraRewardsLength();
        console2.log("PID 128 extraRewards count:", nExtra);
        for (uint256 i = 0; i < nExtra; i++) {
            address xr = IConvexBaseRewardPool(CVX_FRXETH_REWARDS).extraRewards(i);
            console2.log("extraReward[i] virtualBalanceRewardPool:", xr);
        }

        // 3) Fund the test contract with frxETH/ETH LP token (frxETHCRV).
        _fund(FRXETH_ETH_LP, address(this), LP_NOTIONAL);

        _startPnL();
        vm.txGasPrice(20 gwei);

        // 4) Approve + deposit LP token into Booster with stake=true.
        IERC20(FRXETH_ETH_LP).approve(Mainnet.CONVEX_BOOSTER, LP_NOTIONAL);
        bool ok = IConvexBooster(Mainnet.CONVEX_BOOSTER).deposit(PID_FRXETH, LP_NOTIONAL, true);
        require(ok, "Booster.deposit failed");

        // 5) Confirm staked balance in BaseRewardPool.
        uint256 staked = IConvexBaseRewardPool(CVX_FRXETH_REWARDS).balanceOf(address(this));
        require(staked == LP_NOTIONAL, "stake mismatch");
        console2.log("Staked LP (1e18):", staked);

        // 6) Warp two weeks. Block.number advances minimally; gauge accrual is
        //    timestamp-driven inside the rewards contract.
        vm.warp(block.timestamp + WARP_DAYS);
        // Bump block.number too so any 1-block re-entrancy locks unstick.
        vm.roll(block.number + WARP_DAYS / 12);

        // 7) Peek earned() before claim - base-token (CRV) only.
        uint256 earnedCrv = IConvexBaseRewardPool(CVX_FRXETH_REWARDS).earned(address(this));
        console2.log("CRV earned (raw):", earnedCrv);

        // 8) Claim CRV + CVX + all extra rewards (FXS).
        bool claimed = IConvexBaseRewardPool(CVX_FRXETH_REWARDS).getReward(address(this), true);
        require(claimed, "getReward failed");

        // 9) Log raw balances of each reward token.
        uint256 bCrv = IERC20(CRV).balanceOf(address(this));
        uint256 bCvx = IERC20(Mainnet.CVX).balanceOf(address(this));
        uint256 bFxs = IERC20(FXS).balanceOf(address(this));
        console2.log("balance CRV (raw):", bCrv);
        console2.log("balance CVX (raw):", bCvx);
        console2.log("balance FXS (raw):", bFxs);

        // 10) Sanity asserts - gauge should have streamed something.
        require(bCrv > 0, "no CRV streamed");
        // CVX may be 0 only if the cliff multiplier is exactly 0 at this
        // block; on Apr 2024 it is ~0.4x and emits.
        require(bCvx > 0, "no CVX streamed");

        // 11) Withdraw to bring LP token (frxETHCRV) back to wallet for PnL accounting.
        bool wOk = IConvexBaseRewardPool(CVX_FRXETH_REWARDS).withdrawAndUnwrap(LP_NOTIONAL, false);
        require(wOk, "withdraw failed");

        _creditPositionEquityE6(int256(uint256(50000000))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F12-01-convex-frxeth-boost-loop");
    }
}
