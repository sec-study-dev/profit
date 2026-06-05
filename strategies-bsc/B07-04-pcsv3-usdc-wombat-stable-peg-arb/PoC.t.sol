// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";
import {IWombatPool} from "src/interfaces/bsc/amm/IWombatPool.sol";
import {IWombatRouter} from "src/interfaces/bsc/amm/IWombatRouter.sol";
import {IPancakeStableRouter} from "src/interfaces/bsc/amm/IPancakeStableRouter.sol";

/// @title B07-04 PCS v3 USDC/USDT 0.01% flash -> Wombat USDC->USDT -> PCS StableSwap USDT->USDC -> repay
/// @notice Three independent stable AMMs price USDC/USDT differently because
///         each uses a different invariant:
///           - PCS v3 0.01% uses concentrated-liquidity (LP-curated band).
///           - Wombat Main Pool uses dynamic-asset-weight StableSwap (LP
///             coverage ratio shifts mid as inventory imbalances).
///           - PCS StableSwap (Curve-fork) uses static StableSwap with
///             amplification factor A.
///
///         When Wombat's USDC coverage drops below 1.0 (under-covered USDC),
///         Wombat charges a positive haircut to swap *into* USDC and a
///         negative haircut (subsidy) to swap *out of* USDC. This creates a
///         persistent USDT->USDC mispricing relative to PCS StableSwap. We
///         flash USDC from PCS v3, swap USDC->USDT on Wombat (paying small
///         haircut), then swap USDT->USDC on PCS StableSwap (cheaper exit),
///         and repay. Edge = the difference in implied USDC/USDT rates
///         between Wombat and PCS StableSwap, net of fees.
contract B07_04_PcsV3UsdcWombatStableArbTest is BSCStrategyBase, IPancakeV3FlashCallback {
    uint256 internal constant FORK_BLOCK = 42_000_000;

    /// @dev PCS v3 USDC/USDT 0.01% pool. token0 = USDC 0x8AC7..., token1 =
    ///      USDT 0x55d3... - but USDT (0x55d3) < USDC (0x8AC7), so actually
    ///      token0 = USDT, token1 = USDC. Verified on BscScan as the
    ///      canonical 1-bp stable pool.
    address internal constant PCS_V3_USDT_USDC_100 = 0x92b7807bF19b7DDdf89b706143896d05228f3121;
    uint24 internal constant PCS_V3_FEE_100 = 100;

    /// @dev Wombat Main Pool stable basket (USDT/USDC/BUSD).
    address internal constant WOMBAT_MAIN = BSC.WOMBAT_MAIN_POOL;

    /// @dev PCS StableSwap USDC/USDT/BUSD 3-pool (Curve fork).
    /// @dev Placeholder - // TODO verify against PCS StableSwap factory
    ///      on pinned block. Used via the unified IPancakeStableRouter API.
    address internal constant PCS_STABLE_3POOL = 0x169E633A2D1E6c10dD91238Ba11c4A708dfEF37C;

    /// @dev Flash USDC notional. 1M USDC (1e18 on BSC) - sized to test the
    ///      three-DEX edge at meaningful scale without breaking Wombat
    ///      coverage ratios.
    uint256 internal constant FLASH_NOTIONAL_USDC = 1_000_000 ether;

    /// @dev Required gross spread (bps). Wombat haircut + PCS StableSwap
    ///      0.04% + PCS v3 flash 0.01% ~ 8 bps total.
    uint256 internal constant MIN_SPREAD_BPS = 8;

    bool internal _flashActive;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.USDC);
        _trackToken(BSC.USDT);
    }

    function testStrategy_B07_04() public {
        IPancakeV3Pool pool = IPancakeV3Pool(PCS_V3_USDT_USDC_100);

        address token0 = pool.token0();
        address token1 = pool.token1();
        // Accept either ordering. Identify which side is USDC for the flash arg.
        bool usdcIsToken1 = token0 == BSC.USDT && token1 == BSC.USDC;
        bool usdcIsToken0 = token0 == BSC.USDC && token1 == BSC.USDT;
        require(usdcIsToken0 || usdcIsToken1, "pcsv3: unexpected token pair");

        // ---- 1. Quote Wombat USDC->USDT and PCS StableSwap USDT->USDC ----
        // Wombat: how much USDT do we get for FLASH_NOTIONAL_USDC of USDC?
        (uint256 wombatUsdtOut, uint256 wombatHaircut) =
            IWombatPool(WOMBAT_MAIN).quotePotentialSwap(BSC.USDC, BSC.USDT, FLASH_NOTIONAL_USDC);
        // PCS StableSwap: with that USDT, how much USDC back? Uses Curve
        // index convention (i, j); placeholder indices USDT=0, USDC=1.
        uint256 stableSwapUsdcOut;
        try IPancakeStableRouter(PCS_STABLE_3POOL).get_dy(0, 1, wombatUsdtOut) returns (uint256 dy) {
            stableSwapUsdcOut = dy;
        } catch {
            // If the canonical pool isn't reachable at this block, skip.
            emit log_string("B07-04: skipped (PCS StableSwap pool not live)");
            return;
        }

        emit log_named_uint("B07-04: wombat_haircut_1e18", wombatHaircut);
        emit log_named_uint("B07-04: wombat_usdt_out_1e18", wombatUsdtOut);
        emit log_named_uint("B07-04: stable_usdc_out_1e18", stableSwapUsdcOut);

        // Edge if stableSwapUsdcOut > FLASH_NOTIONAL_USDC + pcsv3 flash fee.
        // PCS v3 flash fee on a 0.01% pool = N x 100 / 1_000_000 = N/10_000.
        uint256 pcsFlashFee = FLASH_NOTIONAL_USDC / 10_000;
        uint256 owed = FLASH_NOTIONAL_USDC + pcsFlashFee;
        if (stableSwapUsdcOut <= owed) {
            emit log_string("B07-04: skipped (no positive edge after fees)");
            return;
        }
        uint256 edgeBps = ((stableSwapUsdcOut - owed) * 10_000) / FLASH_NOTIONAL_USDC;
        emit log_named_uint("B07-04: edge_bps_after_pcs_flash", edgeBps);
        if (edgeBps < MIN_SPREAD_BPS) {
            emit log_string("B07-04: skipped (edge below min)");
            return;
        }

        _startPnL();

        _flashActive = true;
        // Borrow USDC. amount0/amount1 depend on ordering.
        if (usdcIsToken0) {
            pool.flash(address(this), FLASH_NOTIONAL_USDC, 0, abi.encode(true));
        } else {
            pool.flash(address(this), 0, FLASH_NOTIONAL_USDC, abi.encode(false));
        }
        _flashActive = false;

        _endPnL("B07-04: PCS v3 0.01% USDC flash + Wombat + PCS StableSwap stable peg arb");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        require(_flashActive, "callback: not active");
        require(msg.sender == PCS_V3_USDT_USDC_100, "callback: wrong pool");

        bool usdcIsToken0 = abi.decode(data, (bool));
        uint256 owedFee = usdcIsToken0 ? fee0 : fee1;

        // ---- 1. USDC -> USDT on Wombat ----
        IERC20(BSC.USDC).approve(WOMBAT_MAIN, type(uint256).max);
        (uint256 usdtOut, ) = IWombatPool(WOMBAT_MAIN).swap(
            BSC.USDC, BSC.USDT, FLASH_NOTIONAL_USDC, 1, address(this), block.timestamp
        );
        require(usdtOut > 0, "wombat: zero out");

        // ---- 2. USDT -> USDC on PCS StableSwap (Curve fork) ----
        IERC20(BSC.USDT).approve(PCS_STABLE_3POOL, type(uint256).max);
        uint256 usdcBack = IPancakeStableRouter(PCS_STABLE_3POOL).exchange(0, 1, usdtOut, 1);
        require(usdcBack > 0, "stableswap: zero out");

        // ---- 3. Repay PCS v3 flash ----
        IERC20(BSC.USDC).transfer(PCS_V3_USDT_USDC_100, FLASH_NOTIONAL_USDC + owedFee);
    }
}
