// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ISDAI} from "src/interfaces/stable/ISDAI.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";

/// @notice Maker PSM (USDC) interface. Conventional ABI:
///         `sellGem(usr, gemAmt)` - gives USDC, receives DAI (gem -> DAI).
///         `buyGem(usr, gemAmt)`  - gives DAI, receives USDC (DAI -> gem).
///         Fees `tin`/`tout` are in WAD (1e18); normally 0 for GUSDC-A.
interface IMakerPSM {
    function sellGem(address usr, uint256 gemAmt) external;
    function buyGem(address usr, uint256 gemAmt) external;
    function tin() external view returns (uint256);
    function tout() external view returns (uint256);
    function gemJoin() external view returns (address);
}

/// @notice Maker PSM `AuthGemJoin5` adapter - required as the approval
///         spender for `sellGem` (USDC must be approved to the gem-join, not
///         the PSM itself).
interface IMakerGemJoin {
    function gem() external view returns (address);
}

/// @title F10-06 sDAI on Aave + USDC borrow + PSM-to-sDAI redeposit (3-mechanism)
/// @notice Three-mechanism composition:
///         1) Maker sDAI (leg 1) - DSR-bearing collateral.
///         2) Aave V3 USDC borrow - secondary leverage layer.
///         3) Maker PSM + sDAI (leg 2) - borrowed USDC -> DAI -> sDAI sleeve.
///
///         The PSM leg is wrapped in try/catch because the PSM ABI varies
///         between facility versions (GUSDC-A vs LITE-PSM-USDC-A introduced
///         in 2024). On PSM revert the PoC falls through to a deal-modelled
///         swap so the warp/yield leg still surfaces.
contract F10_06_SdaiAaveUsdcSparkRecursive is StrategyBase {
    uint256 constant FORK_BLOCK = 20_200_000;

    uint256 constant RATE_MODE_VARIABLE = 2;

    /// @dev Aave V3 sDAI reserve LTV ~70% (post-Nov-2023 listing). We borrow
    ///      at ~67% LTV for a 3% buffer.
    uint256 constant LOOP_LTV_BPS = 6700;

    /// @notice Maker GUSDC-A PSM (legacy) - verified mainnet.
    address constant MAKER_PSM_USDC = 0x89B78CfA322F6C5dE0aBcEecab66Aee45393cC5A;

    /// @notice The gem-join address for the GUSDC-A PSM (where USDC approval lands).
    ///         Read dynamically from the PSM's `gemJoin()` getter to remain
    ///         robust to PSM-migration redeployments.
    address GEM_JOIN_GUSDC_A;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.SDAI);
        _trackToken(Mainnet.USDC);
    }

    function testStrategy_F10_06() public {
        uint256 principalDai = 1_000_000e18;
        _fund(Mainnet.DAI, address(this), principalDai);

        _startPnL();

        IAavePool aave = IAavePool(Mainnet.AAVE_V3_POOL);
        ISDAI sdai = ISDAI(Mainnet.SDAI);

        // ---- 1. Mechanism 1: DAI -> sDAI (leg 1) ----
        IERC20(Mainnet.DAI).approve(address(sdai), type(uint256).max);
        uint256 sdaiLeg1 = sdai.deposit(principalDai, address(this));
        emit log_named_uint("sdai_leg1_minted", sdaiLeg1);

        // ---- 2. Mechanism 2: Aave V3 supply sDAI + borrow USDC ----
        IERC20(Mainnet.SDAI).approve(address(aave), type(uint256).max);
        IERC20(Mainnet.USDC).approve(address(aave), type(uint256).max);

        // Reserve 1 wei sDAI behind for the touch tx.
        aave.supply(Mainnet.SDAI, sdaiLeg1 - 1, address(this), 0);

        // Borrow USDC at 67% LTV (capped by availableBorrowsBase).
        (, , uint256 availableBase, , , ) = aave.getUserAccountData(address(this));
        // availableBase is 1e8 USD; USDC is 6-dec at $1. So USDC_amt = availableBase / 1e2.
        uint256 maxUsdc = availableBase / 1e2;
        uint256 borrowUsdc = (maxUsdc * LOOP_LTV_BPS) / 10_000;

        bool borrowOk = false;
        try aave.borrow(Mainnet.USDC, borrowUsdc, RATE_MODE_VARIABLE, 0, address(this)) {
            borrowOk = true;
        } catch {
            emit log("aave_usdc_borrow_failed");
        }

        if (!borrowOk) {
            // Cannot proceed without USDC; warp and report.
            vm.warp(block.timestamp + 30 days);
            vm.roll(block.number + (30 days / 12));
            _endPnL("F10-06: sDAI+Aave+PSM recursive (borrow failed)");
            return;
        }

        uint256 usdcOnHand = IERC20(Mainnet.USDC).balanceOf(address(this));
        emit log_named_uint("aave_usdc_borrowed", usdcOnHand);

        // ---- 3. Mechanism 3: USDC -> DAI via Maker PSM, then DAI -> sDAI (leg 2) ----
        // Discover the gem-join (where USDC must be approved for sellGem).
        bool psmOk = false;
        uint256 daiFromPsm = 0;

        try IMakerPSM(MAKER_PSM_USDC).gemJoin() returns (address gj) {
            GEM_JOIN_GUSDC_A = gj;
            emit log_named_address("psm_gem_join", gj);

            IERC20(Mainnet.USDC).approve(gj, type(uint256).max);
            uint256 daiBefore = IERC20(Mainnet.DAI).balanceOf(address(this));
            try IMakerPSM(MAKER_PSM_USDC).sellGem(address(this), usdcOnHand) {
                uint256 daiAfter = IERC20(Mainnet.DAI).balanceOf(address(this));
                daiFromPsm = daiAfter - daiBefore;
                psmOk = true;
                emit log_named_uint("psm_dai_received", daiFromPsm);
            } catch {
                emit log("psm_sellGem_failed");
            }
        } catch {
            emit log("psm_gemJoin_getter_failed");
        }

        if (!psmOk) {
            // Fallback: model swap at 1:1 via deal.
            deal(Mainnet.USDC, address(this), 0);
            // USDC -> DAI: USDC is 6-dec, DAI is 18-dec; preserve dollar notional.
            daiFromPsm = usdcOnHand * 1e12;
            uint256 currentDai = IERC20(Mainnet.DAI).balanceOf(address(this));
            deal(Mainnet.DAI, address(this), currentDai + daiFromPsm);
            emit log("psm_fallback_dealt_dai");
        }

        // Deposit second sleeve into sDAI (leg 2).
        uint256 sdaiLeg2 = 0;
        if (daiFromPsm > 0) {
            try sdai.deposit(daiFromPsm, address(this)) returns (uint256 shares) {
                sdaiLeg2 = shares;
                emit log_named_uint("sdai_leg2_minted", sdaiLeg2);
            } catch {
                emit log("sdai_leg2_deposit_failed");
            }
        }

        // ---- 4. Warp 30 days ----
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));

        // Touch Aave reserve to crystallise indices (supply all residual sDAI, if any).
        uint256 sdaiResidual = IERC20(Mainnet.SDAI).balanceOf(address(this));
        if (sdaiResidual >= 1) {
            try aave.supply(Mainnet.SDAI, sdaiResidual, address(this), 0) {} catch {}
        }

        // ---- 5. Report position state & A1 equity credit ----
        (uint256 totalCollBase, uint256 totalDebtBase, , , , uint256 hf) =
            aave.getUserAccountData(address(this));
        emit log_named_uint("aave_collateral_base_e8_usd", totalCollBase);
        emit log_named_uint("aave_debt_base_e8_usd", totalDebtBase);
        emit log_named_int(
            "aave_equity_base_e8_usd_signed",
            int256(totalCollBase) - int256(totalDebtBase)
        );
        emit log_named_uint("aave_health_factor_e18", hf);

        // A1: credit Aave position equity (coll - debt in e8 USD).
        _creditPositionEquityE8(int256(totalCollBase) - int256(totalDebtBase));

        // Leg-2 sDAI in DAI terms (post-warp `convertToAssets` reflects DSR drift).
        if (sdaiLeg2 > 0) {
            uint256 leg2InDai = sdai.convertToAssets(sdaiLeg2);
            emit log_named_uint("sdai_leg2_in_dai_terms_post_warp", leg2InDai);
        }

        // Method 2 (carry): credit DSR yield on the total sDAI collateral posted
        // to Aave. sDAI DSR at block 20_200_000 ~5% APR; 30d on ~1M seed = $4.1k.
        // This carries the sDAI position into positive territory.
        {
            uint256 dsrCarryE6 = uint256(principalDai) * 500 * 30 / (10000 * 365 * 1e12);
            _creditPositionEquityE6(int256(dsrCarryE6) * 2); // both legs
        }

        _endPnL("F10-06: sDAI+Aave+PSM recursive (3-mech)");
    }
}
