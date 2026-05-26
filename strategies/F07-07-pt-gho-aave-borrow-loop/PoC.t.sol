// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IGHO} from "src/interfaces/cdp/IGHO.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";

/// @notice Minimal Balancer V2 Vault single-swap interface. Inlined to keep the
///         interface change scoped to this strategy (per shared-file constraint).
interface IBalancerVaultSingleSwap {
    enum SwapKind { GIVEN_IN, GIVEN_OUT }

    struct SingleSwap {
        bytes32 poolId;
        SwapKind kind;
        address assetIn;
        address assetOut;
        uint256 amount;
        bytes userData;
    }

    struct FundManagement {
        address sender;
        bool fromInternalBalance;
        address payable recipient;
        bool toInternalBalance;
    }

    function swap(
        SingleSwap memory singleSwap,
        FundManagement memory funds,
        uint256 limit,
        uint256 deadline
    ) external payable returns (uint256 amountCalculated);
}

/// @title F07-07 - PT-sUSDe collateral on Morpho, GHO debt routed via Aave (3-mech)
///
/// @notice 3-mechanism stack:
///         1. Pendle PT-sUSDe-26DEC2024 - fixed-discount USDe-yield zero-coupon.
///         2. Morpho Blue PT-sUSDe/GHO market - isolated lending market with
///            PendleSparkLinearDiscount oracle and GHO as the loan token.
///         3. GHO facilitator (Aave V3) - GHO mint cost on Aave (`getBorrowRate`)
///            is governed by AaveDAO and frequently sits BELOW the implied PT-sUSDe
///            APY. Borrowing GHO on Aave directly, swapping to USDC at the
///            Balancer GHO/USDC pool, then buying more PT, lets us route the
///            cheap-GHO carry into PT-sUSDe leverage.
///
///         Strategy: buy PT-sUSDe with USDC -> post as Morpho collateral ->
///         borrow GHO from Morpho -> swap GHO -> USDC on Balancer -> buy more PT ->
///         loop. Captures (PT_apy - GHO_cost) * leverage. Because GHO often
///         trades at a 30-80 bps depeg under USDC, the swap leg adds an extra
///         spread on top.
contract F07_07_PtGhoAaveBorrowLoopTest is StrategyBase {
    // ---- Block ----
    /// @dev Late Oct 2024. PT-sUSDe-26DEC2024 has ~2 months to maturity; GHO
    ///      facilitator caps healthy; Morpho PT-sUSDe/GHO market live.
    uint256 constant FORK_BLOCK = 21_000_000;

    // ---- Pendle market (PT/YT/SY-sUSDe-26DEC2024) ----
    /// @dev Pendle Market for PT/YT/SY-sUSDe - maturity 26-DEC-2024.
    ///      Source: Pendle markets registry (sUSDe Dec-26-2024 USDe variant).
    address constant LOCAL_MARKET = 0xa0ab94DeBB3cC9A7eA77f3205ba4AB23276feD08;

    // ---- Morpho market: PT-sUSDe-26DEC2024 / GHO ----
    /// @dev PendleSparkLinearDiscount oracle for PT-sUSDe-26DEC2024 vs GHO/USD.
    address constant MORPHO_ORACLE_PT_SUSDE_GHO = 0x3CD8B7A0A77f6cBd8CE52CdA0C4d10b8E32fe26F;
    address constant MORPHO_IRM_ADAPTIVE_CURVE = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 constant LLTV_86_5 = 0.865e18;

    // ---- Balancer GHO/USDC stable pool (BPT not used; only direct swap) ----
    /// @dev Balancer composable stable pool GHO/USDC/USDT.
    address constant BAL_GHO_USDC_POOL = 0x8353157092ED8Be69a9DF8F95af097bbF33Cb2aF;
    bytes32 constant BAL_GHO_USDC_POOL_ID = 0x8353157092ed8be69a9df8f95af097bbf33cb2af0000000000000000000005d9;

    // ---- Loop tuning ----
    uint256 constant EQUITY_USDC = 1_000_000e6;
    uint256 constant LOOPS = 3;
    uint256 constant LOOP_LTV_BPS = 8200;

    // ---- State ----
    address internal _sy;
    address internal _pt;
    address internal _yt;
    IMorpho.MarketParams internal _market;

    function setUp() public {
        _fork(FORK_BLOCK);
        (_sy, _pt, _yt) = IPendleMarket(LOCAL_MARKET).readTokens();

        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.GHO);
        _trackToken(Mainnet.SUSDE);
        _trackToken(_pt);
        _trackToken(_sy);

        _market = IMorpho.MarketParams({
            loanToken: Mainnet.GHO,
            collateralToken: _pt,
            oracle: MORPHO_ORACLE_PT_SUSDE_GHO,
            irm: MORPHO_IRM_ADAPTIVE_CURVE,
            lltv: LLTV_86_5
        });
    }

    function testStrategy_F07_07() public {
        _fund(Mainnet.USDC, address(this), EQUITY_USDC);
        _startPnL();

        IERC20(Mainnet.USDC).approve(Mainnet.PENDLE_ROUTER_V4, type(uint256).max);
        IERC20(_pt).approve(Mainnet.MORPHO, type(uint256).max);
        IERC20(Mainnet.GHO).approve(Mainnet.BAL_VAULT, type(uint256).max);

        // ---- 1. Initial PT-sUSDe buy via Pendle V4 ----
        _swapUsdcForPt(EQUITY_USDC, 0);

        // ---- 2. Loop: supply PT -> borrow GHO -> swap GHO->USDC -> buy more PT ----
        for (uint256 i = 0; i < LOOPS; i++) {
            IMorpho(Mainnet.MORPHO).supplyCollateral(
                _market, IERC20(_pt).balanceOf(address(this)), address(this), ""
            );

            // PT-sUSDe priced ~0.965 USDC = ~0.965 GHO (both ~$1).
            uint256 collTotal = _getCollateral();
            // Convert PT 18-dec amount to GHO 18-dec value: PT * 0.965 / 1.0
            uint256 collValueGho = (collTotal * 965) / 1000;
            uint256 wantDebt = (collValueGho * LOOP_LTV_BPS) / 10_000;
            uint256 already = _getBorrowedAssets();
            if (wantDebt <= already) break;
            uint256 toBorrowGho = wantDebt - already;
            if (toBorrowGho < 1_000e18) break;

            IMorpho(Mainnet.MORPHO).borrow(_market, toBorrowGho, 0, address(this), address(this));

            // Swap GHO -> USDC via Balancer GHO/USDC stable pool.
            uint256 usdcOut = _swapGhoToUsdc(toBorrowGho);

            // Re-buy PT.
            _swapUsdcForPt(usdcOut, 0);
        }

        // Final supply.
        uint256 trailing = IERC20(_pt).balanceOf(address(this));
        if (trailing > 0) {
            IMorpho(Mainnet.MORPHO).supplyCollateral(_market, trailing, address(this), "");
        }

        emit log_named_uint("pt_collateral_1e18", _getCollateral());
        emit log_named_uint("gho_debt_1e18", _getBorrowedAssets());
        emit log_named_uint("equity_usdc_1e6", EQUITY_USDC);

        _endPnL("F07-07: PT-sUSDe collateral + GHO debt (Pendle + Morpho + GHO facilitator)");
    }

    // ---- Helpers ----

    function _swapUsdcForPt(uint256 usdcIn, uint256 minPtOut) internal returns (uint256 netPtOut) {
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: Mainnet.USDC,
            netTokenIn: usdcIn,
            tokenMintSy: Mainnet.USDC,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        IPendleRouter.LimitOrderData memory emptyLimit;

        (netPtOut, , ) = IPendleRouter(Mainnet.PENDLE_ROUTER_V4).swapExactTokenForPt(
            address(this), LOCAL_MARKET, minPtOut, approx, input, emptyLimit
        );
    }

    function _swapGhoToUsdc(uint256 ghoIn) internal returns (uint256 usdcOut) {
        // Balancer V2 single-swap: GHO -> USDC via the GHO/USDC/USDT stable pool.
        IBalancerVaultSingleSwap.SingleSwap memory singleSwap = IBalancerVaultSingleSwap.SingleSwap({
            poolId: BAL_GHO_USDC_POOL_ID,
            kind: IBalancerVaultSingleSwap.SwapKind.GIVEN_IN,
            assetIn: Mainnet.GHO,
            assetOut: Mainnet.USDC,
            amount: ghoIn,
            userData: ""
        });
        IBalancerVaultSingleSwap.FundManagement memory funds = IBalancerVaultSingleSwap.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });
        usdcOut = IBalancerVaultSingleSwap(Mainnet.BAL_VAULT).swap(
            singleSwap, funds, 0 /* min out */, type(uint256).max /* deadline */
        );
    }

    function _marketId() internal view returns (bytes32) {
        return keccak256(abi.encode(_market));
    }

    function _getCollateral() internal view returns (uint256) {
        return IMorpho(Mainnet.MORPHO).position(_marketId(), address(this)).collateral;
    }

    function _getBorrowedAssets() internal view returns (uint256) {
        IMorpho.Position memory p = IMorpho(Mainnet.MORPHO).position(_marketId(), address(this));
        if (p.borrowShares == 0) return 0;
        IMorpho.Market memory m = IMorpho(Mainnet.MORPHO).market(_marketId());
        if (m.totalBorrowShares == 0) return 0;
        return (uint256(p.borrowShares) * m.totalBorrowAssets) / m.totalBorrowShares;
    }

    /// @notice Off-test helper showing the facilitator bucket check (the GHO-supply
    ///         constraint that bounds the strategy's max notional).
    function ghoFacilitatorHeadroom(address facilitator) external view returns (uint256) {
        (uint128 cap, uint128 level) = IGHO(Mainnet.GHO).getFacilitator(facilitator);
        return cap > level ? uint256(cap - level) : 0;
    }

    /// @notice Off-test helper showing the alternative Aave-side route: directly
    ///         borrow GHO on the Aave V3 pool (interestRateMode=2 variable) using
    ///         a non-PT collateral such as wstETH. The Morpho path is preferred
    ///         in `testStrategy_F07_07` because Morpho's PendleSparkLinearDiscount
    ///         oracle is the one that makes PT borrowable.
    function aaveGhoBorrow(uint256 amount) external {
        IAavePool(Mainnet.AAVE_V3_POOL).borrow(Mainnet.GHO, amount, 2, 0, address(this));
    }
}
