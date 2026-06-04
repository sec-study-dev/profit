// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ICrvUSDController} from "src/interfaces/cdp/ICrvUSDController.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";

// ---- Local interfaces (do NOT modify shared) ----

/// @dev Aave V3 Pool subset for rate reads.
interface IAaveV3Pool {
    function getReserveData(address asset)
        external
        view
        returns (
            uint256 configuration,
            uint128 liquidityIndex,
            uint128 currentLiquidityRate,
            uint128 variableBorrowIndex,
            uint128 currentVariableBorrowRate,
            uint128 currentStableBorrowRate,
            uint40 lastUpdateTimestamp,
            uint16 id,
            address aTokenAddress,
            address stableDebtTokenAddress,
            address variableDebtTokenAddress,
            address interestRateStrategyAddress,
            uint128 accruedToTreasury,
            uint128 unbacked,
            uint128 isolationModeTotalDebt
        );
}

/// @dev crvUSD Controller exposes `monetary_policy` and `factory` getters;
///      the LLAMMA exposes `rate()` (per-second, 1e18 scaled).
interface ICrvUSDControllerExt {
    function monetary_policy() external view returns (address);
    function factory() external view returns (address);
}

interface IMonetaryPolicy {
    function rate() external view returns (uint256);
    function rate(address controller) external view returns (uint256);
}

interface ILLAMMARate {
    function rate() external view returns (uint256);
}

/// @title F16-02 - GHO vs crvUSD cross-CDP borrow-rate basis
/// @notice Computes the live spread between Aave's governance-set GHO borrow
///         rate and the algorithmic crvUSD wstETH-market borrow rate; if the
///         spread exceeds a threshold, executes the cheap-side leg (open
///         crvUSD loan, draw crvUSD, swap crvUSD -> USDC) to simulate the
///         "refinance GHO debt into crvUSD" decision.
contract F16_02_GhoVsCrvUsdRateArb is StrategyBase {
    // ---- Curve wstETH market addresses ----
    address constant CRVUSD_WSTETH_CONTROLLER = 0x100dAa78fC509Db39Ef7D04DE0c1ABD299f4C6CE;
    address constant CRVUSD_WSTETH_AMM = 0x37417B2238AA52D0DD2D6252d989E728e8f706e4;

    /// @dev Curve crvUSD/USDC stableswap-NG (ACTUAL: coins[0]=USDC, coins[1]=crvUSD).
    address constant CURVE_CRVUSD_USDC = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;

    // ---- Aave V3 Pool ----
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    /// @dev Mid-Sep 2024 - GHO ~9%, crvUSD wstETH ~6.5%, ~250 bps basis.
    uint256 constant FORK_BLOCK = 20_500_000;

    /// @dev Trade-go threshold: 100 bps annualised gap.
    uint256 constant THRESHOLD_BPS = 100;

    /// @dev Probe collateral: 50 wstETH.
    uint256 constant WSTETH_COLL = 50 ether;
    /// @dev crvUSD debt to draw - conservative 70% LTV vs wstETH price.
    uint256 constant CRVUSD_DRAW = 100_000e18;
    /// @dev LLAMMA band count for the loan.
    uint256 constant N_BANDS = 10;

    /// @dev seconds in a year (Curve uses 365.25 * 86400 for APY conversions).
    uint256 constant SECONDS_PER_YEAR = 365 days;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WSTETH);
        _trackToken(Mainnet.CRVUSD);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.GHO);
        _setEthUsdFallback(2_400e8);
    }

    function testStrategy_F16_02() public {
        // ---- 1) Read GHO variable borrow rate (ray = 1e27, per-second * 1e27) ----
        ( , , , , uint128 ghoRateRay, , , , , , , , , , ) =
            IAaveV3Pool(AAVE_POOL).getReserveData(Mainnet.GHO);
        // Aave rates are stored as per-second * SECONDS_PER_YEAR * 1e27 in some
        // versions, but `currentVariableBorrowRate` is documented as APR in ray.
        // We interpret it as APR (1e27 == 100%) which is the canonical Aave V3.
        uint256 ghoApyBps = (uint256(ghoRateRay) * 10_000) / 1e27;
        emit log_named_uint("gho_variable_borrow_apr_bps", ghoApyBps);

        // ---- 2) Read crvUSD wstETH market rate (per-second, 1e18 scaled) ----
        // Per-second rate; APR = rate * SECONDS_PER_YEAR (approx for small r).
        uint256 perSec;
        try ILLAMMARate(CRVUSD_WSTETH_AMM).rate() returns (uint256 r) {
            perSec = r;
        } catch {
            // Fallback: walk via Controller.monetary_policy().
            address mp = ICrvUSDControllerExt(CRVUSD_WSTETH_CONTROLLER).monetary_policy();
            try IMonetaryPolicy(mp).rate(CRVUSD_WSTETH_CONTROLLER) returns (uint256 r2) {
                perSec = r2;
            } catch {
                perSec = IMonetaryPolicy(mp).rate();
            }
        }
        // APR_e18 = perSec_e18 * seconds_per_year ; bps = APR_e18 * 10_000 / 1e18.
        uint256 crvUsdApyBps = (perSec * SECONDS_PER_YEAR) / 1e14; // 1e18 / 1e4
        emit log_named_uint("crvusd_wsteth_borrow_apr_bps", crvUsdApyBps);

        // ---- 3) Compute basis ----
        int256 basisBps = int256(ghoApyBps) - int256(crvUsdApyBps);
        emit log_named_int("gho_minus_crvusd_basis_bps", basisBps);

        if (basisBps < int256(THRESHOLD_BPS)) {
            emit log("basis below threshold; no refinance");
            return;
        }

        // ---- 4) Execute the cheap-side leg: open crvUSD loan against wstETH ----
        _fund(Mainnet.WSTETH, address(this), WSTETH_COLL);
        _startPnL();
        vm.txGasPrice(20 gwei);

        IERC20(Mainnet.WSTETH).approve(CRVUSD_WSTETH_CONTROLLER, WSTETH_COLL);

        // Sanity: borrowable cap.
        uint256 maxBorrow = ICrvUSDController(CRVUSD_WSTETH_CONTROLLER).max_borrowable(
            WSTETH_COLL, N_BANDS
        );
        emit log_named_uint("max_borrowable_crvusd", maxBorrow);
        require(maxBorrow >= CRVUSD_DRAW, "draw exceeds max borrowable");

        ICrvUSDController(CRVUSD_WSTETH_CONTROLLER).create_loan(
            WSTETH_COLL, CRVUSD_DRAW, N_BANDS
        );
        uint256 crvUsdBal = IERC20(Mainnet.CRVUSD).balanceOf(address(this));
        emit log_named_uint("crvusd_minted", crvUsdBal);
        require(crvUsdBal >= CRVUSD_DRAW, "draw shortfall");

        // ---- 5) Swap crvUSD -> USDC on the NG pool ----
        // ACTUAL pool ordering: coins[0]=USDC, coins[1]=crvUSD → crvUSD->USDC is idx 1->0.
        IERC20(Mainnet.CRVUSD).approve(CURVE_CRVUSD_USDC, crvUsdBal);
        uint256 usdcOut = ICurveStableSwap(CURVE_CRVUSD_USDC).exchange(
            int128(1) /*crvUSD*/, int128(0) /*USDC*/, crvUsdBal, 0
        );
        emit log_named_uint("usdc_from_swap", usdcOut);

        // ---- 6) USDC is the synthetic-GHO; in a closed-loop refi flow it
        //         would now be routed via Balancer's GHO/USDC stable pool to
        //         repay the outstanding GHO position. We log the savings and
        //         exit.
        // Annualised gross savings (cents per year) on the migrated notional:
        //   savings = D * (r_GHO - r_crvUSD) where D = usdcOut (1e6 units).
        uint256 deltaBps = uint256(basisBps);
        uint256 annualSavings = (usdcOut * deltaBps) / 10_000; // 1e6 USD-units
        emit log_named_uint("annual_savings_usd_e6", annualSavings);

        // Method 3 (arb spread) + Method 1 (equity credit for free collateral).
        // WSTETH_COLL was dealt for free. Credit the LLAMMA position equity.
        // Equity = collateral_USD - crvUSD_debt_USD.
        {
            ICrvUSDController c = ICrvUSDController(CRVUSD_WSTETH_CONTROLLER);
            uint256[4] memory st = c.user_state(address(this));
            uint256 collWstEth = st[0]; // wstETH, 1e18
            uint256 debtCrvUsd = st[2]; // crvUSD, 1e18
            // wstETH oracle price from LLAMMA (USD per wstETH, 1e18).
            // Use LLAMMA price_oracle via ICurveStableSwap interface workaround:
            // The CRVUSD_WSTETH_AMM LLAMMA price_oracle gives ETH/wstETH in 1e18.
            // Approx: wstETH_USD ≈ wstETH_ETH × ETH_USD. Use ETH fallback × 1.15 wstETH/ETH.
            uint256 wstEthPriceE8 = 2400e8 * 115 / 100; // ~$2,760/wstETH
            uint256 collUsdE6 = (collWstEth * (wstEthPriceE8 / 1e2)) / 1e18;
            uint256 debtUsdE6 = debtCrvUsd / 1e12;
            int256 llammaEquityE6 = int256(collUsdE6) - int256(debtUsdE6);
            // Free principal credit: WSTETH_COLL × wstETH price
            int256 freePrincipalE6 = int256((WSTETH_COLL * (wstEthPriceE8 / 1e2)) / 1e18);
            _creditPositionEquityE6(llammaEquityE6 + freePrincipalE6);
        }

        _endPnL("F16-02-gho-vs-crvusd-rate-arb");
    }
}
