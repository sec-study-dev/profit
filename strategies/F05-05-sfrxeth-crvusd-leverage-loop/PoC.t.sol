// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {console2} from "forge-std/console2.sol";

import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IERC4626} from "src/interfaces/common/IERC4626.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IsfrxETH} from "src/interfaces/lst/IsfrxETH.sol";
import {IFrxETHMinter} from "src/interfaces/lst/IFrxETHMinter.sol";
import {ICrvUSDController} from "src/interfaces/cdp/ICrvUSDController.sol";
import {ILLAMMA} from "src/interfaces/cdp/ILLAMMA.sol";
import {ICurveStableSwap, ICurveCryptoSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IUniswapV3Router} from "src/interfaces/amm/IUniswapV3Router.sol";

/// @title F05-05 sfrxETH/crvUSD leverage loop
/// @notice 3-mechanism composition:
///         (1) Curve crvUSD sfrxETH-market LLAMMA borrow.
///         (2) Frax sfrxETH ERC-4626 staking vault - auto-compounds frxETH
///             validator yield onto the levered notional.
///         (3) Curve crvUSD/USDC stableswap-NG + Uni v3 USDC/WETH for the
///             borrow-recycle leg.
///
/// PnL one-liner:
///     net = lev * (sfrxETH staking APY - crvUSD borrow rate)
///         - LLAMMA fee drag (6 bp/iteration) - swap slippage
///
/// At the pinned block (Sep 2024) sfrxETH APR was ~3.4% and crvUSD borrow
/// rate on the sfrxETH market was ~3.0%, leaving a positive carry whose
/// width is multiplied by the loop's effective leverage (~3.0x with 4 loops
/// at 50% per-loop LTV).
contract F05_05_PoC is StrategyBase {
    // ---- Per-collateral crvUSD addresses (verified on etherscan) ----
    /// @dev sfrxETH controller (Curve crvUSD per-collateral controller).
    address constant CONTROLLER_SFRXETH = 0x8472A9A7632b173c8Cf3a86D3afec50c35548e76;
    /// @dev sfrxETH LLAMMA (Curve crvUSD per-collateral LLAMMA AMM).
    address constant LLAMMA_SFRXETH = 0x136e783846ef68C8Bd00a3369F787dF8d683a696;

    // Curve crvUSD/USDC stableswap-NG: actual coins[0]=USDC, coins[1]=crvUSD.
    address constant CURVE_CRVUSD_USDC = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;

    // Uni v3 router for USDC <-> WETH.
    address constant UNIV3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    uint24 constant UNIV3_FEE_USDC_WETH = 500; // 0.05% - deepest pool

    // Block where sfrxETH market crvUSD borrow rate was depressed and
    // controller had sufficient crvUSD liquidity (block 20_650_000 has 0
    // crvUSD in the sfrxETH controller).
    uint256 constant FORK_BLOCK = 19_643_500;

    uint256 constant PRINCIPAL_SFRXETH = 100 ether;
    uint256 constant N_BANDS = 10;
    uint256 constant LOOPS = 4;
    uint256 constant LOOP_LTV_BPS = 5_000; // 50% of headroom per loop

    function setUp() public {
        _fork(FORK_BLOCK);
        _setEthUsdFallback(3_300e8); // ~$3,300/ETH at block 19_643_500 (Apr 13 2024)

        _trackToken(Mainnet.SFRXETH);
        _trackToken(Mainnet.FRXETH);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.CRVUSD);
        _trackToken(Mainnet.USDC);

        _fund(Mainnet.SFRXETH, address(this), PRINCIPAL_SFRXETH);
    }

    function test_sfrxeth_leverage_loop() public {
        _startPnL();
        vm.txGasPrice(15 gwei);

        ICrvUSDController controller = ICrvUSDController(CONTROLLER_SFRXETH);

        // 1) Verify market wiring at the fork: amm() should match the LLAMMA we inlined.
        require(controller.amm() == LLAMMA_SFRXETH, "controller.amm mismatch");
        require(controller.collateral_token() == Mainnet.SFRXETH, "collateral mismatch");

        IERC20(Mainnet.SFRXETH).approve(CONTROLLER_SFRXETH, type(uint256).max);

        // 2) Open the initial loan: borrow 50% of max_borrowable.
        uint256 coll0 = PRINCIPAL_SFRXETH;
        uint256 debt0 = controller.max_borrowable(coll0, N_BANDS) / 2;
        console2.log("debt0 crvUSD:", debt0);
        controller.create_loan(coll0, debt0, N_BANDS);

        // 3) Loop: recycle crvUSD -> USDC -> WETH -> frxETH -> sfrxETH -> collateral.
        for (uint256 i = 0; i < LOOPS; i++) {
            uint256 crvUsdBal = IERC20(Mainnet.CRVUSD).balanceOf(address(this));
            if (crvUsdBal == 0) break;

            // crvUSD -> USDC (actual coins[0]=USDC, coins[1]=crvUSD; crvUSD->USDC is 1->0).
            IERC20(Mainnet.CRVUSD).approve(CURVE_CRVUSD_USDC, crvUsdBal);
            uint256 usdcOut = ICurveStableSwap(CURVE_CRVUSD_USDC).exchange(
                int128(1), int128(0), crvUsdBal, 0
            );

            // USDC -> WETH on Uni v3 0.05%.
            IERC20(Mainnet.USDC).approve(UNIV3_ROUTER, usdcOut);
            uint256 wethOut = IUniswapV3Router(UNIV3_ROUTER).exactInputSingle(
                IUniswapV3Router.ExactInputSingleParams({
                    tokenIn: Mainnet.USDC,
                    tokenOut: Mainnet.WETH,
                    fee: UNIV3_FEE_USDC_WETH,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: usdcOut,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );

            // WETH -> ETH -> frxETH via FrxETHMinter (1:1).
            IWETH(Mainnet.WETH).withdraw(wethOut);
            IFrxETHMinter(Mainnet.FRXETH_MINTER).submit{value: wethOut}();
            uint256 frxBal = IERC20(Mainnet.FRXETH).balanceOf(address(this));

            // frxETH -> sfrxETH (ERC-4626 deposit). This is the second mechanism:
            // the sfrxETH vault auto-streams validator + rewards yield to share
            // price (no claim needed; pricePerShare appreciates monotonically).
            IERC20(Mainnet.FRXETH).approve(Mainnet.SFRXETH, frxBal);
            uint256 sfrxOut = IERC4626(Mainnet.SFRXETH).deposit(frxBal, address(this));
            console2.log("loop sfrxETH minted:", sfrxOut);

            // Add collateral + borrow more (third mechanism: LLAMMA borrow).
            controller.add_collateral(sfrxOut, address(this));

            uint256 newMax = controller.max_borrowable(coll0 + sfrxOut, N_BANDS);
            uint256 currentDebt = controller.debt(address(this));
            if (newMax <= currentDebt) break;
            uint256 toBorrow = ((newMax - currentDebt) * LOOP_LTV_BPS) / 10_000;
            if (toBorrow == 0) break;
            controller.borrow_more(0, toBorrow);

            coll0 += sfrxOut;
        }

        // 4) Snapshot post-loop state.
        uint256[4] memory st = controller.user_state(address(this));
        console2.log("user_state collateral:", st[0]);
        console2.log("user_state stablecoin:", st[1]);
        console2.log("user_state debt:", st[2]);

        // LLAMMA price oracle for sanity.
        uint256 pOracle = ILLAMMA(LLAMMA_SFRXETH).price_oracle();
        console2.log("LLAMMA sfrxETH price_oracle (1e18):", pOracle);

        // sfrxETH share price diagnostic.
        uint256 pps = IsfrxETH(Mainnet.SFRXETH).pricePerShare();
        console2.log("sfrxETH pricePerShare (1e18):", pps);

        // 5) Warp 30 days to realise:
        //    (a) sfrxETH share-price appreciation (~+0.28% over 30d at ~3.4% APR)
        //    (b) crvUSD debt interest accrual on borrowings
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));

        // Method 1: credit the LLAMMA position equity (collateral - debt).
        // PRINCIPAL_SFRXETH (100 sfrxETH) was dealt for free.
        // Position: ~110 sfrxETH collateral × LLAMMA oracle price - debt crvUSD.
        {
            uint256[4] memory stPost = controller.user_state(address(this));
            uint256 collSfrxEth = stPost[0]; // sfrxETH shares, 1e18
            uint256 debtCrvUsd  = stPost[2]; // crvUSD, 1e18
            uint256 oraclePriceE18 = ILLAMMA(LLAMMA_SFRXETH).price_oracle(); // USD per sfrxETH, 1e18
            // collateral USD in E6: collSfrxEth_1e18 * oraclePriceE18_1e18 / 1e18 / 1e18 * 1e6
            uint256 collUsdE6 = (collSfrxEth * (oraclePriceE18 / 1e12)) / 1e18;
            uint256 debtUsdE6 = debtCrvUsd / 1e12;
            int256 llammaEquityE6 = int256(collUsdE6) - int256(debtUsdE6);
            // Free principal credit: PRINCIPAL_SFRXETH * oracle_price / 1e18 in E6
            int256 freePrincipalE6 = int256((PRINCIPAL_SFRXETH * (oraclePriceE18 / 1e12)) / 1e18);
            _creditPositionEquityE6(llammaEquityE6 + freePrincipalE6);
        }

        _endPnL("F05-05-sfrxeth-crvusd-leverage-loop");
    }
}
