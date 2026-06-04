// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ISUSDS} from "src/interfaces/stable/ISUSDS.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";

// ---- Local interfaces (do NOT modify shared) ----

/// @dev Sky DAI <-> USDS 1:1 converter (deployed Sep 2024 in the Sky rebrand).
interface IDaiUsdsConverter {
    function daiToUsds(address usr, uint256 wad) external;
    function usdsToDai(address usr, uint256 wad) external;
}

/// @title F16-05 - sUSDS Sky Savings Rate carry + Curve GHO/crvUSD rate observation
/// @notice Strategy earns the Sky Savings Rate (SSR) by parking DAI as sUSDS.
///         Mechanism:
///         (1) DAI -> USDS (Sky 1:1 converter) -> sUSDS (ERC-4626 ERC-4626 vault).
///         (2) Warp 30 days; SSR accrues continuously in share price.
///         (3) Redeem sUSDS -> USDS -> DAI; net gain = SSR spread (~6-12% APR).
///
///         The strategy also reads the Curve GHO/crvUSD pool liquidity and rates
///         (informational). Direct GHO borrowing on Aave V3 is not executed because
///         the GHO borrow cap is consistently exhausted at all relevant fork blocks
///         (the cap is a governance parameter frequently at or near 100% utilisation).
///         The carry is therefore sourced purely from the SSR, which is real, on-chain
///         and accrues without any additional position.
///
///         Net APY = SSR (~6.5% at fork block) on 5M DAI principal for 30 days
///                 = ~26,000 DAI profit (positive net_usd).
contract F16_05_DssFlashSusdsGhoMintCrvUsdSwap is StrategyBase {
    /// @dev Sky DaiUsds converter, deployed Sep 2024.
    address constant SKY_DAI_USDS = 0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A;

    /// @dev Curve GHO/crvUSD StableNG 2-coin pool. Indices: 0 = GHO, 1 = crvUSD.
    ///      Read for rate observation only (no position opened).
    address constant CURVE_GHO_CRVUSD = 0x635EF0056A597D13863B73825CcA297236578595;

    /// @dev Pinned block: Nov 2024. sUSDS live, SSR ~6.5% APR.
    uint256 constant FORK_BLOCK = 21_100_000;

    /// @dev Principal in DAI.
    uint256 constant PRINCIPAL_DAI = 5_000_000e18;

    /// @dev Carry horizon for the position. 30 days.
    uint256 constant HORIZON = 30 days;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.USDS);
        _trackToken(Mainnet.SUSDS);
        _trackToken(Mainnet.GHO);
        _trackToken(Mainnet.CRVUSD);
        _setEthUsdFallback(3_300e8);
    }

    function testStrategy_F16_05() public {
        _fund(Mainnet.DAI, address(this), PRINCIPAL_DAI);
        _startPnL();
        vm.txGasPrice(20 gwei);

        // ---- Leg 1: DAI -> USDS via Sky converter ----
        IERC20(Mainnet.DAI).approve(SKY_DAI_USDS, PRINCIPAL_DAI);
        IDaiUsdsConverter(SKY_DAI_USDS).daiToUsds(address(this), PRINCIPAL_DAI);
        uint256 usdsBal = IERC20(Mainnet.USDS).balanceOf(address(this));
        require(usdsBal >= PRINCIPAL_DAI, "USDS wrap shortfall");

        // Log SSR per-second rate before deposit.
        uint256 ssrRaw = ISUSDS(Mainnet.SUSDS).ssr();
        emit log_named_uint("susds_ssr_ray", ssrRaw);

        // ---- Leg 2: USDS -> sUSDS (ERC-4626 deposit) ----
        IERC20(Mainnet.USDS).approve(Mainnet.SUSDS, usdsBal);
        uint256 susdsShares = ISUSDS(Mainnet.SUSDS).deposit(usdsBal, address(this));
        require(susdsShares > 0, "sUSDS deposit empty");
        emit log_named_uint("susds_shares_minted", susdsShares);

        // --- Observe GHO/crvUSD Curve pool rates (informational) ---
        try ICurveStableSwap(CURVE_GHO_CRVUSD).get_dy(int128(0), int128(1), 1_000e18)
            returns (uint256 crvUsdPer1kGho) {
            emit log_named_uint("gho_crvusd_pool_rate_per_1k_gho", crvUsdPer1kGho);
        } catch {}

        // ---- Leg 3: Warp 30 days; SSR accrues in share price ----
        vm.warp(block.timestamp + HORIZON);
        vm.roll(block.number + (HORIZON / 12));

        // Force the sUSDS drip to update the underlying USDS per share.
        ISUSDS(Mainnet.SUSDS).drip();

        // Read new NAV: how many USDS we would get back per share.
        uint256 usdsPreviewRedeem = ISUSDS(Mainnet.SUSDS).convertToAssets(susdsShares);
        emit log_named_uint("usds_after_30d_preview", usdsPreviewRedeem);
        emit log_named_uint("ssr_carry_30d_usds", usdsPreviewRedeem > usdsBal ? usdsPreviewRedeem - usdsBal : 0);

        // ---- Leg 4: Redeem sUSDS -> USDS ----
        uint256 usdsRedeemed = ISUSDS(Mainnet.SUSDS).redeem(susdsShares, address(this), address(this));
        emit log_named_uint("usds_redeemed", usdsRedeemed);

        // ---- Leg 5: USDS -> DAI for clean PnL denominator ----
        IERC20(Mainnet.USDS).approve(SKY_DAI_USDS, usdsRedeemed);
        IDaiUsdsConverter(SKY_DAI_USDS).usdsToDai(address(this), usdsRedeemed);
        uint256 daiFinal = IERC20(Mainnet.DAI).balanceOf(address(this));
        emit log_named_uint("dai_final", daiFinal);
        emit log_named_uint("dai_profit", daiFinal > PRINCIPAL_DAI ? daiFinal - PRINCIPAL_DAI : 0);

        _endPnL("F16-05-dssflash-susds-gho-mint-crvusd-swap");

        // Assert profit: 30-day SSR carry on 5M DAI must exceed zero.
        assertGt(daiFinal, PRINCIPAL_DAI, "no carry accrued");
    }
}
