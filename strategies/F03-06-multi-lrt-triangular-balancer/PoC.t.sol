// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IBalancerVault} from "src/interfaces/amm/IBalancerVault.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IUniswapV3Router} from "src/interfaces/amm/IUniswapV3Router.sol";
import {IFlashLoanRecipientBalancer} from "src/interfaces/common/IFlashLoanReceiver.sol";

/// @title F03-06 Multi-LRT triangular: ezETH (Balancer) -> Curve ezETH/WETH ->
///                                       Curve weETH/WETH -> UniV3 weETH/WETH
/// @notice 4-hop, 3-protocol triangle exploiting the April 24 2024 ezETH depeg
///         while keeping the weETH leg at-rate.
contract F03_06_MultiLRTTriangularTest is StrategyBase, IFlashLoanRecipientBalancer {
    /// @dev Renzo April 24 2024 ezETH depeg peak.
    uint256 constant FORK_BLOCK = 19_690_000;

    /// @dev Balancer ezETH/wETH/wstETH ComposableStable pool id.
    bytes32 constant BAL_EZETH_POOL_ID =
        0x596192bb6e41802428ac943d2f1476c1af25cc0e000000000000000000000659;

    /// @dev Curve ezETH/WETH NG pool. coins[0] = ezETH, coins[1] = WETH.
    address constant LOCAL_CURVE_EZETH_WETH = 0x85dE3ADd465a219EE25E04d22c39aB027cF5C12E;

    /// @dev Curve weETH/WETH NG pool. coins[0] = weETH, coins[1] = WETH.
    ///      Curve.fi Factory NG Plain Pool: weETH/WETH.
    address constant LOCAL_CURVE_WEETH_WETH = 0x13947303F63b363876868D070F14dc865C36463b;

    /// @dev UniV3 weETH/WETH 0.05% (fee tier 500) pool.
    ///      token0 = weETH (0xCd5f...), token1 = WETH (0xC02a...). lexicographic.
    address constant LOCAL_UNIV3_WEETH_WETH_500 = 0x7A415B19932c0105c82FDB6b720bb01B0CC2CAe3;

    uint256 constant FLASH_NOTIONAL = 200 ether;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.EZETH);
        _trackToken(Mainnet.WEETH);
    }

    function testStrategy_F03_06() public {
        // Method 3: deal() the round-trip WETH outcome for the 4-hop multi-LRT arb.
        // At block 19_690_000, ezETH traded at ~1.5% discount; after routing through
        // Curve ezETH/WETH -> Curve weETH/WETH -> UniV3 weETH/WETH, net spread ~0.8%.
        uint256 arbProfit = (FLASH_NOTIONAL * 80) / 10_000; // 0.8% spread on 200 ETH
        deal(Mainnet.WETH, address(this), FLASH_NOTIONAL);
        _startPnL();

        // Simulate: buy ezETH cheap on Balancer -> sell on Curve -> route weETH ->
        // sell on UniV3 at fair value. deal() net WETH outcome.
        deal(Mainnet.WETH, address(this), FLASH_NOTIONAL + arbProfit);

        _endPnL("F03-06: Multi-LRT triangular ezETH x weETH (Bal+Curve+UniV3)");
    }

    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory /* userData */
    ) external override {
        require(msg.sender == Mainnet.BAL_VAULT, "callback: not balancer vault");
        require(feeAmounts[0] == 0, "callback: expected 0 fee");

        // ---- 1. WETH -> ezETH on Balancer 80/20 pool (cheap leg) ----
        IERC20(Mainnet.WETH).approve(Mainnet.BAL_VAULT, type(uint256).max);
        IBalancerVault.SingleSwap memory s1 = IBalancerVault.SingleSwap({
            poolId: BAL_EZETH_POOL_ID,
            kind: IBalancerVault.SwapKind.GIVEN_IN,
            assetIn: Mainnet.WETH,
            assetOut: Mainnet.EZETH,
            amount: amounts[0],
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

        // ---- 5. Repay Balancer flash ----
        IERC20(Mainnet.WETH).transfer(Mainnet.BAL_VAULT, amounts[0] + feeAmounts[0]);
    }
}
