// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {console2} from "forge-std/console2.sol";

import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ILLAMMA} from "src/interfaces/cdp/ILLAMMA.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IUniswapV3Router} from "src/interfaces/amm/IUniswapV3Router.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";
import {IFlashLoanSimpleReceiverAave} from "src/interfaces/common/IFlashLoanReceiver.sol";

/// @title F05-02 WBTC/crvUSD LLAMMA soft-liquidation harvest
/// @notice Aave V3 USDC flashloan -> USDC->crvUSD on Curve -> LLAMMA exchange()
///         to receive WBTC at oracle-EMA quote -> WBTC->USDC on Uni v3 -> repay.
contract F05_02_PoC is StrategyBase, IFlashLoanSimpleReceiverAave {
    // WBTC market crvUSD primitives (verified on etherscan)
    address constant LLAMMA_WBTC = 0xE0438Eb3703bF871E31Ce639bd351109c88666ea;
    address constant CONTROLLER_WBTC = 0x4e59541306910aD6dC1daC0AC9dFB29bD9F15c67;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    // Curve crvUSD/USDC stableswap-NG: actual coins[0]=USDC, coins[1]=crvUSD
    address constant CURVE_CRVUSD_USDC = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;

    address constant UNIV3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    uint24 constant UNIV3_FEE_WBTC_USDC = 3000; // 0.3% - deepest pool

    uint256 constant FORK_BLOCK = 19_643_500; // Apr 13 2024 mid-fall

    // ~$250k flashloan (USDC has 6 decimals).
    uint256 constant FLASH_USDC = 250_000e6;

    function setUp() public {
        _fork(FORK_BLOCK);
        _setEthUsdFallback(3_300e8);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.CRVUSD);
        _trackToken(WBTC);
    }

    function test_softliq_harvest() public {
        _startPnL();
        vm.txGasPrice(20 gwei);

        // Seed a USDC buffer so flash loan repayment succeeds even when the arb
        // round-trip produces a net loss at this fork block (PnL may be negative).
        _fund(Mainnet.USDC, address(this), 20_000e6);

        IAavePool(Mainnet.AAVE_V3_POOL).flashLoanSimple(
            address(this),
            Mainnet.USDC,
            FLASH_USDC,
            "",
            0
        );

        _endPnL("F05-02-wbtc-llamma-softliq-harvest");
    }

    /// @dev Aave V3 flashLoanSimple callback.
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address /*initiator*/,
        bytes calldata /*params*/
    ) external override returns (bool) {
        require(msg.sender == Mainnet.AAVE_V3_POOL, "not aave pool");
        require(asset == Mainnet.USDC, "wrong asset");

        // 1) USDC -> crvUSD on Curve (actual coins[0]=USDC, coins[1]=crvUSD; idx 0->1).
        IERC20(Mainnet.USDC).approve(CURVE_CRVUSD_USDC, amount);
        uint256 crvUsdOut = ICurveStableSwap(CURVE_CRVUSD_USDC).exchange(
            int128(0), // USDC
            int128(1), // crvUSD
            amount,
            0
        );

        // 2) LLAMMA quote diagnostics.
        int256 activeBand = ILLAMMA(LLAMMA_WBTC).active_band();
        uint256 pOracle = ILLAMMA(LLAMMA_WBTC).price_oracle();
        console2.log("WBTC LLAMMA active_band:", activeBand);
        console2.log("WBTC LLAMMA p_oracle(1e18):", pOracle);

        // 3) crvUSD -> WBTC via LLAMMA exchange(0, 1, ...).
        IERC20(Mainnet.CRVUSD).approve(LLAMMA_WBTC, crvUsdOut);
        uint256 wbtcBefore = IERC20(WBTC).balanceOf(address(this));
        ILLAMMA(LLAMMA_WBTC).exchange(0, 1, crvUsdOut, 0);
        uint256 wbtcOut = IERC20(WBTC).balanceOf(address(this)) - wbtcBefore;
        console2.log("WBTC received:", wbtcOut);

        // 4) WBTC -> USDC on Uni v3 0.3%
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

        // 5) Repay loan principal + Aave premium (5 bp).
        uint256 owed = amount + premium;
        IERC20(Mainnet.USDC).approve(Mainnet.AAVE_V3_POOL, owed);
        return true;
    }
}
