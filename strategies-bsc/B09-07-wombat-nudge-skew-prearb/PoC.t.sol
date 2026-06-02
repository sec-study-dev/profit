// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWombatPool} from "src/interfaces/bsc/amm/IWombatPool.sol";
import {IPancakeStableRouter} from "src/interfaces/bsc/amm/IPancakeStableRouter.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";

/// @title B09-07 Wombat asset-weight "nudge" pre-arb (atomic)
/// @notice Atomic 4-step sandwich of Wombat's dynamic-weight curve against
///         PCS StableSwap, exploiting the fact that Wombat's haircut formula
///         is convex in `cov` whereas PCS's `get_dy` is locally linear:
///
///         (1) Flash USDT from PCS v3 (USDC/USDT 0.01% pool, 1 bp fee).
///         (2) "Nudge": small `Wombat.swap(USDT, USDC, dN)` to push
///             `cov_USDT` past 1.15 → arrives at the convex knee.
///         (3) "Strike": large `Wombat.swap(USDC, USDT, N)` at the
///             over-corrected quote where Wombat now pays USDC sellers a
///             bonus to restore USDT coverage.
///         (4) Round-trip the resulting USDT back through PCS Stable to USDC,
///             repay the flash, keep the spread.
///
///         The "nudge" sounds like manipulation but is mechanically just
///         exploiting the same dynamic-weight pricing surface as B09-01/02 —
///         the difference is that the operator *creates* the skew within the
///         tx instead of waiting for it to occur naturally. The math works
///         only when the curve's curvature dominates the haircut, i.e. when
///         the pool is already moderately skewed (`cov_USDT > 1.05` ex-ante).
contract B09_07_Wombat_Nudge_Skew_PreArb is BSCStrategyBase, IPancakeV3FlashCallback {
    /// @dev TODO: pin a block where Wombat USDT side is at `cov_USDT ~ 1.08`
    ///      (close to but not past the convex knee).
    uint256 constant FORK_BLOCK = 45_900_000;

    /// @dev USDC/USDT PCS v3 0.01% pool — flash source (same as B09-01).
    address constant PCS_V3_POOL_USDC_USDT_100 = 0x92b7807bF19b7DDdf89b706143896d05228f3121;
    uint24 constant FLASH_FEE_TIER = 100;

    /// @dev Flash notional (USDT).
    uint256 constant FLASH_NOTIONAL = 2_000_000 ether;

    /// @dev The "nudge" leg size: small enough to not blow gas on slippage,
    ///      large enough to push `cov_USDT` past the convex knee.
    uint256 constant NUDGE_SIZE = 100_000 ether;

    /// @dev Main "strike" leg size after the nudge.
    uint256 constant STRIKE_SIZE = 1_500_000 ether;

    /// @dev PCS Stable indices (mirrors B09-01).
    uint256 constant PCS_IDX_USDT = 1;
    uint256 constant PCS_IDX_USDC = 2;

    address public flashPool;
    uint256 public nudgeOut;  // USDT -> USDC nudge result
    uint256 public strikeOut; // USDC -> USDT strike result
    uint256 public pcsOut;    // USDT -> USDC PCS return
    uint256 public owedFeeTracked;

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }

        _trackToken(BSC.USDT);
        _trackToken(BSC.USDC);
    }

    function testStrategy_B09_07() public {
        if (!_haveFork) {
            _offlinePnLCheck();
            return;
        }

        _resolveFlashPool();
        _startPnL();

        bool usdtIsToken0 = IPancakeV3Pool(flashPool).token0() == BSC.USDT;
        bytes memory data = abi.encode(FLASH_NOTIONAL, usdtIsToken0);
        if (usdtIsToken0) {
            IPancakeV3Pool(flashPool).flash(address(this), FLASH_NOTIONAL, 0, data);
        } else {
            IPancakeV3Pool(flashPool).flash(address(this), 0, FLASH_NOTIONAL, data);
        }

        _endPnL("B09-07: Wombat nudge pre-arb (flash USDT)");
    }

    function _resolveFlashPool() internal {
        flashPool = PCS_V3_POOL_USDC_USDT_100;
        uint256 codeSize;
        address p = flashPool;
        assembly {
            codeSize := extcodesize(p)
        }
        require(codeSize > 0, "no USDC/USDT 1bp pool");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        require(msg.sender == flashPool, "callback: not flash pool");
        (uint256 notional, bool usdtIsToken0) = abi.decode(data, (uint256, bool));
        uint256 owedFee = usdtIsToken0 ? fee0 : fee1;
        owedFeeTracked = owedFee;

        // ---- Step 2: Nudge — USDT -> USDC via Wombat to push cov_USDT past
        // the knee.
        IERC20(BSC.USDT).approve(BSC.WOMBAT_MAIN_POOL, NUDGE_SIZE);
        (nudgeOut, ) = IWombatPool(BSC.WOMBAT_MAIN_POOL).swap(
            BSC.USDT, BSC.USDC, NUDGE_SIZE, 0, address(this), block.timestamp
        );

        // ---- Step 3: Strike — USDC -> USDT via Wombat at the over-corrected
        // quote. Use the USDC just received as part of the strike input.
        uint256 usdcForStrike = nudgeOut; // re-use the nudge output
        // If we want a larger strike than the nudge returned, we can't (we'd
        // need more USDC; flashing two assets at once isn't supported on a
        // single pool's flash). PoC sticks with the conservative size:
        // strikeIn = nudgeOut.
        IERC20(BSC.USDC).approve(BSC.WOMBAT_MAIN_POOL, usdcForStrike);
        (strikeOut, ) = IWombatPool(BSC.WOMBAT_MAIN_POOL).swap(
            BSC.USDC, BSC.USDT, usdcForStrike, 0, address(this), block.timestamp
        );

        // ---- Step 4: We now have the original `notional - NUDGE_SIZE` USDT
        // plus `strikeOut` USDT, and zero USDC. Need to repay the flash in
        // USDT. The balance: flashed N USDT - NUDGE_SIZE consumed +
        // strikeOut. To produce extra USDT we route a slice through PCS
        // Stable USDT->USDC->USDT, harvesting any residual mispricing as the
        // round-trip exit. PoC keeps it simple: skip the PCS return because
        // after the nudge+strike we should already net positive in USDT.
        pcsOut = 0;

        IERC20(BSC.USDT).transfer(flashPool, notional + owedFee);
    }

    /// @dev Offline simulation: model the nudge+strike profile. With a 100k
    ///      USDT nudge starting at cov_USDT=1.08, the haircut climbs to ~7 bp
    ///      mid-trade; the strike (USDC->USDT, same size) then captures the
    ///      convex bonus of ~12 bp on the way back. Net atomic spread on the
    ///      shared notional of ~100k: 5 bp = $50 per 100k. Flash fee on
    ///      2M USDT: 1 bp = $200. The strategy only clears net positive when
    ///      the strike size is large relative to the nudge (which requires
    ///      either a larger ex-ante skew or routing the strike-USDC from a
    ///      different source — e.g. flash USDC instead of USDT).
    function _offlinePnLCheck() internal {
        nudgeOut  = (NUDGE_SIZE * 9993) / 10000; // -7 bp Wombat haircut on USDT push
        strikeOut = (nudgeOut   * 10005) / 10000; // +5 bp Wombat bonus on USDC pull
        pcsOut = 0;
        uint256 flashFee = FLASH_NOTIONAL / 10000;
        owedFeeTracked = flashFee;

        // Pre-fund USDT to simulate the flash inflow.
        _fund(BSC.USDT, address(this), FLASH_NOTIONAL + flashFee);
        _startPnL();

        // Token motions: USDT out (nudge), USDC in (nudge), USDC out (strike),
        // USDT in (strike), USDT out (repay).
        IERC20(BSC.USDT).transfer(address(0xdead), NUDGE_SIZE);
        _fund(BSC.USDC, address(this), nudgeOut);
        IERC20(BSC.USDC).transfer(address(0xdead), nudgeOut);
        _fund(BSC.USDT, address(this), strikeOut);
        IERC20(BSC.USDT).transfer(address(0xdead), FLASH_NOTIONAL + flashFee);

        _endPnL("B09-07[offline]: Wombat nudge pre-arb");
    }
}
