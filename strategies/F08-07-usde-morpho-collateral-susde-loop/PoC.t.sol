// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ISUSDe} from "src/interfaces/stable/ISUSDe.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "src/interfaces/common/IFlashLoanReceiver.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";

/// @title F08-07 - USDe-collateral Morpho loop, sUSDe held off-Morpho (3-mech)
/// @notice **Three-mechanism composition** distinct from F08-01:
///         - F08-01 puts sUSDe as collateral; collateral grows with NAV.
///         - F08-07 puts USDe as collateral (flat ~$1) and holds sUSDe in the
///           wallet (off-Morpho). The leverage is *pure liquidity leverage*;
///           the yield accrues to the off-Morpho sUSDe bag which is never
///           marked by the Morpho oracle.
///
///         Why is this useful?
///         - Liquidation threshold is decoupled from sUSDe NAV variance -
///           a sUSDe oracle hiccup cannot trigger liquidation because no
///           sUSDe is collateral.
///         - The off-Morpho sUSDe is *withdrawable on demand* (via cooldown
///           or AMM) without unwinding the Morpho leverage, which gives the
///           operator independent control over the yield sleeve.
///
///         Mechanisms stacked:
///         1. **Morpho Blue** USDe/USDC isolated market (collateral leg) plus
///            Morpho **free flashloan** for atomic bootstrap.
///         2. **Curve USDe/USDC** for the USDC->USDe surrogate-mint conversion
///            (Ethena mint requires off-chain RFQ; same rationale as F08-01).
///         3. **Ethena sUSDe** ERC-4626 stake - the yield-bearing receipt that
///            holds the accrual sleeve outside the lending venue.
contract F08_07_UsdeMorphoCollateralSusdeLoopTest is StrategyBase, IMorphoFlashLoanCallback {
    // ---- Pinned constants ----

    /// @dev Block 20,800,000 (~Sep 2024). Morpho USDe/USDC market live with
    ///      LLTV 86% (USDe non-rebasing is treated as a regular collateral).
    uint256 constant FORK_BLOCK = 20_800_000;

    /// @dev Curve USDe/USDC pool (coin 0 = USDe, coin 1 = USDC).
    address constant LOCAL_CURVE_USDE_USDC = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72;

    /// @dev Morpho USDe/USDC 86% LLTV market.
    ///      Oracle: a USDe price oracle (typically Chainlink USDe/USD or
    ///      Redstone aggregator). IRM: Morpho's canonical AdaptiveCurve.
    ///      We construct the MarketParams locally and confirm via
    ///      idToMarketParams; if Morpho returns the zero-struct, the market
    ///      does not exist at the fork block and we surface a clear revert.
    address constant LOCAL_MORPHO_ORACLE_USDE_USDC =
        0xaE4750d0813B5E37A51f7629beedd72AF1f9cA35;
    address constant LOCAL_MORPHO_IRM_ADAPTIVE_CURVE =
        0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 constant LLTV_86 = 0.86e18;

    /// @dev Initial equity in USDe (we accumulate sUSDe entirely from the loop).
    uint256 constant EQUITY_USDE = 1_000_000e18; // 1M USDe

    /// @dev Morpho flashloan to bootstrap the loop in a single tx.
    uint256 constant FLASH_USDE = 4_000_000e18; // 4M USDe (5x notional total)

    IMorpho.MarketParams internal _market;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.USDE);
        _trackToken(Mainnet.SUSDE);
        _trackToken(Mainnet.USDC);

        require(
            ICurveStableSwap(LOCAL_CURVE_USDE_USDC).coins(0) == Mainnet.USDE,
            "F08-07: curve coin0 != USDe"
        );
        require(
            ICurveStableSwap(LOCAL_CURVE_USDE_USDC).coins(1) == Mainnet.USDC,
            "F08-07: curve coin1 != USDC"
        );

        _market = IMorpho.MarketParams({
            loanToken: Mainnet.USDC,
            collateralToken: Mainnet.USDE,
            oracle: LOCAL_MORPHO_ORACLE_USDE_USDC,
            irm: LOCAL_MORPHO_IRM_ADAPTIVE_CURVE,
            lltv: LLTV_86
        });

        // Confirm the market exists at the fork block by recovering via id.
        bytes32 mid = keccak256(abi.encode(_market));
        IMorpho.MarketParams memory onchain = IMorpho(Mainnet.MORPHO).idToMarketParams(mid);
        require(onchain.loanToken == Mainnet.USDC, "F08-07: USDe/USDC market missing at fork block");
    }

    function testStrategy_F08_07() public {
        _fund(Mainnet.USDE, address(this), EQUITY_USDE);
        _startPnL();

        // Approvals.
        IERC20(Mainnet.USDE).approve(Mainnet.MORPHO, type(uint256).max);
        IERC20(Mainnet.USDE).approve(Mainnet.SUSDE, type(uint256).max);
        IERC20(Mainnet.USDE).approve(LOCAL_CURVE_USDE_USDC, type(uint256).max);
        IERC20(Mainnet.USDC).approve(LOCAL_CURVE_USDE_USDC, type(uint256).max);
        IERC20(Mainnet.USDC).approve(Mainnet.MORPHO, type(uint256).max);

        // Morpho flashloan in USDe - bootstraps the entire position atomically.
        IMorpho(Mainnet.MORPHO).flashLoan(Mainnet.USDE, FLASH_USDE, abi.encode("usde-loop"));

        // ---- Post-flash state surface ----
        bytes32 mid = keccak256(abi.encode(_market));
        IMorpho.Position memory pos = IMorpho(Mainnet.MORPHO).position(mid, address(this));
        IMorpho.Market memory mkt = IMorpho(Mainnet.MORPHO).market(mid);

        uint256 usdcDebt = mkt.totalBorrowShares == 0
            ? 0
            : (uint256(pos.borrowShares) * uint256(mkt.totalBorrowAssets)) / uint256(mkt.totalBorrowShares);

        // Equity = USDe collateral - USDC debt (1:1 stable) + sUSDe NAV (in USDe).
        uint256 susdeBal = IERC20(Mainnet.SUSDE).balanceOf(address(this));
        uint256 susdeNavUsde = ISUSDe(Mainnet.SUSDE).convertToAssets(susdeBal);

        emit log_named_uint("usde_collateral_e18", pos.collateral);
        emit log_named_uint("usdc_debt_e6", usdcDebt);
        emit log_named_uint("offmorpho_susde_shares_e18", susdeBal);
        emit log_named_uint("offmorpho_susde_nav_usde_e18", susdeNavUsde);

        // Net equity (USDe-denom, e18): collateral + sUSDe_NAV - debt_USDC * 1e12
        int256 netEquityUsdE18 = int256(uint256(pos.collateral))
            + int256(susdeNavUsde)
            - int256(usdcDebt * 1e12);
        emit log_named_int("net_equity_usde_e18", netEquityUsdE18);

        _endPnL("F08-07: USDe-collateral Morpho loop with off-Morpho sUSDe");
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata) external {
        require(msg.sender == Mainnet.MORPHO, "F08-07: only morpho");

        // We hold EQUITY_USDE + assets of USDe = 5M USDe total.
        uint256 totalUsde = IERC20(Mainnet.USDE).balanceOf(address(this));

        // ---- Supply ALL USDe as Morpho collateral ----
        IMorpho(Mainnet.MORPHO).supplyCollateral(_market, totalUsde, address(this), "");

        // ---- Borrow USDC against the USDe collateral ----
        // At LLTV 86% with USDe oracle at $1, max borrow = 0.86 * totalUsde (in USDC).
        // Keep a 1% buffer; borrow 85% LTV = 0.85 * totalUsde (in USDC).
        // USDe is 18 dec, USDC is 6 dec - scale by 1e12.
        uint256 borrowUsdc = (totalUsde * 8500) / 10_000 / 1e12;
        IMorpho(Mainnet.MORPHO).borrow(_market, borrowUsdc, 0, address(this), address(this));

        // ---- Swap USDC -> USDe on Curve, then stake into sUSDe ----
        uint256 expectedUsde = ICurveStableSwap(LOCAL_CURVE_USDE_USDC).get_dy(
            int128(1), int128(0), borrowUsdc
        );
        uint256 minOut = (expectedUsde * 9950) / 10_000;
        uint256 usdeFromUsdc = ICurveStableSwap(LOCAL_CURVE_USDE_USDC).exchange(
            int128(1), int128(0), borrowUsdc, minOut
        );

        // ---- Stake the freshly bought USDe into sUSDe (kept off-Morpho) ----
        // The yield-bearing sUSDe stays in the wallet; it is NOT supplied to
        // Morpho. NAV growth accrues to the wallet sleeve untouched.
        // We can use the freshly-bought USDe to repay the flash AFTER we
        // covered the flash principal - but here we use a different path:
        // use FLASH_USDE worth of newly-bought USDe to repay the flash, and
        // stake the residual.
        //
        // Strategy split:
        //   - assets (FLASH_USDE) of usdeFromUsdc is held for repay
        //   - residual usdeFromUsdc - assets is staked into sUSDe
        //
        // If usdeFromUsdc < assets (e.g. due to Curve slippage > collateral
        // headroom), we'd be short the repay. The 85% LTV with 99.5% min-out
        // gives us:  borrowUsdc = 0.85 * 5M = 4.25M USDC.
        //            usdeFromUsdc ~= 4.225M USDe (5 bps slippage).
        // Flash principal = 4M USDe. So the residual ~= 225k USDe gets staked.

        require(usdeFromUsdc >= assets, "F08-07: insufficient USDe to repay flash");
        uint256 stakingAmt = usdeFromUsdc - assets;

        if (stakingAmt > 0) {
            ISUSDe(Mainnet.SUSDE).deposit(stakingAmt, address(this));
        }

        // Morpho pulls `assets` back via outer approval after callback returns.
    }
}
