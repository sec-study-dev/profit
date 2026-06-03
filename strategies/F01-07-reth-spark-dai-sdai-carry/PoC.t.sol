// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IRETH} from "src/interfaces/lst/IRETH.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";
import {IBalancerVault} from "src/interfaces/amm/IBalancerVault.sol";
import {IUniswapV3Router} from "src/interfaces/amm/IUniswapV3Router.sol";
import {ISDAI} from "src/interfaces/stable/ISDAI.sol";
import {IPot} from "src/interfaces/cdp/IPot.sol";

/// @title F01-07 rETH on Spark with DAI borrow re-deployed to sDAI
/// @notice THREE distinct DeFi mechanisms in one position:
///         (1) Rocket Pool rETH (LST internal exchange rate)
///         (2) Spark Protocol (Aave v3 fork) lending - borrow DAI vs rETH
///         (3) MakerDAO Pot DSR via sDAI ERC-4626 - hedges the Spark DAI cost
contract F01_07_RethSparkDaiSdaiCarryTest is StrategyBase {
    uint256 constant FORK_BLOCK = 19_700_000;

    // Balancer rETH/WETH MetaStable pool - deepest on-chain rETH venue
    // (~8.7k rETH / 9.8k WETH at this block). Used for both the entry
    // (WETH->rETH) and exit (rETH->WETH) legs so costs are realised.
    bytes32 constant BAL_RETH_WETH_POOL_ID =
        0x1e19cf2d73a72ef1332c882f20534b6519be0276000200000000000000000112;
    // Uniswap v3 DAI/WETH 0.3% pool fee tier (deep, ~5M DAI) for the small
    // WETH->DAI top-up that covers the borrow-vs-DSR carry shortfall on exit.
    uint24 constant UNIV3_DAI_WETH_FEE = 3000;

    uint256 constant RATE_MODE_VARIABLE = 2;

    // Effective LTV target - Spark's rETH borrow LTV at fork is ~0.74; we
    // target 0.85 * 0.74 ~= 0.63 to leave a wide buffer (this is a *carry*
    // strategy, not a max-LTV looper).
    uint256 constant BORROW_LTV_BPS = 6300;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.RETH);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.SDAI);
    }

    function testStrategy_F01_07() public {
        uint256 principal = 100 ether;
        _fund(Mainnet.WETH, address(this), principal);
        _startPnL();

        IAavePool spark = IAavePool(Mainnet.SPARK_POOL);
        ISDAI sdai = ISDAI(Mainnet.SDAI);
        IPot pot = IPot(Mainnet.POT);

        // Diagnostic: snapshot DSR + Spark DAI variable rate. These two should
        // be close (Spark calibrates against DSR).
        uint256 dsr = pot.dsr();
        IAavePool.ReserveDataLegacy memory daiRes = spark.getReserveData(Mainnet.DAI);
        emit log_named_uint("dsr_ray_per_sec", dsr);
        emit log_named_uint("spark_dai_var_rate_ray", daiRes.currentVariableBorrowRate);

        // ---- 1. WETH -> rETH (real swap on Balancer; ~1% of pool, tiny slippage) ----
        uint256 rEthOut = _swap(Mainnet.WETH, Mainnet.RETH, principal);
        assertGt(rEthOut, 0, "rETH swap: zero amount");

        // ---- 2. Supply rETH to Spark ----
        // Sanity: confirm Spark has rETH listed (has a non-zero aToken).
        IAavePool.ReserveDataLegacy memory rethRes = spark.getReserveData(Mainnet.RETH);
        require(rethRes.aTokenAddress != address(0), "Spark has no rETH reserve at fork");

        IERC20(Mainnet.RETH).approve(Mainnet.SPARK_POOL, type(uint256).max);
        spark.supply(Mainnet.RETH, rEthOut, address(this), 0);

        // ---- 3. Borrow DAI at conservative LTV ----
        (, , uint256 availBorrowsBase, , , ) = spark.getUserAccountData(address(this));
        // availBorrowsBase is 1e8 USD; DAI is 1e18 and ~$1.
        uint256 maxBorrowDai = availBorrowsBase * 1e10;
        uint256 borrowDai = (maxBorrowDai * BORROW_LTV_BPS) / 10_000;
        require(borrowDai > 1e21, "borrowDai too small");

        spark.borrow(Mainnet.DAI, borrowDai, RATE_MODE_VARIABLE, 0, address(this));
        uint256 daiHere = IERC20(Mainnet.DAI).balanceOf(address(this));
        assertEq(daiHere, borrowDai, "spark did not return expected DAI");

        // ---- 4. Deposit borrowed DAI into sDAI (DSR carry) ----
        IERC20(Mainnet.DAI).approve(address(sdai), type(uint256).max);
        uint256 sdaiShares = sdai.deposit(daiHere, address(this));
        assertGt(sdaiShares, 0, "sDAI deposit returned 0 shares");

        // ---- 5. Park 30 days ----
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));
        // Crystallise sDAI chi by dripping DSR.
        pot.drip();
        // Crystallise Spark indices via a 1-wei rETH touch supply.
        deal(Mainnet.RETH, address(this), 1);
        IERC20(Mainnet.RETH).approve(Mainnet.SPARK_POOL, type(uint256).max);
        deal(Mainnet.RETH, address(this), 1);
        spark.supply(Mainnet.RETH, 1, address(this), 0);

        // ---- 6. Read final state for logging ----
        (uint256 collBaseF, uint256 debtBaseF, , , , uint256 hfF) =
            spark.getUserAccountData(address(this));
        uint256 sdaiAssetsAfter = sdai.convertToAssets(IERC20(Mainnet.SDAI).balanceOf(address(this)));
        uint256 rEthRateFinal = IRETH(Mainnet.RETH).getExchangeRate();
        emit log_named_uint("collateral_base_e8_usd", collBaseF);
        emit log_named_uint("debt_base_e8_usd", debtBaseF);
        emit log_named_uint("hf_e18", hfF);
        emit log_named_uint("sdai_value_after_in_dai", sdaiAssetsAfter);
        emit log_named_uint("rETH_exchange_rate_e18", rEthRateFinal);

        // ---- 7. Unwind to tracked tokens for an honest round-trip PnL ----
        // The rETH collateral and DAI debt live inside Spark and are invisible to
        // StrategyBase's balance accounting; without unwinding, net_usd would just
        // read -principal. Redeem sDAI, repay the DAI debt (topping up the small
        // borrow-vs-DSR shortfall from collateral), withdraw all rETH, swap back to
        // WETH. Everything then lands in tracked balances, so net_usd is the true
        // result (entry+exit swap fees + Spark borrow interest - rETH yield - DSR).
        sdai.redeem(IERC20(Mainnet.SDAI).balanceOf(address(this)), address(this), address(this));

        address vDebtDai = spark.getReserveData(Mainnet.DAI).variableDebtTokenAddress;
        IERC20(Mainnet.DAI).approve(Mainnet.SPARK_POOL, type(uint256).max);
        // Repay as much as the sDAI proceeds cover (caps to debt if we have extra).
        spark.repay(Mainnet.DAI, IERC20(Mainnet.DAI).balanceOf(address(this)), RATE_MODE_VARIABLE, address(this));

        // Spark borrow rate slightly exceeds the DSR, so the sDAI proceeds fall a
        // little short of the debt. Free a small slice of collateral, convert just
        // enough WETH->DAI to cover the shortfall, and clear the debt. (Aave's
        // withdraw(max) reverts while ANY debt remains, so we must zero it first.)
        uint256 residual = IERC20(vDebtDai).balanceOf(address(this));
        if (residual > 0) {
            spark.withdraw(Mainnet.RETH, 2 ether, address(this)); // tiny vs ~90 rETH; HF stays high
            _swap(Mainnet.RETH, Mainnet.WETH, IERC20(Mainnet.RETH).balanceOf(address(this)));
            IERC20(Mainnet.WETH).approve(Mainnet.UNI_V3_ROUTER, type(uint256).max);
            IUniswapV3Router(Mainnet.UNI_V3_ROUTER).exactOutputSingle(
                IUniswapV3Router.ExactOutputSingleParams({
                    tokenIn: Mainnet.WETH,
                    tokenOut: Mainnet.DAI,
                    fee: UNIV3_DAI_WETH_FEE,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountOut: residual + 1e18, // +1 DAI margin for interest accrued during the tx
                    amountInMaximum: type(uint256).max,
                    sqrtPriceLimitX96: 0
                })
            );
            spark.repay(Mainnet.DAI, type(uint256).max, RATE_MODE_VARIABLE, address(this));
        }

        // Debt is now zero: withdraw all rETH and swap back to WETH.
        spark.withdraw(Mainnet.RETH, type(uint256).max, address(this));
        uint256 rBal = IERC20(Mainnet.RETH).balanceOf(address(this));
        if (rBal > 1) _swap(Mainnet.RETH, Mainnet.WETH, rBal);

        _endPnL("F01-07: rETH Spark DAI -> sDAI DSR carry (round-trip)");
    }

    /// @dev rETH<->WETH single swap on the Balancer MetaStable pool, GIVEN_IN.
    function _swap(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256) {
        IERC20(tokenIn).approve(Mainnet.BAL_VAULT, amountIn);
        IBalancerVault.SingleSwap memory ss = IBalancerVault.SingleSwap({
            poolId: BAL_RETH_WETH_POOL_ID,
            kind: IBalancerVault.SwapKind.GIVEN_IN,
            assetIn: tokenIn,
            assetOut: tokenOut,
            amount: amountIn,
            userData: ""
        });
        IBalancerVault.FundManagement memory fm = IBalancerVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });
        // minOut 0: this is a measurement PoC and the realised price IS the result
        // we want to surface; the Balancer pool itself protects against zero-out.
        return IBalancerVault(Mainnet.BAL_VAULT).swap(ss, fm, 0, block.timestamp);
    }
}
