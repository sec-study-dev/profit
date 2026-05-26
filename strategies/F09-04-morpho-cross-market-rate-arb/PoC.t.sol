// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";
import {console2} from "forge-std/console2.sol";

/// @notice F09-04 — Morpho cross-market rate arb (structural demonstration).
///
/// Reads two Morpho USDC-loan markets at the fork block, computes utilisation
/// for each, asserts the utilisation differential, then opens the supply leg
/// (USDC supply to the higher-rate market). The matching borrow leg on the
/// other market is the production extension and would use the same flashloan
/// callback pattern as F09-01.
contract F09_04_MorphoCrossMarketRateArbTest is StrategyBase {
    // ---- Constants ----

    uint256 constant FORK_BLOCK = 21_400_000;

    // We use two well-known marketIds and recover the MarketParams via Morpho's
    // own `idToMarketParams(bytes32)` view (avoids hard-coding fragile oracle
    // addresses that might shift across redeployments).
    //
    // Market A: sUSDe / USDC 91.5% LLTV — Morpho's flagship stable carry market.
    // Market B: wstETH / USDC 86% LLTV — Morpho's flagship LST-collateral market.
    bytes32 constant SUSDE_USDC_MARKET_ID =
        0x39d11026eae1c6ec02aa4c0910778664089cdd97c3fd23f68f7cd05e2e95af48;
    bytes32 constant WSTETH_USDC_MARKET_ID =
        0xb323495f7e4148be5643a4ea4a8221eef163e4bccfdedc2a6f4696baacbc86cc;

    uint256 constant SUPPLY_AMOUNT = 100_000e6; // 100k USDC supply-leg notional

    IMorpho.MarketParams internal _marketA;
    IMorpho.MarketParams internal _marketB;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.USDC);

        // Recover both markets' params from on-chain Morpho registry by marketId.
        _marketA = IMorpho(Mainnet.MORPHO).idToMarketParams(SUSDE_USDC_MARKET_ID);
        _marketB = IMorpho(Mainnet.MORPHO).idToMarketParams(WSTETH_USDC_MARKET_ID);

        // Sanity: these markets should exist (have non-zero loanToken). If the
        // marketIds were wrong, Morpho returns the zero struct.
        require(_marketA.loanToken == Mainnet.USDC, "F09-04: marketA mismatch or not USDC-loan");
        require(_marketA.collateralToken == Mainnet.SUSDE, "F09-04: marketA not sUSDe-collateral");
        require(_marketB.loanToken == Mainnet.USDC, "F09-04: marketB mismatch or not USDC-loan");
        require(_marketB.collateralToken == Mainnet.WSTETH, "F09-04: marketB not wstETH-collateral");
    }

    function testStrategy_F09_04() public {
        IMorpho morpho = IMorpho(Mainnet.MORPHO);

        // ---- Read both markets' on-chain state ----
        IMorpho.Market memory mA = morpho.market(SUSDE_USDC_MARKET_ID);
        IMorpho.Market memory mB = morpho.market(WSTETH_USDC_MARKET_ID);

        // util in 1e18 fixed point.
        uint256 utilA = mA.totalSupplyAssets > 0
            ? (uint256(mA.totalBorrowAssets) * 1e18) / uint256(mA.totalSupplyAssets)
            : 0;
        uint256 utilB = mB.totalSupplyAssets > 0
            ? (uint256(mB.totalBorrowAssets) * 1e18) / uint256(mB.totalSupplyAssets)
            : 0;

        console2.log("market A (sUSDe/USDC 91.5):");
        console2.log("  totalSupplyAssets =", mA.totalSupplyAssets);
        console2.log("  totalBorrowAssets =", mA.totalBorrowAssets);
        console2.log("  utilisation (e18) =", utilA);
        console2.log("market B (wstETH/USDC 86):");
        console2.log("  totalSupplyAssets =", mB.totalSupplyAssets);
        console2.log("  totalBorrowAssets =", mB.totalBorrowAssets);
        console2.log("  utilisation (e18) =", utilB);

        uint256 utilDelta = utilA > utilB ? utilA - utilB : utilB - utilA;
        console2.log("utilisation delta (e18) =", utilDelta);

        // Necessary condition for a meaningful rate spread under AdaptiveCurveIRM:
        // utilisation differential ≥ 5% (5e16 in 1e18 fixed-point).
        require(utilDelta >= 0.05e18, "F09-04: insufficient util spread at fork block");

        // ---- Execute the supply leg of the arb (supply to higher-util market A) ----
        _fund(Mainnet.USDC, address(this), SUPPLY_AMOUNT);
        _startPnL();

        IERC20(Mainnet.USDC).approve(Mainnet.MORPHO, type(uint256).max);
        (uint256 assetsSupplied, uint256 sharesSupplied) =
            morpho.supply(_marketA, SUPPLY_AMOUNT, 0, address(this), "");

        console2.log("supplied to A: assets =", assetsSupplied);
        console2.log("supplied to A: shares =", sharesSupplied);

        // The matching borrow leg on market B would require wstETH collateral on
        // contract; we leave it as a documented extension in the README.

        _endPnL("F09-04: Morpho-cross-market-rate-arb (supply leg)");
    }
}
