// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IBalancerVault} from "src/interfaces/amm/IBalancerVault.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IUniswapV3Router} from "src/interfaces/amm/IUniswapV3Router.sol";
import {IUniswapV3Pool} from "src/interfaces/amm/IUniswapV3Pool.sol";
import {IUniswapV3FlashCallback} from "src/interfaces/common/IFlashLoanReceiver.sol";

/// @title F03-06 Multi-LRT triangular: ezETH (Balancer) -> Curve ezETH/WETH ->
///                                       Curve weETH/WETH -> UniV3 weETH/WETH
/// @notice Flash WETH from UniV3 wstETH/WETH 1bp pool (avoids Balancer vault reentrancy),
///         then execute the 4-hop triangle.
contract F03_06_MultiLRTTriangularTest is StrategyBase, IUniswapV3FlashCallback {
    /// @dev Renzo April 24 2024 ezETH depeg peak.
    uint256 constant FORK_BLOCK = 19_690_000;

    /// @dev Balancer ezETH/wETH/wstETH ComposableStable pool id.
    bytes32 constant BAL_EZETH_POOL_ID =
        0x596192bb6e41802428ac943d2f1476c1af25cc0e000000000000000000000659;

    /// @dev Curve ezETH/WETH NG pool. coins[0] = ezETH, coins[1] = WETH.
    address constant LOCAL_CURVE_EZETH_WETH = 0x85dE3ADd465a219EE25E04d22c39aB027cF5C12E;

    /// @dev Curve weETH/WETH NG pool. coins[0] = weETH, coins[1] = WETH.
    address constant LOCAL_CURVE_WEETH_WETH = 0x13947303F63b363876868D070F14dc865C36463b;

    /// @dev UniV3 wstETH/WETH 0.01% (fee tier 100) pool used as WETH flash source.
    ///      token0=wstETH, token1=WETH. Correct address verified via factory.getPool().
    address constant UNIV3_WSTETH_WETH_100 = 0x109830a1AAaD605BbF02a9dFA7B0B92EC2FB7dAa;

    uint256 constant FLASH_NOTIONAL = 200 ether;
    /// @dev WETH buffer to cover flash repayment shortfall (negative PnL is OK).
    uint256 constant REPAY_BUFFER = 15 ether;

    bool internal _flashActive;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.EZETH);
        _trackToken(Mainnet.WEETH);
    }

    function testStrategy_F03_06() public {
        // Pre-fund WETH buffer to cover any repayment shortfall (negative PnL is OK).
        _fund(Mainnet.WETH, address(this), REPAY_BUFFER);
        _startPnL();

        _flashActive = true;
        // Borrow token1 (WETH) from UniV3 1bp pool.
        IUniswapV3Pool(UNIV3_WSTETH_WETH_100).flash(address(this), 0, FLASH_NOTIONAL, "");
        _flashActive = false;

        _endPnL("F03-06: Multi-LRT triangular ezETH x weETH (Bal+Curve+UniV3)");
    }

    function uniswapV3FlashCallback(
        uint256 /* fee0 */,
        uint256 fee1,
        bytes calldata /* data */
    ) external override {
        require(_flashActive, "callback: not active");
        require(msg.sender == UNIV3_WSTETH_WETH_100, "callback: wrong pool");

        // ---- 1. WETH -> ezETH on Balancer CSP (cheap leg during depeg) ----
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
        require(ezOut > 0, "balancer: zero ezETH");

        // ---- 2. ezETH -> WETH on Curve ezETH/WETH NG pool ----
        IERC20(Mainnet.EZETH).approve(LOCAL_CURVE_EZETH_WETH, type(uint256).max);
        uint256 expWethA = ICurveStableSwap(LOCAL_CURVE_EZETH_WETH).get_dy(0, 1, ezOut);
        uint256 wethMid = ICurveStableSwap(LOCAL_CURVE_EZETH_WETH).exchange(
            0, 1, ezOut, (expWethA * 990) / 1000
        );
        require(wethMid > 0, "curve ezeth: zero");

        // ---- 3. WETH -> weETH on Curve weETH/WETH NG pool ----
        IERC20(Mainnet.WETH).approve(LOCAL_CURVE_WEETH_WETH, type(uint256).max);
        uint256 expWeETH = ICurveStableSwap(LOCAL_CURVE_WEETH_WETH).get_dy(1, 0, wethMid);
        uint256 weethOut = ICurveStableSwap(LOCAL_CURVE_WEETH_WETH).exchange(
            1, 0, wethMid, (expWeETH * 990) / 1000
        );
        require(weethOut > 0, "curve weeth: zero");

        // ---- 4. weETH -> WETH on UniV3 5bp pool ----
        IERC20(Mainnet.WEETH).approve(Mainnet.UNI_V3_ROUTER, type(uint256).max);
        IUniswapV3Router.ExactInputSingleParams memory p = IUniswapV3Router.ExactInputSingleParams({
            tokenIn: Mainnet.WEETH,
            tokenOut: Mainnet.WETH,
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: weethOut,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        uint256 wethBack = IUniswapV3Router(Mainnet.UNI_V3_ROUTER).exactInputSingle(p);
        require(wethBack > 0, "univ3: zero out");

        // ---- 5. Repay UniV3 flash ----
        IERC20(Mainnet.WETH).transfer(UNIV3_WSTETH_WETH_100, FLASH_NOTIONAL + fee1);
    }
}
