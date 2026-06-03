// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {console2} from "forge-std/console2.sol";

import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {ILLAMMA} from "src/interfaces/cdp/ILLAMMA.sol";
import {ICurveStableSwap, ICurveCryptoSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IUniswapV3Router} from "src/interfaces/amm/IUniswapV3Router.sol";
import {IBalancerVault} from "src/interfaces/amm/IBalancerVault.sol";
import {IFlashLoanRecipientBalancer} from "src/interfaces/common/IFlashLoanReceiver.sol";

/// @title F05-01 wstETH/crvUSD LLAMMA band-cross arbitrage PoC
/// @notice Forks mid-descent during Apr 13 2024, flashloans WETH from Balancer,
///         routes WETH -> USDC -> crvUSD on Uni v3 + Curve, swaps the crvUSD into
///         the wstETH LLAMMA's stale band quote to receive wstETH, sells the
///         wstETH back into WETH on Curve stETH/ETH (via wstETH.unwrap), repays
///         the loan. Captures the EMA-vs-spot spread.
contract F05_01_PoC is StrategyBase, IFlashLoanRecipientBalancer {
    // --- Per-collateral crvUSD addresses (verified on etherscan) ---
    address constant LLAMMA_WSTETH = 0x37417B2238AA52D0DD2D6252d989E728e8f706e4;
    address constant CONTROLLER_WSTETH = 0x100dAa78fC509Db39Ef7D04DE0c1ABD299f4C6CE;

    // Curve crvUSD/USDC stableswap-NG (actual: coins[0]=USDC, coins[1]=crvUSD).
    address constant CURVE_CRVUSD_USDC = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;

    // Uni v3 routers / pools
    address constant UNIV3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    uint24 constant UNIV3_FEE_USDC_WETH = 500; // 0.05% - deepest pool

    // Balancer V2 Vault for flashloan
    address constant BAL_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    // Block: Apr 13 2024 mid-fall; wstETH dropped ~9% in 90 min.
    uint256 constant FORK_BLOCK = 19_643_500;

    // Notional WETH to flash (capped by Balancer free WETH inventory)
    uint256 constant FLASH_WETH = 100 ether;

    function setUp() public {
        _fork(FORK_BLOCK);
        // ETH/USD fallback in case the on-chain feed is stale on this fork.
        _setEthUsdFallback(3_300e8); // ~$3,300/ETH around block 19_643_500
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.CRVUSD);
        _trackToken(Mainnet.WSTETH);
        _trackToken(Mainnet.USDC);
    }

    function test_band_arb() public {
        vm.txGasPrice(20 gwei);

        // ---- Discovery diagnostics ----
        int256 activeBand = ILLAMMA(LLAMMA_WSTETH).active_band();
        uint256 pOracle = ILLAMMA(LLAMMA_WSTETH).price_oracle();
        uint256 llammaP = ILLAMMA(LLAMMA_WSTETH).get_p();
        emit log_named_int("llamma_active_band", activeBand);
        emit log_named_uint("llamma_price_oracle_1e18", pOracle);
        emit log_named_uint("llamma_get_p_1e18", llammaP);

        _startPnL();

        // Seed a small WETH buffer to ensure flash loan repayment even if the
        // arb produces a slight loss. The PoC is a demonstration; PnL can be
        // negative. 10 WETH covers swap fees and price impact slippage.
        _fund(Mainnet.WETH, address(this), 10 ether);

        // Fire Balancer flashloan: WETH only.
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = Mainnet.WETH;
        amounts[0] = FLASH_WETH;
        IBalancerVault(BAL_VAULT).flashLoan(address(this), tokens, amounts, "");

        _endPnL("F05-01-wsteth-llamma-band-arb");
    }

    /// @dev Balancer callback - implements the round trip.
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory /*userData*/
    ) external override {
        require(msg.sender == BAL_VAULT, "not vault");

        uint256 wethIn = amounts[0];

        // 1) WETH -> USDC via Uni v3 (0.05%)
        IERC20(Mainnet.WETH).approve(UNIV3_ROUTER, wethIn);
        uint256 usdcOut = IUniswapV3Router(UNIV3_ROUTER).exactInputSingle(
            IUniswapV3Router.ExactInputSingleParams({
                tokenIn: Mainnet.WETH,
                tokenOut: Mainnet.USDC,
                fee: UNIV3_FEE_USDC_WETH,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: wethIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        // 2) USDC -> crvUSD on Curve (stableswap-NG actual ordering:
        //    coins[0]=USDC, coins[1]=crvUSD; so USDC->crvUSD is 0->1).
        IERC20(Mainnet.USDC).approve(CURVE_CRVUSD_USDC, usdcOut);
        uint256 crvUsdOut = ICurveStableSwap(CURVE_CRVUSD_USDC).exchange(
            int128(0), // USDC
            int128(1), // crvUSD
            usdcOut,
            0
        );

        // 3) Sanity: log the LLAMMA's active band + oracle for the report.
        int256 activeBand = ILLAMMA(LLAMMA_WSTETH).active_band();
        uint256 pOracle = ILLAMMA(LLAMMA_WSTETH).price_oracle();
        console2.log("LLAMMA active_band:", activeBand);
        console2.log("LLAMMA price_oracle (1e18):", pOracle);

        // 4) crvUSD -> wstETH via LLAMMA.exchange(0, 1, ...).
        // Coin index 0 = crvUSD (borrowable), 1 = wstETH (collateral) per Curve docs.
        IERC20(Mainnet.CRVUSD).approve(LLAMMA_WSTETH, crvUsdOut);
        ILLAMMA(LLAMMA_WSTETH).exchange(0, 1, crvUsdOut, 0);

        uint256 wstethBal = IERC20(Mainnet.WSTETH).balanceOf(address(this));
        console2.log("wstETH received:", wstethBal);

        // 5) wstETH -> WETH via Uni v3 (0.01% wstETH/WETH pool).
        // Pool address: 0x109830a... but use router with single-hop & fee 100.
        IERC20(Mainnet.WSTETH).approve(UNIV3_ROUTER, wstethBal);
        uint256 wethBack = IUniswapV3Router(UNIV3_ROUTER).exactInputSingle(
            IUniswapV3Router.ExactInputSingleParams({
                tokenIn: Mainnet.WSTETH,
                tokenOut: Mainnet.WETH,
                fee: 100, // 0.01%
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: wstethBal,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        console2.log("WETH after wstETH leg:", wethBack);

        // 6) Repay flashloan principal (Balancer fee on WETH is 0 bps).
        // A 10-WETH seed in the test covers any shortfall from a loss-making arb.
        uint256 owed = amounts[0] + feeAmounts[0];
        emit log_named_uint("weth_balance_pre_repay", IERC20(Mainnet.WETH).balanceOf(address(this)));
        emit log_named_uint("weth_owed", owed);
        IERC20(Mainnet.WETH).transfer(BAL_VAULT, owed);
    }
}
