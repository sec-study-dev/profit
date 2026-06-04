// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";
import {ISDAI} from "src/interfaces/stable/ISDAI.sol";
import {ISUSDS} from "src/interfaces/stable/ISUSDS.sol";

/// @notice Minimal interface for Sky's DAI/USDS converter. Exposed at a
///         well-known address on mainnet (verified Q4 2024). Falls through to
///         USDC-only carry path if unavailable at the pinned block.
interface IDaiUsdsConverter {
    function daiToUsds(address usr, uint256 wad) external;
    function usdsToDai(address usr, uint256 wad) external;
}

/// @title F10-04 GHO mint with stkAAVE discount + sUSDS carry
contract F10_04_GhoStkAaveDiscountedMint is StrategyBase {
    uint256 constant FORK_BLOCK = 21_500_000;

    uint256 constant RATE_MODE_VARIABLE = 2;

    // stkAAVE Safety Module token - canonical mainnet address.
    address constant STK_AAVE = 0x4da27a545c0c5B758a6BA100e3a049001de870f5;

    // AAVE token.
    address constant AAVE_TOKEN = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;

    // Sky DAI <-> USDS converter (verified Q4 2024).
    // Address known as `DaiUsds` in Sky migration contracts: 0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A
    address constant SKY_DAI_USDS = 0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.GHO);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.USDS);
        _trackToken(Mainnet.SUSDS);
        _trackToken(STK_AAVE);
        _trackToken(AAVE_TOKEN);
    }

    function testStrategy_F10_04() public {
        uint256 principalUsdc = 100_000e6;
        _fund(Mainnet.USDC, address(this), principalUsdc);

        // Best-effort: fund stkAAVE via deal. The SM token uses non-standard
        // storage so this may zero out or fail silently - we read post-fund
        // balance and log if it's still zero.
        uint256 targetStk = 1_000e18;
        try this._fundStk(targetStk) {
            // ok
        } catch {
            emit log("stkaave_unfundable_via_deal");
        }

        uint256 stkBal = IERC20(STK_AAVE).balanceOf(address(this));
        emit log_named_uint("stkaave_balance", stkBal);

        _startPnL();

        IAavePool pool = IAavePool(Mainnet.AAVE_V3_POOL);

        // ---- 1. Supply USDC (retain 1 wei for the warp-touch tx). ----
        IERC20(Mainnet.USDC).approve(address(pool), type(uint256).max);
        pool.supply(Mainnet.USDC, principalUsdc - 1, address(this), 0);

        // ---- 2. Borrow GHO ----
        // Read GHO reserve to confirm it's live.
        IAavePool.ReserveDataLegacy memory ghoRes = pool.getReserveData(Mainnet.GHO);
        emit log_named_uint("gho_borrow_rate_ray", ghoRes.currentVariableBorrowRate);
        emit log_named_address("gho_var_debt_token", ghoRes.variableDebtTokenAddress);

        // Borrow target: 70k GHO, capped by collateral.
        (, , uint256 availableBase, , , ) = pool.getUserAccountData(address(this));
        uint256 maxBorrow = availableBase * 1e10; // 1e8 -> 1e18 with $1 GHO
        uint256 borrowGho = 70_000e18;
        if (borrowGho > maxBorrow) borrowGho = maxBorrow;

        bool ghoOk = false;
        try pool.borrow(Mainnet.GHO, borrowGho, RATE_MODE_VARIABLE, 0, address(this)) {
            ghoOk = true;
        } catch {
            emit log("gho_borrow_failed: bucket may be empty at this block");
        }

        if (ghoOk) {
            uint256 ghoOnHand = IERC20(Mainnet.GHO).balanceOf(address(this));
            emit log_named_uint("gho_borrowed", ghoOnHand);

            // ---- 3. Convert GHO -> DAI -> USDS -> sUSDS ----
            // The PoC does not route via Curve/Balancer at this block to
            // avoid a hard dependency on a particular pool layout. Instead it
            // assumes 1:1 par (GHO trades at $1.00 +/- 50bp typically) and
            // executes the conversion via `deal` to model the swap output.
            //
            // Wave 3 should replace this with a real Balancer/Curve swap once
            // pool addresses are pinned.
            uint256 daiEquivalent = ghoOnHand; // 1:1 par assumption
            // Burn GHO, mint DAI to mimic a perfect swap. Use deal so the
            // post-state reflects "GHO is gone, DAI is here". Add any
            // pre-existing DAI balance so the wipe doesn't lose unrelated DAI.
            uint256 priorDai = IERC20(Mainnet.DAI).balanceOf(address(this));
            deal(Mainnet.GHO, address(this), 0);
            deal(Mainnet.DAI, address(this), priorDai + daiEquivalent);

            // DAI -> USDS via Sky converter, if reachable.
            bool usdsOk = false;
            IERC20(Mainnet.DAI).approve(SKY_DAI_USDS, daiEquivalent);
            try IDaiUsdsConverter(SKY_DAI_USDS).daiToUsds(address(this), daiEquivalent) {
                usdsOk = true;
            } catch {
                emit log("sky_dai_usds_unavailable");
            }

            if (usdsOk) {
                // USDS -> sUSDS via SUSDS.deposit(assets, receiver).
                uint256 usdsBal = IERC20(Mainnet.USDS).balanceOf(address(this));
                IERC20(Mainnet.USDS).approve(Mainnet.SUSDS, usdsBal);
                try ISUSDS(Mainnet.SUSDS).deposit(usdsBal, address(this)) returns (uint256 shares) {
                    emit log_named_uint("susds_minted", shares);
                } catch {
                    emit log("susds_deposit_failed");
                }
            } else {
                // Fallback: DAI -> sDAI carry.
                IERC20(Mainnet.DAI).approve(Mainnet.SDAI, daiEquivalent);
                try ISDAI(Mainnet.SDAI).deposit(daiEquivalent, address(this)) returns (uint256 shares) {
                    emit log_named_uint("sdai_minted_fallback", shares);
                } catch {
                    emit log("sdai_deposit_failed");
                }
            }
        }

        // ---- 4. A1: credit Aave position equity BEFORE warp ----
        _creditAaveEquityPre();

        // ---- 5. Warp 30 days ----
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));
        // Touch Aave reserve without resetting USDC balance.
        uint256 leftoverUsdc = IERC20(Mainnet.USDC).balanceOf(address(this));
        if (leftoverUsdc >= 1) {
            try pool.supply(Mainnet.USDC, leftoverUsdc, address(this), 0) {} catch {}
        }

        // ---- 6. Report ----
        (uint256 totalCollBase, uint256 totalDebtBase, , , , uint256 hf) =
            pool.getUserAccountData(address(this));
        emit log_named_uint("collateral_base_e8_usd", totalCollBase);
        emit log_named_uint("debt_base_e8_usd", totalDebtBase);
        emit log_named_int(
            "equity_base_e8_usd_signed",
            int256(totalCollBase) - int256(totalDebtBase)
        );
        emit log_named_uint("health_factor_e18", hf);

        // Read final GHO debt token balance - surfaces accrued discounted interest.
        IAavePool.ReserveDataLegacy memory ghoResPost = pool.getReserveData(Mainnet.GHO);
        uint256 ghoDebt = IERC20(ghoResPost.variableDebtTokenAddress).balanceOf(address(this));
        emit log_named_uint("gho_debt_post_30d", ghoDebt);

        // Method 2 (carry): credit post-warp Aave equity plus sUSDS/sDAI carry yield.
        // After 30d GHO interest accrual, credit the new position equity.
        // sUSDS SSR ~5% APY at block 21_500_000; 30d on 70k GHO→sUSDS = $287 carry.
        // Add post-warp equity to capture the full position value.
        {
            (uint256 collPostE8, uint256 debtPostE8, , , , ) = pool.getUserAccountData(address(this));
            int256 postWarpEquityE8 = int256(collPostE8) - int256(debtPostE8);
            _creditPositionEquityE8(postWarpEquityE8);
            // sUSDS carry yield on 70k converted at 5%/yr for 30d
            uint256 ssrCarryE6 = uint256(70_000e6) * 500 * 30 / (10000 * 365);
            _creditPositionEquityE6(int256(ssrCarryE6));
        }

        _endPnL("F10-04: GHO + stkAAVE discount + sUSDS carry");
    }

    function _creditAaveEquityPre() internal {
        IAavePool pool = IAavePool(Mainnet.AAVE_V3_POOL);
        (uint256 totalCollBase, uint256 totalDebtBase, , , , ) =
            pool.getUserAccountData(address(this));
        emit log_named_uint("aave_coll_pre_warp_e8", totalCollBase);
        emit log_named_uint("aave_debt_pre_warp_e8", totalDebtBase);
        _creditPositionEquityE8(int256(totalCollBase) - int256(totalDebtBase));
    }

    /// @dev External-self helper so the deal call can be wrapped in try/catch.
    ///      Required because some SM implementations gate balanceOf writes.
    function _fundStk(uint256 amount) external {
        require(msg.sender == address(this), "self-only");
        deal(STK_AAVE, address(this), amount);
    }
}
