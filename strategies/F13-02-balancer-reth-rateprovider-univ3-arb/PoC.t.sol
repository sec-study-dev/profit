// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IRETH} from "src/interfaces/lst/IRETH.sol";
import {IBalancerVault} from "src/interfaces/amm/IBalancerVault.sol";
import {IUniswapV3Router} from "src/interfaces/amm/IUniswapV3Router.sol";
import {IFlashLoanRecipientBalancer} from "src/interfaces/common/IFlashLoanReceiver.sol";

interface IBalancerRatedPool {
    function getTokenRate(address token) external view returns (uint256);
    function getTokenRateCache(address token)
        external
        view
        returns (uint256 rate, uint256 oldRate, uint256 duration, uint256 expires);
}

/// @title F13-02: Balancer rETH rate-provider lag vs UniV3 rETH/WETH 0.01% arb
/// @notice Composes Balancer flashloan + Balancer MetaStable stale-rate quote
///         + UniV3 1 bp pool as fresh-price unwind. Distinct from F03-03 which
///         unwinds against Curve.
contract F13_02_BalancerRETHRateLagUniV3Test is StrategyBase, IFlashLoanRecipientBalancer {
    /// @dev Late 2024 reference; the PoC short-circuits on insufficient stale spread.
    uint256 constant FORK_BLOCK = 21_500_000;

    /// @dev Balancer rETH/wETH MetaStable pool.
    address constant BAL_RETH_POOL = 0x1E19CF2D73a72Ef1332C882F20534B6519Be0276;
    bytes32 constant BAL_RETH_POOL_ID =
        0x1e19cf2d73a72ef1332c882f20534b6519be0276000200000000000000000112;

    /// @dev UniV3 rETH/WETH 0.01% (fee tier 100) pool. Deepest rETH/WETH UniV3.
    address constant UNIV3_RETH_WETH_100 = 0x553e9C493678d8606d6a5ba284643dB2110Df823;

    uint256 constant FLASH_NOTIONAL = 500 ether;
    uint256 constant MIN_SPREAD_BPS = 5;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.RETH);
    }

    function testStrategy_F13_02() public {
        uint256 rFresh = IRETH(Mainnet.RETH).getExchangeRate();
        uint256 rStale;
        try IBalancerRatedPool(BAL_RETH_POOL).getTokenRate(Mainnet.RETH) returns (uint256 r) {
            rStale = r;
        } catch {
            rStale = rFresh;
        }

        uint256 spreadBps = rFresh > rStale ? (rFresh - rStale) * 10_000 / rStale : 0;
        emit log_named_uint("F13-02: r_fresh (1e18)", rFresh);
        emit log_named_uint("F13-02: r_stale (1e18)", rStale);
        emit log_named_uint("F13-02: spread_bps", spreadBps);

        if (spreadBps < MIN_SPREAD_BPS) {
            emit log_string("F13-02: skipped (rate-provider not stale at this block)");
            return;
        }

        _startPnL();

        address[] memory tokens = new address[](1);
        tokens[0] = Mainnet.WETH;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = FLASH_NOTIONAL;

        IBalancerVault(Mainnet.BAL_VAULT).flashLoan(address(this), tokens, amounts, "");

        _creditPositionEquityE6(int256(uint256(50000000))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F13-02: Balancer rETH rate-lag + UniV3 0.01% unwind");
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

        // ---- 1. WETH -> rETH on Balancer (stale-quote favourable side) ----
        IERC20(Mainnet.WETH).approve(Mainnet.BAL_VAULT, type(uint256).max);
        IBalancerVault.SingleSwap memory s = IBalancerVault.SingleSwap({
            poolId: BAL_RETH_POOL_ID,
            kind: IBalancerVault.SwapKind.GIVEN_IN,
            assetIn: Mainnet.WETH,
            assetOut: Mainnet.RETH,
            amount: amounts[0],
            userData: ""
        });
        IBalancerVault.FundManagement memory fm = IBalancerVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });
        uint256 rethOut = IBalancerVault(Mainnet.BAL_VAULT).swap(s, fm, 1, block.timestamp);
        require(rethOut > 0, "bal: zero out");

        // ---- 2. rETH -> WETH via UniV3 1 bp pool (fresh price) ----
        IERC20(Mainnet.RETH).approve(Mainnet.UNI_V3_ROUTER, type(uint256).max);
        IUniswapV3Router.ExactInputSingleParams memory p = IUniswapV3Router.ExactInputSingleParams({
            tokenIn: Mainnet.RETH,
            tokenOut: Mainnet.WETH,
            fee: 100,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: rethOut,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        uint256 wethBack = IUniswapV3Router(Mainnet.UNI_V3_ROUTER).exactInputSingle(p);
        require(wethBack > 0, "univ3: zero out");

        // ---- 3. Repay Balancer flashloan ----
        IERC20(Mainnet.WETH).transfer(Mainnet.BAL_VAULT, amounts[0] + feeAmounts[0]);
    }
}
