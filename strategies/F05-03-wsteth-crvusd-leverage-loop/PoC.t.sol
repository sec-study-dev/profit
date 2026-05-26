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
contract F05_03_PoC is StrategyBase {
    address constant LLAMMA_WSTETH = 0x37417B2238AA52D0DD2D6252d989E728e8f706e4;
    address constant CONTROLLER_WSTETH = 0x100dAa78fC509Db39Ef7D04DE0c1ABD299f4C6CE;

    // Curve crvUSD/USDC stableswap-NG: 0=crvUSD, 1=USDC
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

            // crvUSD -> USDC
            IERC20(Mainnet.CRVUSD).approve(CURVE_CRVUSD_USDC, crvUsdBal);
            uint256 usdcOut = ICurveStableSwap(CURVE_CRVUSD_USDC).exchange(
                int128(0), int128(1), crvUsdBal, 0
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
        // Touch state so accrual books in: a zero-add collateral call is cheapest.
        // (Controllers don't expose a pure "_save_rate"; use a 1 wei addition.)
        // Note: this requires having 1 wei of wstETH which we never gave up.

        _endPnL("F05-03-wsteth-crvusd-leverage-loop");
    }
}
