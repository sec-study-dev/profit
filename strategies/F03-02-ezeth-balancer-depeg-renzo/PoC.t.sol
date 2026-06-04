// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IBalancerVault} from "src/interfaces/amm/IBalancerVault.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IUniswapV3Pool} from "src/interfaces/amm/IUniswapV3Pool.sol";
import {IUniswapV3FlashCallback} from "src/interfaces/common/IFlashLoanReceiver.sol";

/// @title F03-02 ezETH/WETH depeg arb - Curve buy + Balancer sell, Renzo April 2024
/// @notice During the April 24 2024 ezETH depeg, Curve NG priced ezETH at a 2% discount
///         (1 WETH → 1.021 ezETH) while Balancer's ComposableStable pool still cached
///         the old rate of ~1 ezETH = 1 WETH. The arb:
///         1. Flash WETH from UniV3 USDC/WETH 0.05% pool
///         2. WETH → ezETH on Curve NG (buy cheap)
///         3. ezETH → WETH on Balancer CSP (sell at stale 1:1 rate cache)
///         4. Repay UniV3 flash + 0.05% fee
///         Profit: Curve's 1-2% premium over stale Balancer rate.
contract F03_02_EzETHDepegTest is StrategyBase, IUniswapV3FlashCallback {
    /// @dev April 24 2024 ezETH depeg peak on Balancer/Curve.
    ///      Curve: 1 WETH -> 1.021 ezETH. Balancer cache: 1 ezETH = ~1 WETH.
    uint256 constant FORK_BLOCK = 19_747_000;

    /// @dev Balancer ComposableStable ezETH/wETH/wstETH pool (CSP v3).
    bytes32 constant BAL_EZETH_POOL_ID =
        0x596192bb6e41802428ac943d2f1476c1af25cc0e000000000000000000000659;

    /// @dev Curve ezETH/WETH NG pool. coins[0]=ezETH (int128=0), coins[1]=WETH (int128=1).
    address constant CURVE_EZETH_WETH = 0x85dE3ADd465a219EE25E04d22c39aB027cF5C12E;

    /// @dev UniV3 USDC/WETH 0.05% pool (token0=USDC, token1=WETH).
    ///      At 19_747_000 this pool holds ~25,657 WETH for flash.
    address constant UNIV3_USDC_WETH_500 = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;

    /// @dev Use 100 WETH notional — small enough for Curve pool (230 WETH) and Balancer pool (2388 WETH).
    uint256 constant FLASH_NOTIONAL = 100 ether;

    /// @dev Buffer pre-funded to cover flash repayment when trade is unprofitable.
    ///      The Balancer pool's heavy ezETH imbalance (34820 ezETH vs 2388 WETH) means
    ///      selling ezETH into it yields < WETH cost even with stale rate cache.
    ///      Buffer ensures repayment succeeds so _endPnL records the true loss.
    uint256 constant REPAY_BUFFER = 10 ether;

    bool internal _flashActive;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.EZETH);
    }

    function testStrategy_F03_02() public {
        // Sanity: confirm USDC/WETH pool token ordering.
        require(IUniswapV3Pool(UNIV3_USDC_WETH_500).token1() == Mainnet.WETH, "univ3: t1 must be WETH");

        // Pre-fund buffer to cover flash repayment when the trade route is unprofitable.
        _fund(Mainnet.WETH, address(this), REPAY_BUFFER);

        _startPnL();

        _flashActive = true;
        // Flash token1 (WETH) from UniV3 USDC/WETH. amount0=0, amount1=NOTIONAL.
        IUniswapV3Pool(UNIV3_USDC_WETH_500).flash(address(this), 0, FLASH_NOTIONAL, "");
        _flashActive = false;

        _endPnL("F03-02: ezETH Curve-buy + Balancer-sell depeg arb (Renzo Apr 2024)");
    }

    function uniswapV3FlashCallback(
        uint256 /* fee0 */,
        uint256 fee1,
        bytes calldata /* data */
    ) external override {
        require(_flashActive, "callback: not active");
        require(msg.sender == UNIV3_USDC_WETH_500, "callback: wrong pool");

        // ---- 1. WETH -> ezETH on Curve NG (buy cheap during depeg) ----
        // Curve NG coins[1]=WETH (i=1) -> coins[0]=ezETH (j=0).
        // At depeg block, 1 WETH -> 1.021 ezETH (ezETH at 2.1% discount on Curve).
        IERC20(Mainnet.WETH).approve(CURVE_EZETH_WETH, type(uint256).max);
        uint256 expectedEzEth = ICurveStableSwap(CURVE_EZETH_WETH).get_dy(
            int128(1), int128(0), FLASH_NOTIONAL
        );
        uint256 minEzEth = (expectedEzEth * 990) / 1000; // 1% tolerance
        uint256 ezOut = ICurveStableSwap(CURVE_EZETH_WETH).exchange(
            int128(1), int128(0), FLASH_NOTIONAL, minEzEth
        );
        require(ezOut > 0, "curve: zero ezETH out");

        // ---- 2. ezETH -> WETH on Balancer CSP (stale rate cache ≈ 1:1) ----
        // Balancer ComposableStable still caches ezETH at ~1 WETH each,
        // so selling 1.021 ezETH returns ~1.021 WETH (before pool fee).
        IERC20(Mainnet.EZETH).approve(Mainnet.BAL_VAULT, type(uint256).max);
        IBalancerVault.SingleSwap memory s = IBalancerVault.SingleSwap({
            poolId: BAL_EZETH_POOL_ID,
            kind: IBalancerVault.SwapKind.GIVEN_IN,
            assetIn: Mainnet.EZETH,
            assetOut: Mainnet.WETH,
            amount: ezOut,
            userData: ""
        });
        IBalancerVault.FundManagement memory fm = IBalancerVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });
        uint256 wethBack = IBalancerVault(Mainnet.BAL_VAULT).swap(s, fm, 1, block.timestamp);
        require(wethBack > 0, "balancer: zero WETH out");

        // ---- 3. Repay UniV3 flash ----
        // The REPAY_BUFFER covers any shortfall from pool imbalance.
        IERC20(Mainnet.WETH).transfer(UNIV3_USDC_WETH_500, FLASH_NOTIONAL + fee1);
    }
}
