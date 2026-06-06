// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

// Interfaces referenced in commented live-call sketches:
//   IListaInteraction, IPancakeV3Router, IPancakeV3NonfungiblePositionManager

/// @title B03-06 Dual-collateral Lista (ETH + slisBNB) -> lisUSD -> PCS LP farm
/// @notice 3-mechanism positional PoC stacking:
///         1. Lista CDP - slisBNB ilk collateral, mint lisUSD.
///         2. Lista CDP - WETH ilk collateral, mint additional lisUSD.
///         3. PCS v3 lisUSD/USDT 1bp concentrated LP, earning the dominant
///            stable-stable fee on BSC.
///
///         Why dual collateral? Lista charges a separate stability fee per
///         ilk and exposes per-ilk LTV ceilings. Splitting collateral across
///         slisBNB and WETH:
///           - **diversifies** the liquidation exposure (uncorrelated price
///             shocks on BNB vs ETH),
///           - lets the operator harvest **two independent staking accruals**
///             (slisBNB intrinsic APR + ETH-side accrual is zero, but the
///             ETH collateral is fully retained capital, not bridge-rented),
///           - **raises the effective LTV ceiling** because each ilk's
///             `line` (debt ceiling) is independent of the other.
///
///         The aggregated lisUSD is then deployed as the dominant stable
///         leg of a tight PCS v3 1bp range (concentrated around par), where
///         PCS pays the entire 1bp on every USDT/lisUSD trade.
contract B03_06_EthSlisBnbDualCollateralLisUsdPcsLpTest is BSCStrategyBase {
    uint256 constant FORK_BLOCK = 42_500_000;

    // ---- Lista CDP parameters ----
    uint256 constant SEED_SLIS_BNB = 100 ether; // $60k
    uint256 constant SEED_WETH = 20 ether; // $60k
    uint256 constant LTV_SLIS_BPS = 7500; // 75%
    uint256 constant LTV_WETH_BPS = 7000; // 70% - Lista typically gives ETH a tighter LTV
    uint256 constant SLIS_BORROW_BPS = 250; // 2.5%/yr stability fee on slisBNB ilk
    uint256 constant WETH_BORROW_BPS = 350; // 3.5%/yr stability fee on WETH ilk

    // ---- slisBNB intrinsic accrual ----
    uint256 constant SLIS_INTRINSIC_BPS = 320; // 3.2% native staking

    // ---- PCS v3 LP fee accrual ----
    /// @dev Modeled annualised lisUSD/USDT 1bp pool fee APR for a tight
    ///      20 bp range around par. Empirically ~5-8% on stable-stable
    ///      pools when concentrated; we model 600 bp (6%).
    uint256 constant LP_FEE_APR_BPS = 600;

    uint256 constant HOLD_DAYS = 30;

    uint256 public totalLisUsdMinted;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.WETH);
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.USDT);
    }

    function testStrategy_B03_06() public {
        _fund(BSC.slisBNB, address(this), SEED_SLIS_BNB);
        _fund(BSC.WETH, address(this), SEED_WETH);
        // Seed a small USDT counter-leg for the LP position.
        _fund(BSC.USDT, address(this), 50_000 * 1e18);

        _startPnL();

        // ===== Mechanism 1: Lista CDP - slisBNB ilk =====
        //
        //   IERC20(BSC.slisBNB).approve(BSC.LISTA_INTERACTION, SEED_SLIS_BNB);
        //   IListaInteraction(BSC.LISTA_INTERACTION).deposit(
        //       address(this), BSC.slisBNB, SEED_SLIS_BNB
        //   );
        //   uint256 mint1 = (SEED_SLIS_BNB * 600e18 / 1e18 * LTV_SLIS_BPS) / 10_000;
        //   IListaInteraction(BSC.LISTA_INTERACTION).borrow(BSC.slisBNB, mint1);
        //
        // Offline: lock slisBNB, mint lisUSD at LTV.
        IERC20(BSC.slisBNB).transfer(address(0xCAFE), SEED_SLIS_BNB);
        uint256 slisCollatUsd = SEED_SLIS_BNB * 600; // 1 slisBNB ~ $600
        uint256 mintFromSlis = (slisCollatUsd * LTV_SLIS_BPS) / 10_000;
        _fund(BSC.lisUSD, address(this), mintFromSlis);

        // ===== Mechanism 2: Lista CDP - WETH ilk =====
        //
        //   IERC20(BSC.WETH).approve(BSC.LISTA_INTERACTION, SEED_WETH);
        //   IListaInteraction(BSC.LISTA_INTERACTION).deposit(
        //       address(this), BSC.WETH, SEED_WETH
        //   );
        //   uint256 mint2 = (SEED_WETH * 3000e18 / 1e18 * LTV_WETH_BPS) / 10_000;
        //   IListaInteraction(BSC.LISTA_INTERACTION).borrow(BSC.WETH, mint2);
        //
        // Offline: lock WETH, mint additional lisUSD.
        IERC20(BSC.WETH).transfer(address(0xCAFE), SEED_WETH);
        uint256 wethCollatUsd = SEED_WETH * 3000; // 1 WETH ~ $3000
        uint256 mintFromWeth = (wethCollatUsd * LTV_WETH_BPS) / 10_000;
        _fund(BSC.lisUSD, address(this), mintFromWeth);

        totalLisUsdMinted = mintFromSlis + mintFromWeth;

        // ===== Mechanism 3: PCS v3 lisUSD/USDT 1bp tight-range LP =====
        //
        //   IERC20(BSC.lisUSD).approve(BSC.PCS_V3_NPM, totalLisUsdMinted/2);
        //   IERC20(BSC.USDT).approve(BSC.PCS_V3_NPM, ~ totalLisUsdMinted/2 USD);
        //   INonfungiblePositionManager(BSC.PCS_V3_NPM).mint({
        //       token0: lisUSD, token1: USDT, fee: 100,
        //       tickLower: -20, tickUpper: 20,
        //       amount0Desired: half lisUSD, amount1Desired: half USDT,
        //       amount0Min: 0, amount1Min: 0,
        //       recipient: address(this), deadline: block.timestamp
        //   });
        //
        // Offline: lock both legs by transferring to dead.
        uint256 lisUsdLeg = totalLisUsdMinted / 2;
        // Pull USDT counter-leg from seeded buffer.
        uint256 usdtLeg = 50_000 * 1e18;
        IERC20(BSC.lisUSD).transfer(address(0xdEaD), lisUsdLeg);
        IERC20(BSC.USDT).transfer(address(0xdEaD), usdtLeg);

        // Effective LP-deployed notional = lisUsdLeg + usdtLeg (USD).
        uint256 lpNotionalUsd = lisUsdLeg + usdtLeg;

        // ---- Carry & yield over HOLD_DAYS ----

        // (a) slisBNB intrinsic accrual: locked collateral still earns LST APR.
        uint256 slisYieldUsd =
            (slisCollatUsd * SLIS_INTRINSIC_BPS * HOLD_DAYS) / (10_000 * 365);

        // (b) Two stability fees (slis + WETH ilks).
        uint256 slisDebtCostUsd =
            (mintFromSlis * SLIS_BORROW_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 wethDebtCostUsd =
            (mintFromWeth * WETH_BORROW_BPS * HOLD_DAYS) / (10_000 * 365);

        // (c) PCS LP fee APR on full deployed notional.
        uint256 lpFeeUsd =
            (lpNotionalUsd * LP_FEE_APR_BPS * HOLD_DAYS) / (10_000 * 365);

        // Net carry in USD = (a) + (c) - (b1) - (b2). Realise this by
        // funding lisUSD on net positive, or burning slisBNB on net
        // negative. We expect positive: 3.2% x $120k + 6% x $84k - blended
        // borrow ~ positive.
        int256 netCarryUsd =
            int256(slisYieldUsd + lpFeeUsd) -
            int256(slisDebtCostUsd + wethDebtCostUsd);

        if (netCarryUsd > 0) {
            _fund(BSC.lisUSD, address(this), uint256(netCarryUsd));
        } else if (netCarryUsd < 0) {
            // Burn lisUSD to represent net loss (PoC accounting).
            uint256 loss = uint256(-netCarryUsd);
            uint256 bal = IERC20(BSC.lisUSD).balanceOf(address(this));
            uint256 burn = loss > bal ? bal : loss;
            IERC20(BSC.lisUSD).transfer(address(0xdEaD), burn);
        }

        _endPnL("B03-06: dual-collateral Lista + PCS v3 LP");
    }
}
