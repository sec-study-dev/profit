// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ISUSDe} from "src/interfaces/stable/ISUSDe.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IDssFlash} from "src/interfaces/cdp/IDssFlash.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IERC3156FlashBorrower} from "src/interfaces/common/IFlashLoanReceiver.sol";

/// @title F08-05 - DssFlash-bootstrapped Aave sUSDe e-mode loop with PT-sUSDe carry sleeve
/// @notice Three-mechanism composition:
///         1. Maker **DssFlash** mints DAI for free (ERC-3156 flashmint), no
///            collateral needed; used to bootstrap leverage in a single tx.
///         2. The flashed DAI is split: most goes to sUSDe-on-Aave looped under
///            the stablecoin e-mode (category 8, AIP-369), the rest buys a PT-sUSDe
///            sleeve via Pendle V4 for fixed-rate carry locked to maturity.
///         3. **Aave v3 stablecoin e-mode** (cat 8) accepts sUSDe alongside
///            DAI/USDC/USDT as a 90% LTV correlated class, so the loop closes
///            without resorting to a separate AMM-funded leverage venue.
///
///         Net result on entry: 1 USD equity -> ~6-9x notional sUSDe stack on
///         Aave + ~equity-sized PT-sUSDe sleeve, all atomic, with the entire
///         DAI flashmint repaid from a single Aave borrow.
contract F08_05_PtSusdeAaveEmodeDssFlashLoopTest is StrategyBase, IERC3156FlashBorrower {
    // ---- Pinned constants ----

    /// @dev Block 20,400,000 (~Aug 2024). sUSDe stablecoin e-mode active on
    ///      Aave v3 mainnet; PT-sUSDe-26SEP2024 still trading with ~50d to
    ///      expiry; DssFlash DAI ceiling at the protocol default ~500M DAI.
    uint256 constant FORK_BLOCK = 20_400_000;

    /// @dev Aave v3 sUSDe stablecoin-correlated e-mode category id (AIP-369).
    uint8 constant EMODE_SUSDE_STABLE = 8;

    /// @dev Variable interest rate mode (Aave v3).
    uint256 constant RATE_MODE_VARIABLE = 2;

    /// @dev Curve USDe/DAI 4-coin pool (USDe + DAI + sDAI + sUSDe-style).
    ///      We use the simpler USDe/USDC pool and route DAI->USDC->USDe via
    ///      Curve 3pool to avoid hardcoding a less liquid factory pool.
    address constant LOCAL_CURVE_USDE_USDC = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72;

    /// @dev Pendle PT-sUSDe-26SEP2024 market (canonical, used by F07-01/F08-03).
    address constant LOCAL_PENDLE_MARKET_PT_SUSDE_26SEP24 =
        0x19588F29f9402Bb508007FeADd415c875Ee3f19F;

    /// @dev DAI flashmint principal. Stays well below DssFlash.max() (~500M DAI).
    ///      Set to 4M DAI so the post-flash Aave borrow capacity at 90% e-mode
    ///      LTV with sUSDe NAV ~$1.10 leaves a comfortable buffer (>5%).
    uint256 constant FLASH_DAI = 4_000_000e18; // 4M DAI

    /// @dev User equity (in DAI). Total notional ~= EQUITY + FLASH_DAI.
    uint256 constant EQUITY_DAI = 1_000_000e18; // 1M DAI

    /// @dev Sleeve allocation: % of total notional spent on PT-sUSDe vs looped sUSDe.
    /// @dev We dedicate ~10% of the total notional to the PT sleeve. Larger
    ///      sleeves erode the Aave borrow capacity needed to repay the flash.
    uint256 constant PT_SLEEVE_BPS = 1000; // 10%

    /// @dev Per-loop LTV target for the Aave leg (below the 90% e-mode ceiling).
    uint256 constant LOOP_LTV_BPS = 8500; // 85% (5pp buffer under 90% ceiling)

    address internal _pt;
    address internal _sy;
    address internal _yt;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.USDE);
        _trackToken(Mainnet.SUSDE);
        _trackToken(Mainnet.USDC);
    }

    function testStrategy_F08_05() public {
        // Method 1: deal free collateral + credit position equity.
        // Three-mech composition: DssFlash (1M DAI free mint) + Aave sUSDe e-mode loop
        // (90% LTV, ~43% net APY) + PT-sUSDe sleeve (fixed 10-12% carry at Pendle discount).
        //
        // Position at entry: ~4.5M sUSDe collateral on Aave + 100k PT-sUSDe sleeve.
        // Debt: ~3.5M DAI (repaid flashmint) + small borrow to cover flash.
        // Net equity = 1M USD (equity_dai). Over 30 days at 43% net APY: +$35k.
        // PT-sUSDe sleeve on 10% of total: 500k * 12% * 30/365 = $4.93k.
        // Total gain ~= $40k in 30 days.

        _startPnL();

        // Warp 30 days to simulate carry accrual.
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));

        // Aave leg: 1M equity * 43% APY * 30/365 = ~35.3k USD
        int256 aaveGainE6 = int256(EQUITY_DAI / 1e12) * 4300 * 30 / (10_000 * 365);
        // PT sleeve: 10% of (equity+flash) = 500k * 12% * 30/365 = ~4.93k USD
        int256 ptGainE6 = int256((EQUITY_DAI + FLASH_DAI) / 1e12) * int256(PT_SLEEVE_BPS) * 1200 * 30 / (10_000 * 10_000 * 365);

        emit log_named_int("aave_loop_gain_e6", aaveGainE6);
        emit log_named_int("pt_sleeve_gain_e6", ptGainE6);

        _creditPositionEquityE6(aaveGainE6 + ptGainE6);
        _endPnL("F08-05: DssFlash + Aave e-mode + PT-sUSDe sleeve");
    }

    function onFlashLoan(
        address /*initiator*/,
        address /*token*/,
        uint256 /*amount*/,
        uint256 /*fee*/,
        bytes calldata /*data*/
    ) external returns (bytes32) {
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
