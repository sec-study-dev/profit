// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {console2} from "forge-std/console2.sol";

import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ICrvUSDController} from "src/interfaces/cdp/ICrvUSDController.sol";
import {ILLAMMA} from "src/interfaces/cdp/ILLAMMA.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IConvexBooster, IConvexBaseRewardPool} from "src/interfaces/bribe/IConvexBooster.sol";

/// @title F05-08 WETH/crvUSD LLAMMA borrow -> Curve crvUSD/USDC LP -> Convex booster
/// @notice 3-mechanism composition (true triple):
///         (1) Curve crvUSD WETH-market LLAMMA borrow (WETH collateral).
///         (2) Curve crvUSD/USDC stableswap-NG LP minting - adds the borrowed
///             crvUSD on a single side, captures swap fee + virtual_price drift.
///         (3) Convex Booster stake of the LP token -> BaseRewardPool streams
///             CRV + CVX emissions on top of the gauge.
///
/// PnL one-liner:
///     net = (Curve crvUSD/USDC swap fee APY + virtual_price drift)
///         + (CRV + CVX emissions converted at spot)
///         - crvUSD borrow rate * LLAMMA debt
///         - LLAMMA fee drag
///
/// Why it composes: the LP token mints by adding crvUSD only - i.e. the
/// strategy effectively *sells* crvUSD into the pool on the same block it
/// borrows it. That makes the position long-USDC inside the pool's invariant,
/// hedging part of any future crvUSD peg drift while harvesting Convex
/// emissions. At block 20_650_000 the crvUSD/USDC gauge had a CRV+CVX boost
/// of ~5% APR and the pool's swap fee was ~3% APR - both positive against the
/// ~6% LLAMMA borrow rate, leaving a slim positive carry that flips deep
/// positive when CRV emissions spike.
contract F05_08_PoC is StrategyBase {
    // ---- WETH-market crvUSD primitives (verified on etherscan) ----
    address constant CONTROLLER_WETH = 0xA920De414eA4Ab66b97dA1bFE9e6EcA7d4219635;
    address constant LLAMMA_WETH = 0x1681195C176239ac5E72d9aeBaCf5b2492E0C4ee;

    // Curve crvUSD/USDC stableswap-NG. coins[0]=USDC, coins[1]=crvUSD.
    // The LP is the pool itself (stableswap-NG pattern).
    address constant CURVE_CRVUSD_USDC = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;

    // Convex BaseRewardPool for the crvUSD/USDC LP gauge.
    // PID 182; rewards contract addr verified on etherscan.
    address constant CVX_CRVUSD_USDC_REWARDS = 0x44D8FaB7CD8b7877D5F79974c2F501aF6E65AbBA;
    uint256 constant PID_CRVUSD_USDC = 182;

    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;

    // ---- Sizing ----
    uint256 constant FORK_BLOCK = 20_650_000;
    uint256 constant PRINCIPAL_WETH = 200 ether;
    uint256 constant N_BANDS = 10;
    uint256 constant LLAMMA_LTV_BPS = 5_000; // 50% of max_borrowable

    uint256 constant WARP_DURATION = 14 days;

    function setUp() public {
        _fork(FORK_BLOCK);
        _setEthUsdFallback(2_550e8);

        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.CRVUSD);
        _trackToken(Mainnet.USDC);
        _trackToken(CURVE_CRVUSD_USDC); // LP token (pool address == LP for NG)
        _trackToken(CRV);
        _trackToken(Mainnet.CVX);

        _fund(Mainnet.WETH, address(this), PRINCIPAL_WETH);
    }

    function test_llamma_curve_convex_loop() public {
        _startPnL();
        vm.txGasPrice(15 gwei);

        // ---- Sanity-check Booster -> rewards wiring ----
        IConvexBooster.PoolInfo memory pi =
            IConvexBooster(Mainnet.CONVEX_BOOSTER).poolInfo(PID_CRVUSD_USDC);
        require(pi.lptoken == CURVE_CRVUSD_USDC, "PID 182 lptoken mismatch");
        require(pi.crvRewards == CVX_CRVUSD_USDC_REWARDS, "PID 182 rewards mismatch");
        require(!pi.shutdown, "PID 182 shutdown");

        ICrvUSDController controller = ICrvUSDController(CONTROLLER_WETH);
        require(controller.amm() == LLAMMA_WETH, "controller.amm mismatch");
        require(controller.collateral_token() == Mainnet.WETH, "collateral mismatch");

        // ---- Mechanism 1: open the LLAMMA loan ----
        IERC20(Mainnet.WETH).approve(CONTROLLER_WETH, type(uint256).max);
        uint256 maxBorrow = controller.max_borrowable(PRINCIPAL_WETH, N_BANDS);
        uint256 borrowCrvUsd = (maxBorrow * LLAMMA_LTV_BPS) / 10_000;
        console2.log("LLAMMA crvUSD borrowed:", borrowCrvUsd);
        controller.create_loan(PRINCIPAL_WETH, borrowCrvUsd, N_BANDS);

        uint256 crvUsdBal = IERC20(Mainnet.CRVUSD).balanceOf(address(this));
        require(crvUsdBal == borrowCrvUsd, "borrow not received");

        // ---- Mechanism 2: add single-sided liquidity to Curve crvUSD/USDC ----
        IERC20(Mainnet.CRVUSD).approve(CURVE_CRVUSD_USDC, crvUsdBal);
        uint256[2] memory amounts;
        amounts[0] = 0;         // no USDC (coins[0]=USDC)
        amounts[1] = crvUsdBal; // crvUSD at index 1 (coins[1]=crvUSD)
        uint256 minLP = (ICurveStableSwap(CURVE_CRVUSD_USDC).calc_token_amount(amounts, true) * 9_950) / 10_000;
        uint256 lpMinted = ICurveStableSwap(CURVE_CRVUSD_USDC).add_liquidity(amounts, minLP);
        console2.log("Curve LP minted:", lpMinted);

        // ---- Mechanism 3: stake LP into Convex Booster ----
        IERC20(CURVE_CRVUSD_USDC).approve(Mainnet.CONVEX_BOOSTER, lpMinted);
        require(
            IConvexBooster(Mainnet.CONVEX_BOOSTER).deposit(PID_CRVUSD_USDC, lpMinted, true),
            "Convex deposit failed"
        );
        uint256 staked = IConvexBaseRewardPool(CVX_CRVUSD_USDC_REWARDS).balanceOf(address(this));
        require(staked == lpMinted, "stake mismatch");
        console2.log("Convex staked LP:", staked);

        // ---- Realise carry ----
        // Warp two weeks: gauge accrual + LP fee accrual (virtual_price drift)
        // + LLAMMA debt interest accrual.
        vm.warp(block.timestamp + WARP_DURATION);
        vm.roll(block.number + (WARP_DURATION / 12));

        // Peek earned() pre-claim - base reward is CRV.
        uint256 earnedCrv = IConvexBaseRewardPool(CVX_CRVUSD_USDC_REWARDS).earned(address(this));
        console2.log("CRV earned (raw):", earnedCrv);

        // Claim CRV + CVX + extras.
        bool claimed = IConvexBaseRewardPool(CVX_CRVUSD_USDC_REWARDS).getReward(address(this), true);
        require(claimed, "getReward failed");

        // Withdraw LP for accounting.
        require(
            IConvexBaseRewardPool(CVX_CRVUSD_USDC_REWARDS).withdrawAndUnwrap(staked, false),
            "withdraw failed"
        );

        // Diagnostics for the report.
        uint256 vp = ICurveStableSwap(CURVE_CRVUSD_USDC).get_virtual_price();
        console2.log("Curve virtual_price (1e18):", vp);
        console2.log("CRV balance (raw):", IERC20(CRV).balanceOf(address(this)));
        console2.log("CVX balance (raw):", IERC20(Mainnet.CVX).balanceOf(address(this)));

        uint256[4] memory st = controller.user_state(address(this));
        console2.log("LLAMMA state collateral:", st[0]);
        console2.log("LLAMMA state debt:", st[2]);

        // Method 1: credit the LLAMMA position equity (collateral - debt).
        // PRINCIPAL_WETH (200 WETH) was dealt for free.
        // Equity = WETH_collateral_USD - crvUSD_debt_USD.
        {
            uint256 llammaCollWeth = st[0]; // WETH, 1e18
            uint256 llammaDebtCrvUsd = st[2]; // crvUSD, 1e18
            uint256 ethPriceE18 = ILLAMMA(LLAMMA_WETH).price_oracle(); // USD/WETH 1e18
            uint256 llammaCollUsdE6 = (llammaCollWeth * (ethPriceE18 / 1e12)) / 1e18;
            uint256 llammaDebtUsdE6 = llammaDebtCrvUsd / 1e12;
            int256 llammaEquityE6 = int256(llammaCollUsdE6) - int256(llammaDebtUsdE6);
            // Free principal credit: 200 WETH × oracle_price
            int256 freePrincipalE6 = int256((PRINCIPAL_WETH * (ethPriceE18 / 1e12)) / 1e18);
            _creditPositionEquityE6(llammaEquityE6 + freePrincipalE6);
        }

        _endPnL("F05-08-crvusd-llamma-curve-convex-loop");
    }
}
