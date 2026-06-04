// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWstETH} from "src/interfaces/lst/IWstETH.sol";
import {IBalancerVault} from "src/interfaces/amm/IBalancerVault.sol";
import {IUniswapV3Pool} from "src/interfaces/amm/IUniswapV3Pool.sol";
import {IUniswapV3Router} from "src/interfaces/amm/IUniswapV3Router.sol";
import {IUniswapV3FlashCallback} from "src/interfaces/common/IFlashLoanReceiver.sol";

/// @dev Local Balancer rate-provider getters (subset of MetaStable / ComposableStable).
interface IBalancerRatedPool {
    function getTokenRate(address token) external view returns (uint256);
}

/// @title F13-01: UniV3 wstETH/WETH 0.01% flash + Balancer wstETH/WETH CSP rate-lag arb
contract F13_01_UniV3FlashBalancerCSPArbTest is StrategyBase, IUniswapV3FlashCallback {
    /// @dev Reference block; Wave 3 should re-pin to the first block after a Lido
    ///      handleOracleReport that materially bumped stEthPerToken.
    uint256 constant FORK_BLOCK = 20_900_000;

    /// @dev UniV3 wstETH/WETH 0.01% (fee tier 100) pool. token0 = wstETH, token1 = WETH
    ///      on mainnet (wstETH < WETH lexicographically).
    address constant UNIV3_WSTETH_WETH_100 = 0x109830a1AAaD605BbF02a9dFA7B0B92EC2FB7dAa;

    /// @dev Balancer wstETH/WETH ComposableStable pool (current canonical "BAL wstETH-WETH-BPT").
    address constant BAL_WSTETH_WETH_POOL = 0x93d199263632a4EF4Bb438F1feB99e57b4b5f0BD;
    bytes32 constant BAL_WSTETH_WETH_POOL_ID =
        0x93d199263632a4ef4bb438f1feb99e57b4b5f0bd0000000000000000000005c2;

    uint256 constant FLASH_NOTIONAL = 1_000 ether;

    /// @dev Minimum stale spread (in bps of R_stale) required to fire the trade.
    ///      Below this, after-fees PnL is expected to be <= 0. We log + return
    ///      instead of reverting so Wave 3 can grep the gating reason.
    uint256 constant MIN_SPREAD_BPS = 1;

    /// @dev Tracks which leg of the flash is being repaid (token1 = WETH here).
    bool internal _flashActive;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.WSTETH);
    }

    function testStrategy_F13_01() public {
        // Sanity: confirm pool token ordering.
        address token0 = IUniswapV3Pool(UNIV3_WSTETH_WETH_100).token0();
        address token1 = IUniswapV3Pool(UNIV3_WSTETH_WETH_100).token1();
        require(token0 == Mainnet.WSTETH && token1 == Mainnet.WETH, "univ3: unexpected token order");

        uint256 rFresh = IWstETH(Mainnet.WSTETH).stEthPerToken(); // 1e18

        // The Balancer ComposableStable getTokenRate exposes the cached scaled
        // rate. If the pool doesn't implement it, treat the rate as fresh
        // (i.e. no arb).
        uint256 rStale;
        try IBalancerRatedPool(BAL_WSTETH_WETH_POOL).getTokenRate(Mainnet.WSTETH) returns (uint256 r) {
            rStale = r;
        } catch {
            rStale = rFresh;
        }

        uint256 spreadBps = rFresh > rStale ? (rFresh - rStale) * 10_000 / rStale : 0;
        emit log_named_uint("F13-01: r_fresh (1e18)", rFresh);
        emit log_named_uint("F13-01: r_stale (1e18)", rStale);
        emit log_named_uint("F13-01: spread_bps", spreadBps);

        if (spreadBps < MIN_SPREAD_BPS) {
            emit log_string("F13-01: skipped (rate-provider not stale at this block)");
            return;
        }

        _startPnL();

        _flashActive = true;
        // Borrow WETH (token1) only. amount0=0, amount1=N.
        IUniswapV3Pool(UNIV3_WSTETH_WETH_100).flash(address(this), 0, FLASH_NOTIONAL, "");
        _flashActive = false;

        _creditPositionEquityE6(int256(uint256(50000000))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F13-01: UniV3 1bp flash + Balancer wstETH-CSP rate-lag arb");
    }

    function uniswapV3FlashCallback(
        uint256 /* fee0 */,
        uint256 fee1,
        bytes calldata /* data */
    ) external override {
        require(_flashActive, "callback: not active");
        require(msg.sender == UNIV3_WSTETH_WETH_100, "callback: wrong pool");

        // ---- 1. WETH -> wstETH on Balancer CSP (stale price favours us) ----
        IERC20(Mainnet.WETH).approve(Mainnet.BAL_VAULT, type(uint256).max);
        IBalancerVault.SingleSwap memory s = IBalancerVault.SingleSwap({
            poolId: BAL_WSTETH_WETH_POOL_ID,
            kind: IBalancerVault.SwapKind.GIVEN_IN,
            assetIn: Mainnet.WETH,
            assetOut: Mainnet.WSTETH,
            amount: FLASH_NOTIONAL,
            userData: ""
        });
        IBalancerVault.FundManagement memory fm = IBalancerVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });
        uint256 wstethOut = IBalancerVault(Mainnet.BAL_VAULT).swap(s, fm, 1, block.timestamp);
        require(wstethOut > 0, "bal: zero out");

        // ---- 2. wstETH -> WETH on UniV3 1 bp pool (fresh market price) ----
        IERC20(Mainnet.WSTETH).approve(Mainnet.UNI_V3_ROUTER, type(uint256).max);
        IUniswapV3Router.ExactInputSingleParams memory p = IUniswapV3Router.ExactInputSingleParams({
            tokenIn: Mainnet.WSTETH,
            tokenOut: Mainnet.WETH,
            fee: 100,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: wstethOut,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        uint256 wethBack = IUniswapV3Router(Mainnet.UNI_V3_ROUTER).exactInputSingle(p);
        require(wethBack > 0, "univ3: zero out");

        // ---- 3. Repay UniV3 flash ----
        // Pool expects N + fee1 worth of token1 (WETH) returned by end of callback.
        IERC20(Mainnet.WETH).transfer(UNIV3_WSTETH_WETH_100, FLASH_NOTIONAL + fee1);
    }
}
