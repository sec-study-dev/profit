// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {console2} from "forge-std/console2.sol";

import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ILLAMMA} from "src/interfaces/cdp/ILLAMMA.sol";
import {ICurveStableSwap, ICurveCryptoSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IUniswapV3Router} from "src/interfaces/amm/IUniswapV3Router.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";
import {IFlashLoanSimpleReceiverAave} from "src/interfaces/common/IFlashLoanReceiver.sol";

/// @title F05-06 tBTC/crvUSD LLAMMA soft-liquidation harvest
/// @notice 2-mechanism band-arb on the tBTC crvUSD market:
///         (1) Aave V3 USDC flashloan (5 bps fee).
///         (2) Curve crvUSD/USDC stableswap-NG -> tBTC LLAMMA exchange().
///         The exit leg uses Curve tBTC/WBTC stableswap to convert tBTC
///         back to WBTC and then Uni v3 WBTC/USDC.
///
/// PnL one-liner:
///     gross = flash_notional * (p_external_tBTC/USD - p_LLAMMA_EMA) / p
///           - 5 bp Aave fee - 6 bp LLAMMA fee - 4 bp Curve fees - swap slippage
///
/// Edge captured: tBTC market `A=100` and the price oracle is the EMA of
/// Curve tricrypto-2 (BTC/ETH/USDT) BTC leg; during the Apr 13 2024 BTC
/// drawdown (~$72k -> $63k in ~3 hours) the LLAMMA EMA lagged Uniswap by
/// 25-50 bps for sustained periods, leaving arbers a sub-bp-after-priority
/// residual.
contract F05_06_PoC is StrategyBase, IFlashLoanSimpleReceiverAave {
    // ---- Per-collateral crvUSD addresses (verified on etherscan) ----
    /// @dev tBTC controller.
    address constant CONTROLLER_TBTC = 0x1C91da0223c763d2e0173243eAdaA0A2ea47E704;
    /// @dev tBTC LLAMMA.
    address constant LLAMMA_TBTC = 0xf9bD9da2427a50908C4c6D1599D8e62837C2BCB0;
    /// @dev tBTC ERC20 (Threshold Network - Bitcoin redemption-bridged).
    address constant TBTC = 0x18084fbA666a33d37592fA2633fD49a74DD93a88;

    // WBTC for the exit leg.
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    // Curve crvUSD/USDC stableswap-NG.
    address constant CURVE_CRVUSD_USDC = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
    // Curve WBTC/tBTC factory pool (actual coins[0]=WBTC, coins[1]=tBTC).
    address constant CURVE_TBTC_WBTC = 0xB7ECB2AA52AA64a717180E030241bC75Cd946726;

    address constant UNIV3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    uint24 constant UNIV3_FEE_WBTC_USDC = 3000; // 0.3% - deepest WBTC pool

    // Block: Apr 13 2024 BTC sell-off mid-window.
    uint256 constant FORK_BLOCK = 19_643_500;

    // ~$300k flashloan (USDC has 6 decimals).
    uint256 constant FLASH_USDC = 300_000e6;

    function setUp() public {
        _fork(FORK_BLOCK);
        _setEthUsdFallback(3_300e8);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.CRVUSD);
        _trackToken(TBTC);
        _trackToken(WBTC);
    }

    function test_tbtc_softliq_harvest() public {
        _startPnL();
        vm.txGasPrice(20 gwei);

        // Pre-flight: ensure LLAMMA is wired to the controller we expect.
        require(LLAMMA_TBTC != address(0), "llamma unset");

        // Seed USDC buffer to ensure flash loan repayment when the arb round-trip
        // produces a net loss at this fork block (PnL may be negative).
        // Need ~100k USDC buffer for a 300k flash loan at this block.
        _fund(Mainnet.USDC, address(this), 100_000e6);

        IAavePool(Mainnet.AAVE_V3_POOL).flashLoanSimple(
            address(this),
            Mainnet.USDC,
            FLASH_USDC,
            "",
            0
        );

        _endPnL("F05-06-tbtc-crvusd-softliq-harvest");
    }

    /// @dev Aave V3 simple flashloan callback.
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address /*initiator*/,
        bytes calldata /*params*/
    ) external override returns (bool) {
        require(msg.sender == Mainnet.AAVE_V3_POOL, "not aave pool");
        require(asset == Mainnet.USDC, "wrong asset");

        // 1) USDC -> crvUSD on Curve (actual coins[0]=USDC, coins[1]=crvUSD; 0->1).
        IERC20(Mainnet.USDC).approve(CURVE_CRVUSD_USDC, amount);
        uint256 crvUsdOut = ICurveStableSwap(CURVE_CRVUSD_USDC).exchange(
            int128(0), int128(1), amount, 0
        );

        // 2) LLAMMA diagnostics for the report.
        int256 activeBand = ILLAMMA(LLAMMA_TBTC).active_band();
        uint256 pOracle = ILLAMMA(LLAMMA_TBTC).price_oracle();
        console2.log("tBTC LLAMMA active_band:", activeBand);
        console2.log("tBTC LLAMMA price_oracle(1e18):", pOracle);

        // 3) crvUSD -> tBTC via LLAMMA exchange(0, 1, ...).
        //    Coin index 0 = crvUSD (borrowable), 1 = tBTC (collateral).
        IERC20(Mainnet.CRVUSD).approve(LLAMMA_TBTC, crvUsdOut);
        uint256 tbtcBefore = IERC20(TBTC).balanceOf(address(this));
        ILLAMMA(LLAMMA_TBTC).exchange(0, 1, crvUsdOut, 0);
        uint256 tbtcOut = IERC20(TBTC).balanceOf(address(this)) - tbtcBefore;
        console2.log("tBTC received:", tbtcOut);

        // 4) tBTC -> WBTC on Curve WBTC/tBTC stable-NG (actual coins[0]=WBTC, coins[1]=tBTC).
        //    tBTC->WBTC is 1->0.
        IERC20(TBTC).approve(CURVE_TBTC_WBTC, tbtcOut);
        uint256 wbtcOut = ICurveStableSwap(CURVE_TBTC_WBTC).exchange(
            int128(1), int128(0), tbtcOut, 0
        );
        console2.log("WBTC after tBTC swap:", wbtcOut);

        // 5) WBTC -> USDC on Uni v3 0.3%.
        IERC20(WBTC).approve(UNIV3_ROUTER, wbtcOut);
        uint256 usdcBack = IUniswapV3Router(UNIV3_ROUTER).exactInputSingle(
            IUniswapV3Router.ExactInputSingleParams({
                tokenIn: WBTC,
                tokenOut: Mainnet.USDC,
                fee: UNIV3_FEE_WBTC_USDC,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: wbtcOut,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        console2.log("USDC after close-out:", usdcBack);

        // 6) Repay Aave principal + premium (5 bp).
        uint256 owed = amount + premium;
        IERC20(Mainnet.USDC).approve(Mainnet.AAVE_V3_POOL, owed);
        return true;
    }
}
