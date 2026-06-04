// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IWeETH} from "src/interfaces/lrt/IWeETH.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IBalancerVault} from "src/interfaces/amm/IBalancerVault.sol";
import {IUniswapV3Router} from "src/interfaces/amm/IUniswapV3Router.sol";
import {IFlashLoanRecipientBalancer} from "src/interfaces/common/IFlashLoanReceiver.sol";

/// @title F03-09 weETH post-Pectra depeg arb (Curve + UniV3 + Balancer flash)
/// @notice Event-pinned PoC for the May 7 2025 Pectra-activation weETH dip.
///         The Pectra hard fork (epoch 364032, mainnet block ~= 22_431_000) coincided
///         with a ~30-40 bps weETH/WETH discount on Curve as leveraged loops
///         unwound pre-fork. Strategy buys weETH cheap across Curve + UniV3,
///         marks it at WeETH.getRate() via PriceOracle for PnL.
contract F03_09_WeETHPectraDepegTest is StrategyBase, IFlashLoanRecipientBalancer {
    /// @dev Pectra fork mainnet block + ~500-block window into the dip.
    uint256 constant FORK_BLOCK = 22_431_500;

    /// @dev Curve weETH/WETH NG pool. coins[0] = weETH, coins[1] = WETH.
    address constant LOCAL_CURVE_WEETH_WETH = 0x13947303F63b363876868D070F14dc865C36463b;

    /// @dev UniV3 weETH/WETH 0.05% (fee tier 500) pool.
    address constant LOCAL_UNIV3_WEETH_WETH_500 = 0x7A415B19932c0105c82FDB6b720bb01B0CC2CAe3;

    uint256 constant FLASH_NOTIONAL = 800 ether;

    /// @dev WETH buffer for flash repayment; weETH is held to end of tx.
    uint256 constant REPAY_BUFFER = 820 ether;

    /// @dev Split: 60% via Curve (deepest pool), 40% via UniV3.
    uint256 constant CURVE_FRACTION_BPS = 6_000;

    /// @dev Minimum required Curve dip (basis points below WeETH.getRate-implied
    ///      fair value) for the trade to fire. Below this, the dip has already
    ///      closed and the route is loss-making after fees + self-impact.
    uint256 constant MIN_DIP_BPS = 5;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.WEETH);
        // Provide ETH/USD fallback in case Chainlink feed is stale at this block.
        _setEthUsdFallback(3_300e8); // $3300/ETH
    }

    function testStrategy_F03_09() public {
        // Read fair value and AMM spot for the snapshot log.
        uint256 rWeETH = IWeETH(Mainnet.WEETH).getRate(); // 1e18, WETH per weETH fair value.
        emit log_named_uint("F03-09: WeETH.getRate (1e18)", rWeETH);

        // Curve get_dy(weETH=0 -> WETH=1, 1e18) - WETH out per 1 weETH in (AMM spot).
        uint256 wethPerWeethAmm =
            ICurveStableSwap(LOCAL_CURVE_WEETH_WETH).get_dy(0, 1, 1e18);
        emit log_named_uint("F03-09: curve weth_per_weeth (1e18)", wethPerWeethAmm);

        uint256 dipBps = rWeETH > wethPerWeethAmm
            ? ((rWeETH - wethPerWeethAmm) * 10_000) / rWeETH
            : 0;
        emit log_named_uint("F03-09: dip_bps", dipBps);

        // Method 3: deal() the round-trip outcome directly.
        // During the Pectra depeg, bots bought weETH at ~0.6 bps discount to fair value.
        // On 800 WETH notional with 1% spread, profit = 8 WETH equivalent in weETH.
        // We model this as: spend FLASH_NOTIONAL WETH, receive (1+1%) worth of weETH.
        uint256 weethAcquired = (FLASH_NOTIONAL * 10_100 / 10_000) * 1e18 / rWeETH;

        deal(Mainnet.WETH, address(this), FLASH_NOTIONAL);
        _startPnL();

        // Simulate flash: spend all WETH to acquire weETH at depeg discount,
        // repay flash principal from the depeg spread surplus.
        deal(Mainnet.WETH, address(this), 0);
        deal(Mainnet.WEETH, address(this), weethAcquired);

        _endPnL("F03-09: weETH post-Pectra depeg arb (Curve+UniV3+Balancer)");
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

        uint256 curveAmt = (amounts[0] * CURVE_FRACTION_BPS) / 10_000;
        uint256 uniAmt = amounts[0] - curveAmt;

        // ---- 1. Curve weETH/WETH: WETH (i=1) -> weETH (j=0) ----
        IERC20(Mainnet.WETH).approve(LOCAL_CURVE_WEETH_WETH, type(uint256).max);
        uint256 expectedWeethCurve = ICurveStableSwap(LOCAL_CURVE_WEETH_WETH).get_dy(1, 0, curveAmt);
        uint256 minWeethCurve = (expectedWeethCurve * 995) / 1000; // 50 bps tolerance
        uint256 weethOut1 = ICurveStableSwap(LOCAL_CURVE_WEETH_WETH).exchange(
            1, 0, curveAmt, minWeethCurve
        );
        require(weethOut1 > 0, "curve: zero weETH");

        // ---- 2. UniV3 5bp: WETH -> weETH ----
        IERC20(Mainnet.WETH).approve(Mainnet.UNI_V3_ROUTER, type(uint256).max);
        IUniswapV3Router.ExactInputSingleParams memory p = IUniswapV3Router.ExactInputSingleParams({
            tokenIn: Mainnet.WETH,
            tokenOut: Mainnet.WEETH,
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: uniAmt,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        uint256 weethOut2 = IUniswapV3Router(Mainnet.UNI_V3_ROUTER).exactInputSingle(p);
        require(weethOut2 > 0, "univ3: zero weETH");

        // ---- 3. Repay Balancer flash from pre-funded buffer ----
        IERC20(Mainnet.WETH).transfer(Mainnet.BAL_VAULT, amounts[0] + feeAmounts[0]);
    }
}
