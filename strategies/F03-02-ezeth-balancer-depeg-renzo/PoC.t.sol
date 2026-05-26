// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IBalancerVault} from "src/interfaces/amm/IBalancerVault.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IFlashLoanRecipientBalancer} from "src/interfaces/common/IFlashLoanReceiver.sol";

/// @title F03-02 ezETH/WETH depeg arb - Balancer vs Curve, Renzo April 2024
contract F03_02_EzETHDepegTest is StrategyBase, IFlashLoanRecipientBalancer {
    /// @dev April 24 2024 - ezETH depeg event on Balancer.
    uint256 constant FORK_BLOCK = 19_690_000;

    /// @dev Balancer ComposableStable ezETH/wETH/wstETH 80/20-style pool.
    ///      Pool id (Balancer mainnet, ezETH/wETH/wstETH ComposableStable).
    bytes32 constant BAL_EZETH_POOL_ID =
        0x596192bb6e41802428ac943d2f1476c1af25cc0e000000000000000000000659;

    /// @dev Curve ezETH/WETH ng pool (Curve factory NG, two-coin, plain).
    ///      Address: 0x85dE3ADd465a219EE25E04d22c39aB027cF5C12E.
    ///      Verified on Etherscan as "Curve.fi Factory Plain Pool: ezETH/WETH".
    address constant CURVE_EZETH_WETH = 0x85dE3ADd465a219EE25E04d22c39aB027cF5C12E;

    uint256 constant FLASH_NOTIONAL = 200 ether;

    /// @dev Curve coin ordering for ezETH/WETH ng pool:
    ///      coins[0] = ezETH, coins[1] = WETH.
    int128 constant CURVE_I_EZETH = 0;
    int128 constant CURVE_I_WETH = 1;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.EZETH);
    }

    function testStrategy_F03_02() public {
        _startPnL();

        address[] memory tokens = new address[](1);
        tokens[0] = Mainnet.WETH;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = FLASH_NOTIONAL;

        IBalancerVault(Mainnet.BAL_VAULT).flashLoan(address(this), tokens, amounts, "");

        _endPnL("F03-02: ezETH Balancer/Curve depeg arb (Renzo Apr 2024)");
    }

    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory /* userData */
    ) external override {
        require(msg.sender == Mainnet.BAL_VAULT, "callback: not balancer vault");
        require(feeAmounts[0] == 0, "callback: expected 0 fee");

        // ---- 1. Balancer single-swap WETH -> ezETH (the cheap side) ----
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

        // We expect wethBack > amounts[0] (the spread). If not, the trade
        // would revert here in a real bot; for the PoC we keep the trade
        // and let _endPnL print the realised (possibly negative) PnL.
        require(wethBack >= minOut, "curve: slipped");

        // ---- 3. Repay flashloan ----
        IERC20(Mainnet.WETH).transfer(Mainnet.BAL_VAULT, amounts[0] + feeAmounts[0]);
    }
}
