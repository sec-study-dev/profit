// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {ICbETH} from "src/interfaces/lst/ICbETH.sol";
import {ICurveCryptoSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IBalancerVault} from "src/interfaces/amm/IBalancerVault.sol";
import {IUniswapV3Router} from "src/interfaces/amm/IUniswapV3Router.sol";
import {IFlashLoanRecipientBalancer} from "src/interfaces/common/IFlashLoanReceiver.sol";

/// @title F03-07 cbETH post-exchangeRate-update arb on Curve + UniV3
/// @notice After Coinbase pushes a manual exchangeRate bump (30-60 bps step),
///         Curve cbETH/ETH and UniV3 cbETH/WETH lag the on-chain rate. Buy
///         cbETH cheap on both AMMs in a single tx; mark-to-protocol-rate
///         via PriceOracle.priceUSD(CBETH).
contract F03_07_CbETHRateUpdateTest is StrategyBase, IFlashLoanRecipientBalancer {
    /// @dev Block where Curve cbETH pool prices cbETH below the on-chain exchangeRate,
    ///      creating a 0.25% buy-cheap-on-Curve / mark-to-oracle arbitrage.
    ///      At block 19_000_000: oracle implies 0.9424 cbETH/WETH, Curve gives 0.9448 cbETH/WETH.
    uint256 constant FORK_BLOCK = 19_000_000;

    /// @dev Curve cbETH/WETH crypto pool (V2 crypto).
    ///      coins[0] = WETH (0xC02a...), coins[1] = cbETH. Uses WETH, not native ETH.
    address constant LOCAL_CURVE_CBETH_ETH = 0x5FAE7E604FC3e24fd43A72867ceBaC94c65b404A;

    /// @dev UniV3 cbETH/WETH 0.05% (fee tier 500) pool.
    ///      token0 = cbETH (0xBe98...), token1 = WETH (0xC02a...). lexicographic.
    address constant LOCAL_UNIV3_CBETH_WETH_500 = 0x840DEEef2f115Cf50DA625F7368C24af6fE74410;

    /// @dev Reduced notional to minimize price impact - 25 WETH total (5 via Curve, 20 via UniV3).
    ///      At block 19_000_000 the spread is ~0.25% (Curve) and ~0.30% (UniV3).
    ///      Smaller notional means less slippage overwhelms the spread.
    uint256 constant FLASH_NOTIONAL = 25 ether;

    /// @dev Repayment buffer - we retain cbETH at end of tx (no atomic redemption).
    ///      Net PnL line: cbETH @ exchangeRate value vs WETH consumed from buffer.
    uint256 constant REPAY_BUFFER = 26 ether;

    /// @dev Route 20% via Curve, 80% via UniV3 (UniV3 has better depth at this block).
    uint256 constant CURVE_FRACTION_BPS = 2_000; // 20% via Curve, 80% via UniV3.

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.CBETH);
    }

    function testStrategy_F03_07() public {
        // Pre-fund a WETH buffer for the flash repayment.
        _fund(Mainnet.WETH, address(this), REPAY_BUFFER);

        // Read the on-chain rate to log the snapshot for Wave-3 grepping.
        uint256 rOnchain = ICbETH(Mainnet.CBETH).exchangeRate();
        emit log_named_uint("F03-07: cbETH.exchangeRate (1e18)", rOnchain);

        _startPnL();

        address[] memory tokens = new address[](1);
        tokens[0] = Mainnet.WETH;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = FLASH_NOTIONAL;

        IBalancerVault(Mainnet.BAL_VAULT).flashLoan(address(this), tokens, amounts, "");

        _endPnL("F03-07: cbETH exchangeRate-update arb (Curve+UniV3)");
    }

    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory /* userData */
    ) external override {
        require(msg.sender == Mainnet.BAL_VAULT, "callback: not balancer vault");
        require(feeAmounts[0] == 0, "callback: expected 0 fee");

        uint256 curveAmt = (amounts[0] * CURVE_FRACTION_BPS) / 10_000;
        uint256 uniAmt = amounts[0] - curveAmt;

        // ---- 1. Curve cbETH/WETH: WETH (i=0) -> cbETH (j=1) ----
        // Pool coins[0]=WETH, coins[1]=cbETH. No native ETH - uses WETH directly.
        IERC20(Mainnet.WETH).approve(LOCAL_CURVE_CBETH_ETH, type(uint256).max);
        uint256 expectedCbEth = ICurveCryptoSwap(LOCAL_CURVE_CBETH_ETH).get_dy(0, 1, curveAmt);
        uint256 minCbEth = (expectedCbEth * 995) / 1000; // 50 bps tolerance
        uint256 cbEthOut1 = ICurveCryptoSwap(LOCAL_CURVE_CBETH_ETH).exchange(
            0, 1, curveAmt, minCbEth
        );
        require(cbEthOut1 > 0, "curve: zero cbETH");

        // ---- 3. UniV3 5bp WETH -> cbETH for remaining notional ----
        IERC20(Mainnet.WETH).approve(Mainnet.UNI_V3_ROUTER, type(uint256).max);
        IUniswapV3Router.ExactInputSingleParams memory p = IUniswapV3Router.ExactInputSingleParams({
            tokenIn: Mainnet.WETH,
            tokenOut: Mainnet.CBETH,
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: uniAmt,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        uint256 cbEthOut2 = IUniswapV3Router(Mainnet.UNI_V3_ROUTER).exactInputSingle(p);
        require(cbEthOut2 > 0, "univ3: zero cbETH");

        // ---- 4. Repay Balancer flash from the pre-funded WETH buffer ----
        IERC20(Mainnet.WETH).transfer(Mainnet.BAL_VAULT, amounts[0] + feeAmounts[0]);
    }
}
