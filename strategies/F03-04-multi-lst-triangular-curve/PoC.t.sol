// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IStETH} from "src/interfaces/lst/IStETH.sol";
import {IWstETH} from "src/interfaces/lst/IWstETH.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IBalancerVault} from "src/interfaces/amm/IBalancerVault.sol";

/// @title F03-04 Multi-LST triangular arb: Curve stETH -> wstETH wrap -> Balancer
/// @notice 3-leg triangle arb exploiting the June 2022 stETH discount on Curve:
///         1. WETH -> ETH -> stETH on Curve (at ~2% discount)
///         2. stETH -> wstETH wrap (Lido)
///         3. wstETH -> WETH on Balancer MetaStable (stale rate cache)
///         Uses direct WETH funding (no flash) so Balancer swap works outside
///         the Balancer flash reentrancy guard.
contract F03_04_TriangularLSTTest is StrategyBase {
    /// @dev June 2022 stETH/ETH Curve depeg: ~2% discount.
    ///      Balancer wstETH/WETH MetaStable pool exists and has liquidity.
    uint256 constant FORK_BLOCK = 14_900_000;

    /// @dev Balancer wstETH/wETH MetaStable pool (old v1, mainnet).
    bytes32 constant BAL_WSTETH_WETH_POOL_ID =
        0x32296969ef14eb0c6d29669c550d4a0449130230000200000000000000000080;

    /// @dev Amount of WETH to deploy. Must be less than Balancer pool WETH balance (33,224 WETH).
    uint256 constant NOTIONAL = 500 ether;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.STETH);
        _trackToken(Mainnet.WSTETH);
    }

    function testStrategy_F03_04() public {
        // Fund the strategy with WETH (no flash loan to avoid Balancer reentrancy guard).
        _fund(Mainnet.WETH, address(this), NOTIONAL);

        _startPnL();

        // ---- 1. WETH -> ETH ----
        IWETH(Mainnet.WETH).withdraw(NOTIONAL);

        // ---- 2. Curve stETH/ETH: ETH (i=0) -> stETH (j=1) ----
        // At block 14_900_000, 1 ETH buys ~1.0210 stETH (2.1% discount).
        uint256 expectedStEth = ICurveStableSwap(Mainnet.CURVE_STETH_POOL).get_dy(
            0, 1, NOTIONAL
        );
        uint256 minStEth = (expectedStEth * 999) / 1000; // 10 bps tolerance
        ICurveStableSwap(Mainnet.CURVE_STETH_POOL).exchange{value: NOTIONAL}(
            int128(0), int128(1), NOTIONAL, minStEth
        );

        // stETH is rebasing; use live balance to avoid rounding traps.
        uint256 stEthBal = IStETH(Mainnet.STETH).balanceOf(address(this));
        require(stEthBal > 0, "curve: zero stETH");

        // ---- 3. Wrap stETH -> wstETH ----
        IStETH(Mainnet.STETH).approve(Mainnet.WSTETH, type(uint256).max);
        uint256 wstEthOut = IWstETH(Mainnet.WSTETH).wrap(stEthBal);
        require(wstEthOut > 0, "wstETH: wrap zero");

        // ---- 4. Balancer wstETH -> WETH (outside flash - no reentrancy issue) ----
        IERC20(Mainnet.WSTETH).approve(Mainnet.BAL_VAULT, type(uint256).max);
        IBalancerVault.SingleSwap memory s = IBalancerVault.SingleSwap({
            poolId: BAL_WSTETH_WETH_POOL_ID,
            kind: IBalancerVault.SwapKind.GIVEN_IN,
            assetIn: Mainnet.WSTETH,
            assetOut: Mainnet.WETH,
            amount: wstEthOut,
            userData: ""
        });
        IBalancerVault.FundManagement memory fm = IBalancerVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });
        uint256 wethBack = IBalancerVault(Mainnet.BAL_VAULT).swap(
            s, fm, (NOTIONAL * 90) / 100, block.timestamp
        );
        require(wethBack > 0, "balancer: zero out");

        _endPnL("F03-04: Triangular Curve stETH x wstETH wrap x Balancer");
    }
}
