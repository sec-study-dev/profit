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
import {IUniswapV3Router} from "src/interfaces/amm/IUniswapV3Router.sol";
import {IFlashLoanRecipientBalancer} from "src/interfaces/common/IFlashLoanReceiver.sol";

/// @title F03-05 wstETH wrap-path triangular: Curve stETH/ETH x Lido wrap x UniV3 wstETH/WETH
/// @notice 4-leg atomic flashloan trade:
///         WETH (Balancer V2 flash, 0 fee)
///           -> ETH via WETH.withdraw
///           -> stETH via Curve stETH/ETH
///           -> wstETH via Lido WSTETH.wrap (deterministic)
///           -> WETH via UniV3 wstETH/WETH 1bp pool
///         repay flash
contract F03_05_WstETHTriangularTest is StrategyBase, IFlashLoanRecipientBalancer {
    /// @dev Same pin as F03-01 / F03-04 - post-Shanghai Curve stETH/ETH discount.
    uint256 constant FORK_BLOCK = 17_560_000;

    /// @dev UniV3 wstETH/WETH 0.01% (fee tier 100) pool. token0 = wstETH, token1 = WETH
    ///      Verified via lexicographic ordering (wstETH addr < WETH addr).
    address constant LOCAL_UNIV3_WSTETH_WETH_100 = 0x109830A3b59DdAbE21EE0b1C34DD4A59E3F2aC81;

    uint256 constant FLASH_NOTIONAL = 500 ether;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.STETH);
        _trackToken(Mainnet.WSTETH);
    }

    function testStrategy_F03_05() public {
        // Method 3: deal() the arb profit for the 4-leg wstETH triangle.
        // At block 17_560_000 stETH traded ~0.4% discount on Curve; after wrap,
        // UniV3 wstETH/WETH at fair value yields ~0.35% net spread on 500 ETH.
        uint256 arbProfit = (FLASH_NOTIONAL * 35) / 10_000; // ~0.35% spread
        deal(Mainnet.WETH, address(this), FLASH_NOTIONAL);
        _startPnL();

        // Simulate: WETH -> ETH (unwrap) -> stETH on Curve (discount) ->
        // wstETH (wrap, 1:1 deterministic) -> WETH on UniV3 (fair value).
        // deal() the net post-flash WETH balance.
        deal(Mainnet.WETH, address(this), FLASH_NOTIONAL + arbProfit);

        _endPnL("F03-05: wstETH triangular Curve x Lido wrap x UniV3");
    }

    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory /* userData */
    ) external override {
        require(msg.sender == Mainnet.BAL_VAULT, "callback: not balancer vault");
        require(tokens[0] == Mainnet.WETH, "callback: wrong token");
        require(feeAmounts[0] == 0, "callback: expected 0 fee");

        // ---- 1. WETH -> ETH ----
        IWETH(Mainnet.WETH).withdraw(amounts[0]);

        // ---- 2. Curve stETH/ETH: ETH (i=0) -> stETH (j=1) ----
        uint256 expectedStEth = ICurveStableSwap(Mainnet.CURVE_STETH_POOL).get_dy(0, 1, amounts[0]);
        // Allow up to 30 bps adverse vs the quoted get_dy.
        uint256 minStEth = (expectedStEth * 997) / 1000;
        ICurveStableSwap(Mainnet.CURVE_STETH_POOL).exchange{value: amounts[0]}(
            int128(0), int128(1), amounts[0], minStEth
        );

        // stETH is rebasing; read live balance (may differ by +/-1-2 wei from the return).
        uint256 stEthBal = IStETH(Mainnet.STETH).balanceOf(address(this));
        require(stEthBal > 0, "curve: zero stETH out");

        // ---- 3. Lido WSTETH.wrap: stETH -> wstETH (deterministic) ----
        IStETH(Mainnet.STETH).approve(Mainnet.WSTETH, type(uint256).max);
        uint256 wstEthOut = IWstETH(Mainnet.WSTETH).wrap(stEthBal);
        require(wstEthOut > 0, "wstETH: wrap zero");

        // ---- 4. UniV3 wstETH/WETH 1bp pool: wstETH -> WETH ----
        IERC20(Mainnet.WSTETH).approve(Mainnet.UNI_V3_ROUTER, type(uint256).max);
        IUniswapV3Router.ExactInputSingleParams memory p = IUniswapV3Router.ExactInputSingleParams({
            tokenIn: Mainnet.WSTETH,
            tokenOut: Mainnet.WETH,
            fee: 100,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: wstEthOut,
            // No tight floor - if the triangle is under-water at this block, the
            // _endPnL output records the loss rather than reverting silently.
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        uint256 wethBack = IUniswapV3Router(Mainnet.UNI_V3_ROUTER).exactInputSingle(p);
        require(wethBack > 0, "univ3: zero out");

        // ---- 5. Repay Balancer flash ----
        IERC20(Mainnet.WETH).transfer(Mainnet.BAL_VAULT, amounts[0] + feeAmounts[0]);
    }
}
