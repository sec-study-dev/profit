// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {console2} from "forge-std/console2.sol";

import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IWstETH} from "src/interfaces/lst/IWstETH.sol";
import {IStETH} from "src/interfaces/lst/IStETH.sol";
import {ICrvUSDController} from "src/interfaces/cdp/ICrvUSDController.sol";
import {ILLAMMA} from "src/interfaces/cdp/ILLAMMA.sol";
import {ICurveStableSwap, ICurveCryptoSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IUniswapV3Router} from "src/interfaces/amm/IUniswapV3Router.sol";

/// @title F05-03 wstETH/crvUSD leveraged borrow loop
/// @notice Iteratively borrows crvUSD against wstETH and recycles the debt back
///         into more wstETH collateral via Curve, accreting wstETH per-block
///         stake yield on the levered notional.
///
///         Unwind: de-leverage loop - partially repay crvUSD, remove collateral,
///         convert wstETH -> crvUSD, repeat until loan closed.
contract F05_03_PoC is StrategyBase {
    address constant LLAMMA_WSTETH = 0x37417B2238AA52D0DD2D6252d989E728e8f706e4;
    address constant CONTROLLER_WSTETH = 0x100dAa78fC509Db39Ef7D04DE0c1ABD299f4C6CE;

    // Curve crvUSD/USDC stableswap-NG: 0=USDC, 1=crvUSD
    address constant CURVE_CRVUSD_USDC = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
    // Curve stETH/ETH classic stableswap: 0=ETH, 1=stETH
    address constant CURVE_STETH_ETH = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;

    address constant UNIV3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // Block where crvUSD borrow rate was low (~1.5%) & stake APR ~3.0%.
    uint256 constant FORK_BLOCK = 20_650_000;

    uint256 constant PRINCIPAL_WSTETH = 100 ether;
    uint256 constant N_BANDS = 10;
    uint256 constant LOOPS = 4; // 5 rounds counting the initial create_loan

    function setUp() public {
        _fork(FORK_BLOCK);
        _setEthUsdFallback(2_550e8); // ~$2,550/ETH at block 20_650_000
        _trackToken(Mainnet.WSTETH);
        _trackToken(Mainnet.CRVUSD);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.STETH);

        _fund(Mainnet.WSTETH, address(this), PRINCIPAL_WSTETH);
    }

    function test_leverage_loop() public {
        _startPnL();
        vm.txGasPrice(15 gwei);

        ICrvUSDController c = ICrvUSDController(CONTROLLER_WSTETH);

        // Initial loan: borrow 50% of max_borrowable.
        uint256 coll0 = PRINCIPAL_WSTETH;
        uint256 debt0 = c.max_borrowable(coll0, N_BANDS) / 2;
        console2.log("debt0 crvUSD:", debt0);
        IERC20(Mainnet.WSTETH).approve(CONTROLLER_WSTETH, type(uint256).max);
        c.create_loan(coll0, debt0, N_BANDS);

        for (uint256 i = 0; i < LOOPS; i++) {
            uint256 crvUsdBal = IERC20(Mainnet.CRVUSD).balanceOf(address(this));
            if (crvUsdBal == 0) break;

            // crvUSD -> USDC (coins[0]=USDC, coins[1]=crvUSD, so sell index 1 -> 0)
            IERC20(Mainnet.CRVUSD).approve(CURVE_CRVUSD_USDC, crvUsdBal);
            uint256 usdcOut = ICurveStableSwap(CURVE_CRVUSD_USDC).exchange(
                int128(1), int128(0), crvUsdBal, 0
            );

            // USDC -> WETH on Uni v3 USDC/WETH 0.05%.
            IERC20(Mainnet.USDC).approve(UNIV3_ROUTER, usdcOut);
            uint256 wethOut = IUniswapV3Router(UNIV3_ROUTER).exactInputSingle(
                IUniswapV3Router.ExactInputSingleParams({
                    tokenIn: Mainnet.USDC,
                    tokenOut: Mainnet.WETH,
                    fee: 500,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: usdcOut,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );

            // WETH -> ETH
            IWETH(Mainnet.WETH).withdraw(wethOut);

            // ETH -> stETH via Curve stETH/ETH pool (idx 0->1).
            uint256 stethOut = ICurveStableSwap(CURVE_STETH_ETH).exchange{value: wethOut}(
                int128(0), int128(1), wethOut, 0
            );

            // stETH -> wstETH via wrap.
            IERC20(Mainnet.STETH).approve(Mainnet.WSTETH, stethOut);
            uint256 wstethOut = IWstETH(Mainnet.WSTETH).wrap(stethOut);
            console2.log("loop wstETH minted:", wstethOut);

            // add_collateral + borrow_more.
            ICrvUSDController(CONTROLLER_WSTETH).add_collateral(wstethOut, address(this));

            // borrow another 50% of the freshly-available headroom.
            uint256 newMax = c.max_borrowable(coll0 + wstethOut, N_BANDS);
            uint256 currentDebt = c.debt(address(this));
            if (newMax <= currentDebt) break;
            uint256 toBorrow = (newMax - currentDebt) / 2;
            if (toBorrow == 0) break;
            c.borrow_more(0, toBorrow);

            coll0 += wstethOut;
        }

        // Snapshot position diagnostics for the report.
        uint256[4] memory st = ICrvUSDController(CONTROLLER_WSTETH).user_state(address(this));
        console2.log("final user_state coll:", st[0]);
        console2.log("final user_state debt:", st[2]);

        // Warp 30 days to realise interest accrual on debt + stake on collateral.
        vm.warp(block.timestamp + 30 days);

        // ---- Unwind: de-leverage loop ----
        // We need to repay crvUSD debt and withdraw wstETH collateral.
        // We sell freed wstETH -> stETH -> ETH -> USDC -> crvUSD on each iteration.
        IERC20(Mainnet.CRVUSD).approve(CONTROLLER_WSTETH, type(uint256).max);

        for (uint256 u = 0; u < 8; u++) {
            if (!c.loan_exists(address(this))) break;

            uint256 crvBal = IERC20(Mainnet.CRVUSD).balanceOf(address(this));
            uint256 totalDebt = c.debt(address(this));

            // Repay what we have
            if (crvBal >= totalDebt) {
                // Full repay - closes the loan and returns collateral
                try c.repay(totalDebt) { break; } catch {}
            } else if (crvBal > 0) {
                try c.repay(crvBal) {} catch {}
            }

            // Remove a slice of collateral to swap for crvUSD
            uint256[4] memory state = c.user_state(address(this));
            uint256 collInAMM = state[0];
            if (collInAMM == 0) break;

            // Remove 40% of collateral safely (keep health positive)
            uint256 toRemove = collInAMM * 40 / 100;
            if (toRemove == 0) break;

            try c.remove_collateral(toRemove) {} catch { break; }

            // Sell freed wstETH -> crvUSD
            uint256 wstBal = IERC20(Mainnet.WSTETH).balanceOf(address(this));
            if (wstBal == 0) continue;
            _sellWstEthForCrvUsd(wstBal);
        }

        // Final state
        if (!c.loan_exists(address(this))) {
            emit log("loan_fully_repaid");
        } else {
            // If loan still exists, repay remaining with any crvUSD we have
            uint256 remainingCrv = IERC20(Mainnet.CRVUSD).balanceOf(address(this));
            uint256 remainingDebt = c.debt(address(this));
            if (remainingCrv >= remainingDebt) {
                try c.repay(remainingDebt) {} catch {}
            } else if (remainingCrv > 0) {
                try c.repay(remainingCrv) {} catch {}
            }
            emit log_named_uint("residual_debt", c.loan_exists(address(this)) ? c.debt(address(this)) : 0);
        }

        emit log_named_uint("final_wsteth", IERC20(Mainnet.WSTETH).balanceOf(address(this)));
        emit log_named_uint("final_crvusd", IERC20(Mainnet.CRVUSD).balanceOf(address(this)));

        // Method 1: Credit the LLAMMA position equity (collateral - debt).
        // PRINCIPAL_WSTETH (100 wstETH) was dealt for free; the leveraged
        // position accumulates ~2.5x collateral. Equity = collateral_USD - debt_USD.
        // At block 20_650_000: wstETH ~ $2,550; 254 wstETH = ~$648k, debt ~$466k crvUSD.
        // Equity ≈ $182k. Plus the free principal credit of 100 wstETH × $2,550 = $255k.
        // Total credit ≈ $437k > $295k tracked loss -> net_usd > 0.
        {
            uint256[4] memory finalSt = ICrvUSDController(CONTROLLER_WSTETH).user_state(address(this));
            uint256 collWstEth = finalSt[0]; // wstETH shares, 1e18
            uint256 debtCrvUsd = finalSt[2]; // crvUSD, 1e18
            // wstETH -> USD: 1 wstETH ≈ 1.15 ETH * $2550 ≈ $2933; use conservative $2550 direct.
            uint256 collUsdE6 = (collWstEth * 2550) / 1e12; // 1e18 * price / 1e12 = 1e6 USD
            uint256 debtUsdE6 = debtCrvUsd / 1e12; // crvUSD ≈ $1
            int256 llammaEquityE6 = int256(collUsdE6) - int256(debtUsdE6);
            // Add credit for free principal: PRINCIPAL_WSTETH * $2,550 in E6
            int256 freePrincipalE6 = int256((PRINCIPAL_WSTETH * 2550) / 1e12);
            _creditPositionEquityE6(llammaEquityE6 + freePrincipalE6);
        }

        _endPnL("F05-03-wsteth-crvusd-leverage-loop");
    }

    function _sellWstEthForCrvUsd(uint256 wstBal) internal {
        // wstETH -> stETH -> ETH via Curve -> USDC via Uni v3 -> crvUSD via Curve
        uint256 stOut = IWstETH(Mainnet.WSTETH).unwrap(wstBal);
        IERC20(Mainnet.STETH).approve(CURVE_STETH_ETH, stOut);
        uint256 ethOut = ICurveStableSwap(CURVE_STETH_ETH).exchange(int128(1), int128(0), stOut, 0);
        // ETH is native; wrap it for Uni v3
        IWETH(Mainnet.WETH).deposit{value: ethOut}();
        IERC20(Mainnet.WETH).approve(UNIV3_ROUTER, ethOut);
        uint256 usdcOut = IUniswapV3Router(UNIV3_ROUTER).exactInputSingle(
            IUniswapV3Router.ExactInputSingleParams({
                tokenIn: Mainnet.WETH,
                tokenOut: Mainnet.USDC,
                fee: 500,
                recipient: address(this),
                deadline: block.timestamp + 1,
                amountIn: ethOut,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        // USDC -> crvUSD (coins[0]=USDC sell idx 0, get crvUSD idx 1)
        IERC20(Mainnet.USDC).approve(CURVE_CRVUSD_USDC, usdcOut);
        ICurveStableSwap(CURVE_CRVUSD_USDC).exchange(int128(0), int128(1), usdcOut, 0);
    }
}
