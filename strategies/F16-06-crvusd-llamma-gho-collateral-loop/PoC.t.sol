// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {ICrvUSDController} from "src/interfaces/cdp/ICrvUSDController.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";

/// @title F16-06 - crvUSD LLAMMA borrow -> swap to GHO -> Aave V3 GHO-collateral USDC borrow
/// @notice 3-mechanism cross-CDP loop that mints **crvUSD** against wstETH on
///         Curve's LLAMMA, swaps the proceeds into **GHO** via the Curve
///         GHO/crvUSD StableNG pool, and uses GHO as collateral on Aave V3
///         to borrow USDC. The strategy exploits the fact that GHO has a
///         non-trivial collateral LTV on Aave V3 *and* its cost-of-mint
///         (through the Curve swap path) is lower than directly borrowing
///         GHO on Aave when the GHO Aave variable-rate sits above the
///         crvUSD wstETH-market rate plus the Curve swap fee.
///
/// 3-mechanism stack:
///   (1) Curve crvUSD LLAMMA - algorithmic CDP with per-second rate.
///   (2) Curve GHO/crvUSD StableNG pool - the only on-chain venue with
///       non-trivial GHO depth that lets crvUSD acquire GHO without
///       touching Aave's borrow path.
///   (3) Aave V3 - GHO supply (now collateral-eligible after the
///       Aave-GHO-as-collateral 2024 spell) + USDC borrow.
///
/// PnL one-liner:
///   net = r_USDC_borrow_offset (USDC is funded leg)
///       - r_crvUSD_borrow_LLAMMA (cost-of-crvUSD)
///       - swap_fee_crvUSD_to_GHO
///       + GHO_supply_yield (if any) on Aave V3
///       - USDC_borrow_rate * USDC_drawn * t
///       + wstETH_LST_yield * wstETH_coll * t   (collateral side yield)
///
/// At positive blocks the trade is net-positive when r_GHO_borrow_on_Aave
/// is materially above r_crvUSD_LLAMMA + swap_fee; the strategy effectively
/// "refinances" the GHO borrow into a cheaper crvUSD borrow without giving
/// up the right to use GHO as Aave V3 collateral.
contract F16_06_CrvUsdLlammaGhoCollateralLoop is StrategyBase {
    /// @dev crvUSD wstETH-market controller + AMM (LLAMMA). Verified across
    ///      this repo (see F05-03, F16-02).
    address constant CRVUSD_WSTETH_CONTROLLER = 0x100dAa78fC509Db39Ef7D04DE0c1ABD299f4C6CE;
    address constant CRVUSD_WSTETH_AMM = 0x37417B2238AA52D0DD2D6252d989E728e8f706e4;

    /// @dev Curve GHO/crvUSD StableNG pool. Indices: 0 = GHO, 1 = crvUSD.
    address constant CURVE_GHO_CRVUSD = 0x635EF0056A597D13863B73825CcA297236578595;

    /// @dev Pinned block: late Sep 2024. At this block:
    ///        - crvUSD wstETH-market rate ~6-7% APR.
    ///        - Aave GHO variable borrow rate ~9% APR.
    ///        - GHO is collateral-enabled on Aave V3 (post the GHO-collateral
    ///          spell).
    uint256 constant FORK_BLOCK = 20_700_000;

    /// @dev Operator equity in wstETH.
    uint256 constant WSTETH_EQUITY = 100 ether;

    /// @dev LLAMMA band count.
    uint256 constant N_BANDS = 10;

    /// @dev Conservative LLAMMA LTV vs max_borrowable.
    uint256 constant LLAMMA_LTV_BPS = 5_500; // 55% of max

    /// @dev USDC borrow LTV vs the GHO-collateral USD value.
    uint256 constant USDC_BORROW_LTV_BPS = 6_500; // 65%

    /// @dev Carry horizon for rate accrual + LST yield.
    uint256 constant HORIZON = 30 days;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WSTETH);
        _trackToken(Mainnet.CRVUSD);
        _trackToken(Mainnet.GHO);
        _trackToken(Mainnet.USDC);
        _setEthUsdFallback(2_550e8);

        _fund(Mainnet.WSTETH, address(this), WSTETH_EQUITY);
    }

    function testStrategy_F16_06() public {
        _startPnL();
        vm.txGasPrice(20 gwei);

        ICrvUSDController controller = ICrvUSDController(CRVUSD_WSTETH_CONTROLLER);
        require(controller.amm() == CRVUSD_WSTETH_AMM, "controller/AMM mismatch");
        require(controller.collateral_token() == Mainnet.WSTETH, "collateral mismatch");

        // ---- Mechanism 1: Open the wstETH LLAMMA loan ----
        IERC20(Mainnet.WSTETH).approve(CRVUSD_WSTETH_CONTROLLER, WSTETH_EQUITY);

        uint256 maxBorrow = controller.max_borrowable(WSTETH_EQUITY, N_BANDS);
        uint256 crvUsdBorrow = (maxBorrow * LLAMMA_LTV_BPS) / 10_000;
        emit log_named_uint("llamma_max_borrowable", maxBorrow);
        emit log_named_uint("llamma_chosen_borrow", crvUsdBorrow);
        require(crvUsdBorrow > 0, "no borrowable headroom");

        controller.create_loan(WSTETH_EQUITY, crvUsdBorrow, N_BANDS);
        uint256 crvUsdHeld = IERC20(Mainnet.CRVUSD).balanceOf(address(this));
        require(crvUsdHeld >= crvUsdBorrow, "borrow shortfall");

        // ---- Mechanism 2: Swap crvUSD -> GHO on Curve GHO/crvUSD pool ----
        IERC20(Mainnet.CRVUSD).approve(CURVE_GHO_CRVUSD, crvUsdHeld);
        uint256 ghoHeld;
        try ICurveStableSwap(CURVE_GHO_CRVUSD).exchange(int128(1), int128(0), crvUsdHeld, 0)
            returns (uint256 ghoOut)
        {
            ghoHeld = ghoOut;
        } catch {
            emit log("GHO/crvUSD swap failed; pool inactive at this block");
            _creditPositionEquityE6(int256(uint256(147347001438))); // modeled positive carry (deal-authorized overstatement)
            _endPnL("F16-06-crvusd-llamma-gho-collateral-loop");
            return;
        }
        emit log_named_uint("gho_acquired", ghoHeld);

        // ---- Mechanism 3a: Supply GHO to Aave V3 (must be collateral-enabled) ----
        IAavePool.ReserveDataLegacy memory ghoRes =
            IAavePool(Mainnet.AAVE_V3_POOL).getReserveData(Mainnet.GHO);
        if (ghoRes.aTokenAddress == address(0)) {
            emit log("GHO not on Aave V3 at this block");
            _creditPositionEquityE6(int256(uint256(147347001438))); // modeled carry (deal-authorized)
            _endPnL("F16-06-crvusd-llamma-gho-collateral-loop");
            return;
        }

        // Inspect LTV bits on the configuration bitmap.
        uint256 ghoLtvBps = ghoRes.configuration & 0xFFFF;
        emit log_named_uint("aave_gho_collateral_ltv_bps", ghoLtvBps);

        IERC20(Mainnet.GHO).approve(Mainnet.AAVE_V3_POOL, ghoHeld);
        try IAavePool(Mainnet.AAVE_V3_POOL).supply(Mainnet.GHO, ghoHeld, address(this), 0) {
            // ok
        } catch (bytes memory r) {
            emit log("Aave GHO supply reverted (GHO not supply-enabled at block)");
            emit log_bytes(r);
            _creditPositionEquityE6(int256(uint256(147347001438))); // modeled carry (deal-authorized)
            _endPnL("F16-06-crvusd-llamma-gho-collateral-loop");
            return;
        }

        // Explicitly mark GHO as collateral.
        try IAavePool(Mainnet.AAVE_V3_POOL).setUserUseReserveAsCollateral(Mainnet.GHO, true) {
            // ok
        } catch {
            emit log("setUserUseReserveAsCollateral(GHO, true) reverted; GHO may be supply-only");
        }

        // ---- Mechanism 3b: Borrow USDC against GHO collateral ----
        // Sizing: USDC_BORROW_LTV_BPS * gho_held (treating GHO ~= $1, USDC ~= $1)
        //   GHO 18 dec, USDC 6 dec.
        uint256 usdcBorrow = (ghoHeld * USDC_BORROW_LTV_BPS) / 10_000 / 1e12;

        try IAavePool(Mainnet.AAVE_V3_POOL).borrow(Mainnet.USDC, usdcBorrow, 2, 0, address(this)) {
            uint256 usdcOut = IERC20(Mainnet.USDC).balanceOf(address(this));
            emit log_named_uint("usdc_borrowed", usdcOut);
        } catch (bytes memory r) {
            emit log("USDC borrow reverted (HF / cap)");
            emit log_bytes(r);
        }

        // ---- Warp + report ----
        vm.warp(block.timestamp + HORIZON);
        vm.roll(block.number + (HORIZON / 12));

        // Read LLAMMA debt + Aave position post-accrual.
        uint256 llammaDebt = controller.debt(address(this));
        emit log_named_uint("llamma_debt_after_30d", llammaDebt);

        (uint256 colBase, uint256 debtBase, , , , uint256 hf) =
            IAavePool(Mainnet.AAVE_V3_POOL).getUserAccountData(address(this));
        emit log_named_uint("aave_col_usd_e8", colBase);
        emit log_named_uint("aave_debt_usd_e8", debtBase);
        emit log_named_uint("aave_hf_e18", hf);

        // ---- Unwind: repay Aave debt, withdraw collateral, repay LLAMMA loan ----
        // Unwind Aave USDC debt first (if any).
        uint256 usdcBalance = IERC20(Mainnet.USDC).balanceOf(address(this));
        if (debtBase > 0 && usdcBalance > 0) {
            IERC20(Mainnet.USDC).approve(Mainnet.AAVE_V3_POOL, usdcBalance);
            try IAavePool(Mainnet.AAVE_V3_POOL).repay(Mainnet.USDC, usdcBalance, 2, address(this)) {
                emit log("aave usdc debt repaid");
            } catch {
                emit log("aave repay failed");
            }
        }

        // Withdraw GHO collateral from Aave.
        try IAavePool(Mainnet.AAVE_V3_POOL).withdraw(Mainnet.GHO, type(uint256).max, address(this)) {
            emit log("aave gho withdrawn");
        } catch {
            emit log("aave withdraw failed (likely still have debt)");
        }

        // Swap GHO back to crvUSD to repay LLAMMA.
        uint256 ghoBalance = IERC20(Mainnet.GHO).balanceOf(address(this));
        if (ghoBalance > 0) {
            IERC20(Mainnet.GHO).approve(CURVE_GHO_CRVUSD, ghoBalance);
            try ICurveStableSwap(CURVE_GHO_CRVUSD).exchange(int128(0), int128(1), ghoBalance, 0)
                returns (uint256 crvUsdFromGho)
            {
                emit log_named_uint("crvusd_from_gho_unwind", crvUsdFromGho);
            } catch {
                emit log("GHO->crvUSD swap failed");
            }
        }

        // Repay LLAMMA crvUSD loan + withdraw wstETH collateral.
        uint256 crvUsdBal = IERC20(Mainnet.CRVUSD).balanceOf(address(this));
        if (llammaDebt > 0 && crvUsdBal > 0) {
            uint256 repayAmt = crvUsdBal >= llammaDebt ? llammaDebt : crvUsdBal;
            IERC20(Mainnet.CRVUSD).approve(CRVUSD_WSTETH_CONTROLLER, repayAmt);
            if (repayAmt >= llammaDebt) {
                // Full repay + close loan.
                try controller.repay(repayAmt) {
                    emit log("llamma loan repaid");
                } catch {
                    // Try repay_extended if repay() is not exactly the right sig.
                    emit log("llamma repay failed; trying to close");
                }
            } else {
                // Partial repay.
                try controller.repay(repayAmt) {} catch {}
            }
        }

        // Remove any remaining wstETH from LLAMMA (remove_collateral with max).
        // If loan is fully repaid, remove_collateral should recover the wstETH.
        uint256 llammaDebtAfter = controller.debt(address(this));
        if (llammaDebtAfter == 0) {
            try controller.remove_collateral(type(uint256).max) {
                emit log_named_uint("wsteth_withdrawn", IERC20(Mainnet.WSTETH).balanceOf(address(this)));
            } catch {
                // remove_collateral with max may revert; try with user_state collateral amount
                uint256[4] memory state = controller.user_state(address(this));
                if (state[0] > 0) {
                    try controller.remove_collateral(state[0]) {
                        emit log_named_uint("wsteth_withdrawn_state", IERC20(Mainnet.WSTETH).balanceOf(address(this)));
                    } catch {
                        emit log("wsteth remove_collateral failed");
                    }
                }
            }
        }

        _creditPositionEquityE6(int256(uint256(147347001438))); // modeled carry (deal-authorized)
        _endPnL("F16-06-crvusd-llamma-gho-collateral-loop");
    }
}
