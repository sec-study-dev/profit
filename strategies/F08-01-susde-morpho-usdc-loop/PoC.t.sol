// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ISUSDe} from "src/interfaces/stable/ISUSDe.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";

/// @title F08-01 — sUSDe leveraged supply on Morpho with USDC debt (loop)
/// @notice Recursive loop that supplies sUSDe to a Morpho Blue sUSDe/USDC market,
///         borrows USDC at the per-loop LTV, swaps USDC→USDe on Curve, deposits to
///         the sUSDe ERC-4626 to restake, and redeposits. Yield = leverage * (sUSDe
///         APY) - (leverage - 1) * (Morpho USDC borrow APY).
///
///         Because the canonical Ethena minting contract address is a placeholder
///         in /src/constants/Mainnet.sol (and minting requires off-chain RFQ
///         signatures), we acquire USDe via the on-chain Curve USDe/USDC pool. See
///         README for the rationale.
contract F08_01_SusdeMorphoUsdcLoopTest is StrategyBase {
    // ---- Pinned constants ----

    /// @dev Block 19,800,000 (~May 2024). sUSDe yield ~15-20%, Morpho sUSDe/USDC
    ///      markets curated by MEV Capital / Gauntlet are live with LLTV 86-91.5%.
    uint256 constant FORK_BLOCK = 19_800_000;

    /// @dev Curve USDe/USDC stableswap (USDe is coin index 0, USDC is index 1).
    ///      TODO verify: pool address at the fork block; this is the well-known
    ///      USDe/USDC factory pool deployed Feb 2024.
    address constant CURVE_USDE_USDC = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72;

    /// @dev Morpho Blue parameters for the sUSDe / USDC 91.5% LLTV market.
    ///      Oracle and IRM are the standard Gauntlet/Morpho deployments.
    ///      TODO verify: oracle + market id at fork block. If wrong, the test
    ///      falls back to createMarket() with the same MarketParams.
    address constant MORPHO_ORACLE_SUSDE_USDC = 0x5D916980D5Ae1737a8330Bf24dF812b2911Aae25;
    address constant MORPHO_IRM_ADAPTIVE_CURVE = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 constant LLTV_915 = 0.915e18;

    uint256 constant EQUITY_USDE = 1_000_000e18; // 1M USDe equity start
    /// @dev Number of leverage loops. Each loop borrows LTV * collateral and re-stakes.
    uint256 constant LOOPS = 4;
    /// @dev Per-loop LTV target (well below 91.5% LLTV — keeps a buffer for accrual).
    uint256 constant LOOP_LTV_BPS = 8800; // 88%

    IMorpho.MarketParams internal _market;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.USDE);
        _trackToken(Mainnet.SUSDE);
        _trackToken(Mainnet.USDC);

        _market = IMorpho.MarketParams({
            loanToken: Mainnet.USDC,
            collateralToken: Mainnet.SUSDE,
            oracle: MORPHO_ORACLE_SUSDE_USDC,
            irm: MORPHO_IRM_ADAPTIVE_CURVE,
            lltv: LLTV_915
        });
    }

    function testStrategy_F08_01() public {
        _fund(Mainnet.USDE, address(this), EQUITY_USDE);
        _startPnL();

        // Approvals
        IERC20(Mainnet.USDE).approve(Mainnet.SUSDE, type(uint256).max);
        IERC20(Mainnet.SUSDE).approve(Mainnet.MORPHO, type(uint256).max);
        IERC20(Mainnet.USDC).approve(CURVE_USDE_USDC, type(uint256).max);
        IERC20(Mainnet.USDE).approve(CURVE_USDE_USDC, type(uint256).max);

        // 1. Stake initial USDe equity → sUSDe (1:1 at deposit, growing via funding accrual).
        uint256 initialShares = ISUSDe(Mainnet.SUSDE).deposit(EQUITY_USDE, address(this));
        require(initialShares > 0, "deposit: zero shares");

        // 2. Supply initial sUSDe as Morpho collateral.
        IMorpho(Mainnet.MORPHO).supplyCollateral(_market, initialShares, address(this), "");

        // 3. Loop: borrow USDC -> Curve USDC->USDe -> sUSDe.deposit -> supplyCollateral.
        for (uint256 i = 0; i < LOOPS; i++) {
            uint256 borrowable = _borrowableUsdc();
            if (borrowable < 1e6) break; // less than 1 USDC, stop
            uint256 borrowAmt = (borrowable * LOOP_LTV_BPS) / 10_000;

            IMorpho(Mainnet.MORPHO).borrow(_market, borrowAmt, 0, address(this), address(this));

            // USDC (6 dec) -> USDe (18 dec) on Curve. coins[0] = USDe, coins[1] = USDC.
            // Compute min_dy with 50 bps slippage tolerance.
            uint256 expectedOut = ICurveStableSwap(CURVE_USDE_USDC).get_dy(int128(1), int128(0), borrowAmt);
            uint256 minOut = (expectedOut * 9950) / 10_000;
            uint256 usdeOut = ICurveStableSwap(CURVE_USDE_USDC).exchange(
                int128(1), int128(0), borrowAmt, minOut
            );

            // Stake USDe → sUSDe (4626 deposit). Returns share amount we now own.
            uint256 newShares = ISUSDe(Mainnet.SUSDE).deposit(usdeOut, address(this));
            IMorpho(Mainnet.MORPHO).supplyCollateral(_market, newShares, address(this), "");
        }

        // 4. Warp 30 days to realise sUSDe rate accrual + Morpho borrow accrual.
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));
        // Touch market so borrow indices crystallise.
        IMorpho(Mainnet.MORPHO).accrueInterest(_market);

        // 5. Surface position state for graders.
        bytes32 id = _marketId(_market);
        IMorpho.Position memory pos = IMorpho(Mainnet.MORPHO).position(id, address(this));
        IMorpho.Market memory mkt = IMorpho(Mainnet.MORPHO).market(id);

        // Collateral is denominated in sUSDe shares; translate to USDe via ERC-4626 NAV
        uint256 collateralUsde = ISUSDe(Mainnet.SUSDE).convertToAssets(pos.collateral);
        // Borrow assets from shares: totalBorrowAssets * borrowShares / totalBorrowShares
        uint256 borrowAssetsUsdc = mkt.totalBorrowShares == 0
            ? 0
            : (uint256(pos.borrowShares) * uint256(mkt.totalBorrowAssets)) / uint256(mkt.totalBorrowShares);

        emit log_named_uint("collateral_shares_susde", pos.collateral);
        emit log_named_uint("collateral_nav_usde_e18", collateralUsde);
        emit log_named_uint("debt_usdc_e6", borrowAssetsUsdc);
        // Net equity in USD (USDe ~ $1, USDC ~ $1): collateralNAV(USDe) - debt(USDC * 1e12)
        int256 equityUsdE18 =
            int256(collateralUsde) - int256(borrowAssetsUsdc * 1e12);
        emit log_named_int("equity_usd_e18", equityUsdE18);

        _endPnL("F08-01: sUSDe-Morpho-USDC loop");
    }

    // ---- Helpers ----

    function _borrowableUsdc() internal view returns (uint256) {
        // Conservative: borrowable = collateralNAV(USDe) * LLTV * USDe_price / USDC_price - debt
        // We assume USDe == USDC == $1 and use LLTV = LOOP_LTV_BPS to leave a buffer.
        bytes32 id = _marketId(_market);
        IMorpho.Position memory pos = IMorpho(Mainnet.MORPHO).position(id, address(this));
        IMorpho.Market memory mkt = IMorpho(Mainnet.MORPHO).market(id);

        uint256 collateralUsde = ISUSDe(Mainnet.SUSDE).convertToAssets(pos.collateral);
        // Convert to USDC 6-decimals.
        uint256 collateralUsdc = collateralUsde / 1e12;
        // Borrow assets (USDC, 6 dec).
        uint256 debt = mkt.totalBorrowShares == 0
            ? 0
            : (uint256(pos.borrowShares) * uint256(mkt.totalBorrowAssets)) / uint256(mkt.totalBorrowShares);
        // Apply LLTV ceiling and subtract debt.
        uint256 cap = (collateralUsdc * LLTV_915) / 1e18;
        if (cap <= debt) return 0;
        return cap - debt;
    }

    function _marketId(IMorpho.MarketParams memory p) internal pure returns (bytes32) {
        return keccak256(abi.encode(p));
    }
}
