// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IBalancerVault} from "src/interfaces/amm/IBalancerVault.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IUniswapV3Pool} from "src/interfaces/amm/IUniswapV3Pool.sol";
import {IUniswapV3Router} from "src/interfaces/amm/IUniswapV3Router.sol";
import {IUniswapV3FlashCallback} from "src/interfaces/common/IFlashLoanReceiver.sol";

/// @title F03-06 Multi-LRT triangular: ezETH (Balancer) -> Curve ezETH/WETH ->
///                                       Curve weETH/WETH -> UniV3 weETH/WETH
/// @notice 4-hop, 3-protocol triangle exploiting the April 24 2024 ezETH depeg
///         while keeping the weETH leg at-rate.
///         Uses UniV3 USDC/WETH flash (token1=WETH) to avoid Balancer reentrancy
///         guard (BAL#400). Balancer swap is called outside any Balancer flash
///         callback, which is legal under Balancer V2.
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

    /// @dev UniV3 weETH/WETH 0.05% (fee tier 500) pool.
    address constant LOCAL_UNIV3_WEETH_WETH_500 = 0x7A415B19932c0105c82FDB6b720bb01B0CC2CAe3;

    /// @dev UniV3 USDC/WETH 0.05% pool (token0=USDC, token1=WETH). Used as flash source.
    ///      At block 19_690_000 this pool holds ~25,000+ WETH for flash.
    address constant UNIV3_USDC_WETH_500 = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;

    uint256 constant FLASH_NOTIONAL = 200 ether;

    /// @dev Buffer pre-funded to cover flash repayment if the 4-hop path loses.
    ///      Net_usd will record the actual PnL; the buffer ensures no revert.
    uint256 constant REPAY_BUFFER = 20 ether;

    bool internal _flashActive;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.EZETH);
        _trackToken(Mainnet.WEETH);
    }

    function testStrategy_F03_06() public {
        // Sanity: confirm USDC/WETH pool token ordering.
        require(IUniswapV3Pool(UNIV3_USDC_WETH_500).token1() == Mainnet.WETH, "univ3: t1 must be WETH");

        // Pre-fund WETH buffer to ensure flash repayment if the 4-hop path loses.
        _fund(Mainnet.WETH, address(this), REPAY_BUFFER);

        _startPnL();

        _flashActive = true;
        // Flash token1 (WETH) from UniV3 USDC/WETH pool. amount0=0, amount1=NOTIONAL.
        IUniswapV3Pool(UNIV3_USDC_WETH_500).flash(address(this), 0, FLASH_NOTIONAL, "");
        _flashActive = false;

        _endPnL("F03-06: Multi-LRT triangular ezETH x weETH (Bal+Curve+UniV3)");
    }

    function uniswapV3FlashCallback(
        uint256 /* fee0 */,
        uint256 fee1,
        bytes calldata /* data */
    ) external override {
        require(_flashActive, "callback: not active");
        require(msg.sender == UNIV3_USDC_WETH_500, "callback: wrong pool");

        // ---- 1. WETH -> ezETH on Balancer CSP (buy during depeg at discount) ----
        // Outside any Balancer flash callback -> no BAL#400 reentrancy guard.
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
        // NG pool: coins[0]=ezETH, coins[1]=WETH. Swap i=0 (ezETH) -> j=1 (WETH).
        IERC20(Mainnet.EZETH).approve(LOCAL_CURVE_EZETH_WETH, type(uint256).max);
        uint256 wethMid = ICurveStableSwap(LOCAL_CURVE_EZETH_WETH).exchange(
            0, 1, ezOut, 1
        );
        require(wethMid > 0, "curve ezeth: zero");

        // ---- 3. WETH -> weETH on Curve weETH/WETH NG pool ----
        // NG pool: coins[0]=weETH, coins[1]=WETH. Swap i=1 (WETH) -> j=0 (weETH).
        IERC20(Mainnet.WETH).approve(LOCAL_CURVE_WEETH_WETH, type(uint256).max);
        uint256 weethOut = ICurveStableSwap(LOCAL_CURVE_WEETH_WETH).exchange(
            1, 0, wethMid, 1
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

        // ---- 5. Repay UniV3 flash (token1 = WETH) ----
        // The REPAY_BUFFER covers any shortfall from an unprofitable trade path.
        IERC20(Mainnet.WETH).transfer(UNIV3_USDC_WETH_500, FLASH_NOTIONAL + fee1);
    }
}
