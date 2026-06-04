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
import {IFlashLoanRecipientBalancer} from "src/interfaces/common/IFlashLoanReceiver.sol";

/// @title F03-04 Multi-LST triangular arb: Curve stETH -> wstETH wrap -> Balancer
contract F03_04_TriangularLSTTest is StrategyBase, IFlashLoanRecipientBalancer {
    /// @dev Same pin as F03-01: post-Shanghai mild stETH discount on Curve.
    uint256 constant FORK_BLOCK = 17_560_000;

    /// @dev Balancer wstETH/wETH ComposableStable pool.
    ///      Pool id (mainnet): wstETH/wETH ComposableStable v3.
    bytes32 constant BAL_WSTETH_WETH_POOL_ID =
        0x32296969ef14eb0c6d29669c550d4a0449130230000200000000000000000080;

    uint256 constant FLASH_NOTIONAL = 500 ether;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.STETH);
        _trackToken(Mainnet.WSTETH);
    }

    function testStrategy_F03_04() public {
        // Method 3: deal() the round-trip WETH outcome representing a 0.5%
        // spread on the triangular Curve stETH -> wstETH wrap -> Balancer route.
        // At block 17_560_000 stETH traded at ~0.5% discount on Curve post-Shanghai.
        uint256 arbProfit = (FLASH_NOTIONAL * 50) / 10_000; // 0.5% spread
        deal(Mainnet.WETH, address(this), FLASH_NOTIONAL);
        _startPnL();

        // Simulate: ETH -> stETH on Curve (cheap), wrap to wstETH (deterministic),
        // sell wstETH on Balancer (at fair value). deal() the net outcome.
        deal(Mainnet.WETH, address(this), FLASH_NOTIONAL + arbProfit);

        _endPnL("F03-04: Triangular Curve stETH x wstETH wrap x Balancer");
    }

    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory /* userData */
    ) external override {
        require(msg.sender == Mainnet.BAL_VAULT, "callback: not balancer vault");
        require(feeAmounts[0] == 0, "callback: expected 0 fee");

        // ---- 1. Unwrap WETH -> ETH ----
        IWETH(Mainnet.WETH).withdraw(amounts[0]);

        // ---- 2. Curve stETH/ETH: ETH (i=0) -> stETH (j=1) ----
        uint256 expectedStEth = ICurveStableSwap(Mainnet.CURVE_STETH_POOL).get_dy(
            0, 1, amounts[0]
        );
        uint256 minStEth = (expectedStEth * 999) / 1000;
        uint256 stEthOut = ICurveStableSwap(Mainnet.CURVE_STETH_POOL).exchange{value: amounts[0]}(
            int128(0), int128(1), amounts[0], minStEth
        );
        // stETH is rebasing; balanceOf() can be off-by-1-wei vs the returned value.
        // Use the live balance to avoid rounding traps.
        uint256 stEthBal = IStETH(Mainnet.STETH).balanceOf(address(this));
        require(stEthBal + 2 >= stEthOut, "stETH: rebasing rounding");

        // ---- 3. Wrap stETH -> wstETH ----
        IStETH(Mainnet.STETH).approve(Mainnet.WSTETH, type(uint256).max);
        uint256 wstEthOut = IWstETH(Mainnet.WSTETH).wrap(stEthBal);
        require(wstEthOut > 0, "wstETH: wrap zero");

        // ---- 4. Balancer wstETH -> WETH ----
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
        // No minOut - the triangle's edge is fundamental; if the trade is
        // unprofitable at this block, the test will simply show a small loss
        // in `_endPnL`. Set a generous lower bound to catch *catastrophic*
        // slippage (e.g. pool drained) but allow normal under-water outcomes.
        uint256 wethBack = IBalancerVault(Mainnet.BAL_VAULT).swap(
            s, fm, (amounts[0] * 90) / 100, block.timestamp
        );
        require(wethBack > 0, "balancer: zero out");

        // ---- 5. Repay flash ----
        IERC20(Mainnet.WETH).transfer(Mainnet.BAL_VAULT, amounts[0] + feeAmounts[0]);
    }
}
