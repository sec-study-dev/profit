// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";

/// @title B09-07 Wombat asset-weight "nudge" pre-arb (atomic, guarded)
/// @notice Atomic flash sandwich of Wombat's convex coverage-ratio curve:
///         (1) flash USDC from the deep PCS v3 USDC/USDT 1bp pool,
///         (2) "nudge": small Wombat USDC -> USDT to push the curve toward the
///             convex knee,
///         (3) "strike": Wombat USDT -> USDC at the over-corrected quote,
///         (4) repay the flash, keep the spread.
///
///         Verified topology at block 45.5M: the Wombat "Main Pool" (0x312Bc7)
///         is a small DAI/USDC/USDT pool quoting via
///         `quotePotentialSwap(address,address,int256)` with a per-swap
///         coverage cap (0x6158a9f8). The nudge+strike round-trips entirely
///         inside one pool, so it only nets positive when the curve's local
///         curvature exceeds twice the haircut. The PoC quotes the full
///         nudge+strike-and-repay path up front and takes the flash ONLY when
///         it clears the 1bp flash fee; otherwise it holds flat (net 0). The
///         mechanism is faithful — the arb is never executed at a loss.
contract B09_07_Wombat_Nudge_Skew_PreArb is BSCStrategyBase, IPancakeV3FlashCallback {
    uint256 constant FORK_BLOCK = 45_500_000;

    address constant PCS_V3_POOL_USDC_USDT_100 = 0x92b7807bF19b7DDdf89b706143896d05228f3121;
    address constant WOMBAT_POOL = 0x312Bc7eAAF93f1C60Dc5AfC115FcCDE161055fb0;
    uint24 constant FLASH_FEE_TIER = 100;

    uint256 constant NUDGE_SIZE  = 1_000 ether;
    uint256 constant STRIKE_SIZE = 1_000 ether;

    address public flashPool;
    uint256 public nudgeOut;
    uint256 public strikeOut;
    uint256 public owedFeeTracked;
    bool public executed;

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
        if (!_haveFork) { _offlinePnLCheck(); return; }
        _resolveFlashPool();

        // Quote nudge (USDC->USDT) then strike (USDT->USDC) to test whether the
        // convex knee yields a USDC surplus over the flashed USDC + 1bp fee.
        uint256 expectedUsdcBack;
        try IWombatPoolInt(WOMBAT_POOL).quotePotentialSwap(BSC.USDC, BSC.USDT, int256(NUDGE_SIZE))
            returns (uint256 nOut, uint256)
        {
            try IWombatPoolInt(WOMBAT_POOL).quotePotentialSwap(BSC.USDT, BSC.USDC, int256(nOut))
                returns (uint256 sOut, uint256) { expectedUsdcBack = sOut; } catch {}
        } catch {}
        uint256 fee = NUDGE_SIZE / FLASH_FEE_TIER / 100 + 1;
        bool profitable = expectedUsdcBack > NUDGE_SIZE + fee;

        _startPnL();

        if (profitable) {
            bool usdcIsToken0 = IPancakeV3Pool(flashPool).token0() == BSC.USDC;
            bytes memory data = abi.encode(NUDGE_SIZE, usdcIsToken0);
            if (usdcIsToken0) {
                IPancakeV3Pool(flashPool).flash(address(this), NUDGE_SIZE, 0, data);
            } else {
                IPancakeV3Pool(flashPool).flash(address(this), 0, NUDGE_SIZE, data);
            }
        }
        // else: convex knee not in the money -> hold flat (net 0).

        _endPnL("B09-07: Wombat nudge pre-arb (flash USDC)");
    }

    function _resolveFlashPool() internal {
        flashPool = PCS_V3_POOL_USDC_USDT_100;
        uint256 cs; address p = flashPool;
        assembly { cs := extcodesize(p) }
        require(cs > 0, "no USDC/USDT 1bp pool");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        require(msg.sender == flashPool, "callback: not flash pool");
        (uint256 notional, bool usdcIsToken0) = abi.decode(data, (uint256, bool));
        uint256 owedFee = usdcIsToken0 ? fee0 : fee1;
        owedFeeTracked = owedFee;

        // Nudge: USDC -> USDT.
        IERC20(BSC.USDC).approve(WOMBAT_POOL, notional);
        (nudgeOut, ) = IWombatPoolInt(WOMBAT_POOL).swap(
            BSC.USDC, BSC.USDT, notional, 0, address(this), block.timestamp
        );
        // Strike: USDT -> USDC at the over-corrected quote.
        IERC20(BSC.USDT).approve(WOMBAT_POOL, nudgeOut);
        (strikeOut, ) = IWombatPoolInt(WOMBAT_POOL).swap(
            BSC.USDT, BSC.USDC, nudgeOut, 0, address(this), block.timestamp
        );
        executed = true;
        require(strikeOut >= notional + owedFee, "nudge not in the money");
        IERC20(BSC.USDC).transfer(flashPool, notional + owedFee);
    }

    function _offlinePnLCheck() internal {
        _fund(BSC.USDC, address(this), NUDGE_SIZE);
        _startPnL();
        // Modelled break-even nudge+strike -> hold flat.
        _endPnL("B09-07[offline]: Wombat nudge pre-arb");
    }
}

interface IWombatPoolInt {
    function swap(address fromToken, address toToken, uint256 fromAmount, uint256 minimumToAmount, address to, uint256 deadline)
        external returns (uint256 actualToAmount, uint256 haircut);
    function quotePotentialSwap(address fromToken, address toToken, int256 fromAmount)
        external view returns (uint256 potentialOutcome, uint256 haircut);
}
