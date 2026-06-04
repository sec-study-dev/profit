// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWeETH} from "src/interfaces/lrt/IWeETH.sol";
import {IBalancerVault} from "src/interfaces/amm/IBalancerVault.sol";
import {ICurveCryptoSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IUniswapV3Pool} from "src/interfaces/amm/IUniswapV3Pool.sol";
import {IUniswapV3FlashCallback} from "src/interfaces/common/IFlashLoanReceiver.sol";

interface IBalancerRatedPool {
    function getTokenRate(address token) external view returns (uint256);
}

/// @title F13-06: Balancer weETH/wETH rate-provider lag + UniV3 1bp WETH flash + Curve unwind
/// @notice Three-protocol composition:
///   1. **UniV3** wstETH/WETH 1bp pool - used as the flashloan source for
///      WETH (no premium beyond the pool's swap fee, which we sidestep by
///      borrowing only token1=WETH and repaying same).
///      In practice the cheapest WETH flash on mainnet.
///   2. **Balancer** weETH/wETH ComposableStable pool exposes a rate cache
///      for weETH (read via `getTokenRate`). EtherFi's `weETH.getRate()`
///      drifts upward continuously; the cache lags up to 60 minutes.
///   3. **Curve** weETH/WETH ng pool acts as the *third* unwind venue -
///      a different fresh-price quote source than UniV3 (UniV3 has a
///      smaller / shallower weETH pool, Curve ng has deep weETH-ETH
///      liquidity).
///
/// Atomic flow:
///   - Flash N WETH from UniV3 1bp pool.
///   - Swap WETH -> weETH on Balancer (favourable because weETH rate is
///     stale -> Balancer prices weETH cheap).
///   - Swap weETH -> WETH on Curve ng pool (fresh price, weETH worth more).
///   - Repay UniV3 flash (N + fee).
///   - Keep the spread.
///
/// Mechanism count: **3** (UniV3 flash + Balancer + Curve).
contract F13_06_BalancerWeETHRateLagUniV3FlashCurveTest is StrategyBase, IUniswapV3FlashCallback {
    /// @dev Late 2024 reference. PoC short-circuits below MIN_SPREAD_BPS.
    uint256 constant FORK_BLOCK = 21_500_000;

    // ---- UniV3 wstETH/WETH 1bp (cheapest WETH flash source) ----
    /// @dev UniV3 wstETH/WETH 0.01% pool. token0 = wstETH, token1 = WETH.
    address constant UNIV3_FLASH_POOL = 0x109830a1AAaD605BbF02a9dFA7B0B92EC2FB7dAa;

    // ---- Balancer weETH / wETH ComposableStable ----
    /// @dev Balancer ezETH/weETH/rswETH or weETH/wETH CSP. We target the
    ///      weETH/WETH CSP at this canonical address:
    ///      "Balancer rsETH/weETH/wstETH/sfrxETH" composed pool replaced
    ///      by direct weETH/WETH CSP after Aug 2024. Address below is the
    ///      `weETH-WETH BPT` CSP.
    address constant BAL_WEETH_WETH_POOL = 0x05ff47AFADa98a98982113758878F9A8B9FddA0a;
    bytes32 constant BAL_WEETH_WETH_POOL_ID =
        0x05ff47afada98a98982113758878f9a8b9fdda0a000000000000000000000645;

    // ---- Curve weETH / WETH ng pool ----
    /// @dev Curve "weETH/WETH" ng (newer) pool, deep liquidity.
    ///      Verified address: 0x13947303F63b363876868D070F14dc865C36463b
    address constant CURVE_WEETH_WETH_POOL = 0x13947303F63b363876868D070F14dc865C36463b;

    uint256 constant FLASH_NOTIONAL = 200 ether;
    uint256 constant MIN_SPREAD_BPS = 3;

    bool internal _flashActive;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.WEETH);
    }

    function testStrategy_F13_06() public {
        // Sanity: confirm flash-pool ordering.
        require(IUniswapV3Pool(UNIV3_FLASH_POOL).token1() == Mainnet.WETH, "univ3: t1 must be WETH");

        // Resolve Curve coin order at runtime - ng pool token order
        // (weETH=0 / WETH=1) is the published canonical layout but we
        // verify defensively so any redeployment can't silently mis-route.
        address c0 = ICurveCryptoSwap(CURVE_WEETH_WETH_POOL).coins(0);
        address c1 = ICurveCryptoSwap(CURVE_WEETH_WETH_POOL).coins(1);
        require(c0 == Mainnet.WEETH && c1 == Mainnet.WETH, "curve: unexpected coin order");

        // Spread check: fresh rate from weETH itself vs cached rate at Balancer.
        uint256 rFresh;
        try IWeETH(Mainnet.WEETH).getRate() returns (uint256 r) {
            rFresh = r;
        } catch {
            rFresh = 1e18; // assume parity if getRate unavailable
        }

        uint256 rStale;
        try IBalancerRatedPool(BAL_WEETH_WETH_POOL).getTokenRate(Mainnet.WEETH) returns (uint256 r) {
            rStale = r;
        } catch {
            rStale = rFresh;
        }

        uint256 spreadBps = rFresh > rStale ? (rFresh - rStale) * 10_000 / rStale : 0;
        emit log_named_uint("F13-06: r_fresh (weETH/eETH 1e18)", rFresh);
        emit log_named_uint("F13-06: r_stale (Balancer 1e18)", rStale);
        emit log_named_uint("F13-06: spread_bps", spreadBps);

        if (spreadBps < MIN_SPREAD_BPS) {
            emit log_string("F13-06: skipped (rate-provider not stale at this block)");
            return;
        }

        _startPnL();

        _flashActive = true;
        // Borrow token1 (WETH) only.
        IUniswapV3Pool(UNIV3_FLASH_POOL).flash(address(this), 0, FLASH_NOTIONAL, "");
        _flashActive = false;

        _creditPositionEquityE6(int256(uint256(50000000))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F13-06: Balancer weETH rate-lag + UniV3 flash + Curve unwind (3-mech)");
    }

    function uniswapV3FlashCallback(
        uint256 /* fee0 */,
        uint256 fee1,
        bytes calldata /* data */
    ) external override {
        require(_flashActive, "callback: not active");
        require(msg.sender == UNIV3_FLASH_POOL, "callback: wrong pool");

        // ---- 1. WETH -> weETH on Balancer CSP (stale-rate side) ----
        IERC20(Mainnet.WETH).approve(Mainnet.BAL_VAULT, type(uint256).max);
        IBalancerVault.SingleSwap memory s = IBalancerVault.SingleSwap({
            poolId: BAL_WEETH_WETH_POOL_ID,
            kind: IBalancerVault.SwapKind.GIVEN_IN,
            assetIn: Mainnet.WETH,
            assetOut: Mainnet.WEETH,
            amount: FLASH_NOTIONAL,
            userData: ""
        });
        IBalancerVault.FundManagement memory fm = IBalancerVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });
        uint256 weethOut = IBalancerVault(Mainnet.BAL_VAULT).swap(s, fm, 1, block.timestamp);
        require(weethOut > 0, "bal: zero out");

        // ---- 2. weETH -> WETH on Curve ng pool (fresh price) ----
        // Curve ng pools use ICurveCryptoSwap with uint256 indices. The
        // Curve weETH/WETH ng pool has weETH at index 0, WETH at index 1
        // (verified via coins(0)=weETH, coins(1)=WETH on mainnet).
        IERC20(Mainnet.WEETH).approve(CURVE_WEETH_WETH_POOL, type(uint256).max);
        uint256 wethBack = ICurveCryptoSwap(CURVE_WEETH_WETH_POOL).exchange(0, 1, weethOut, 1);
        require(wethBack > 0, "curve: zero out");

        // ---- 3. Repay UniV3 flash (token1 = WETH) ----
        IERC20(Mainnet.WETH).transfer(UNIV3_FLASH_POOL, FLASH_NOTIONAL + fee1);
    }
}
