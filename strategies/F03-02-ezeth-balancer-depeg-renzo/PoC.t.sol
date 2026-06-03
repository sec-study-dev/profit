// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IBalancerVault} from "src/interfaces/amm/IBalancerVault.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IUniswapV3Pool} from "src/interfaces/amm/IUniswapV3Pool.sol";
import {IUniswapV3FlashCallback} from "src/interfaces/common/IFlashLoanReceiver.sol";

/// @title F03-02 ezETH/WETH depeg arb - Balancer vs Curve, Renzo April 2024
/// @notice Flash WETH from UniV3 wstETH/WETH 1bp pool (avoids Balancer vault reentrancy),
///         buy ezETH cheap on Balancer CSP, sell on Curve ezETH/WETH NG pool, repay flash.
contract F03_02_EzETHDepegTest is StrategyBase, IUniswapV3FlashCallback {
    /// @dev April 24 2024 - ezETH depeg event on Balancer.
    uint256 constant FORK_BLOCK = 19_690_000;

    /// @dev Balancer ComposableStable ezETH/wETH/wstETH pool.
    bytes32 constant BAL_EZETH_POOL_ID =
        0x596192bb6e41802428ac943d2f1476c1af25cc0e000000000000000000000659;

    /// @dev Curve ezETH/WETH ng pool. coins[0] = ezETH, coins[1] = WETH.
    address constant CURVE_EZETH_WETH = 0x85dE3ADd465a219EE25E04d22c39aB027cF5C12E;

    /// @dev UniV3 wstETH/WETH 0.01% (fee tier 100) pool used as WETH flash source.
    ///      token0 = wstETH, token1 = WETH. Borrow token1 only.
    ///      Correct address verified via factory.getPool(wstETH, WETH, 100).
    address constant UNIV3_WSTETH_WETH_100 = 0x109830a1AAaD605BbF02a9dFA7B0B92EC2FB7dAa;

    uint256 constant FLASH_NOTIONAL = 200 ether;
    /// @dev Small WETH buffer to cover any shortfall in the flash repayment
    ///      (trade may be slightly underwater at this exact block; negative PnL is OK).
    uint256 constant REPAY_BUFFER = 2 ether;

    /// @dev Curve coin ordering: coins[0] = ezETH, coins[1] = WETH.
    int128 constant CURVE_I_EZETH = 0;
    int128 constant CURVE_I_WETH = 1;

    bool internal _flashActive;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.EZETH);
    }

    function testStrategy_F03_02() public {
        // Pre-fund WETH buffer to cover any repayment shortfall (negative PnL is OK).
        _fund(Mainnet.WETH, address(this), REPAY_BUFFER);
        _startPnL();

        _flashActive = true;
        // Borrow token1 (WETH) from the 1bp UniV3 pool. amount0=0, amount1=N.
        IUniswapV3Pool(UNIV3_WSTETH_WETH_100).flash(address(this), 0, FLASH_NOTIONAL, "");
        _flashActive = false;

        _endPnL("F03-02: ezETH Balancer/Curve depeg arb (Renzo Apr 2024)");
    }

    function uniswapV3FlashCallback(
        uint256 /* fee0 */,
        uint256 fee1,
        bytes calldata /* data */
    ) external override {
        require(_flashActive, "callback: not active");
        require(msg.sender == UNIV3_WSTETH_WETH_100, "callback: wrong pool");

        // ---- 1. Balancer single-swap WETH -> ezETH (the cheap side during depeg) ----
        IERC20(Mainnet.WETH).approve(Mainnet.BAL_VAULT, type(uint256).max);

        IBalancerVault.SingleSwap memory s1 = IBalancerVault.SingleSwap({
            poolId: BAL_EZETH_POOL_ID,
            kind: IBalancerVault.SwapKind.GIVEN_IN,
            assetIn: Mainnet.WETH,
            assetOut: Mainnet.EZETH,
            amount: FLASH_NOTIONAL,
            userData: ""
        });
        IBalancerVault.FundManagement memory fm = IBalancerVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });
        uint256 ezOut = IBalancerVault(Mainnet.BAL_VAULT).swap(s1, fm, 1, block.timestamp);
        require(ezOut > 0, "balancer: zero out");

        // ---- 2. Sell ezETH on Curve -> WETH (the rich side) ----
        IERC20(Mainnet.EZETH).approve(CURVE_EZETH_WETH, type(uint256).max);
        uint256 expectedWeth = ICurveStableSwap(CURVE_EZETH_WETH).get_dy(
            CURVE_I_EZETH, CURVE_I_WETH, ezOut
        );
        uint256 minOut = (expectedWeth * 995) / 1000; // 50 bps tolerance
        uint256 wethBack = ICurveStableSwap(CURVE_EZETH_WETH).exchange(
            CURVE_I_EZETH, CURVE_I_WETH, ezOut, minOut
        );
        require(wethBack >= minOut, "curve: slipped");

        // ---- 3. Repay UniV3 flash (fee1 = fee on token1=WETH) ----
        IERC20(Mainnet.WETH).transfer(UNIV3_WSTETH_WETH_100, FLASH_NOTIONAL + fee1);
    }
}
