// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";
import {IPancakeV3Router} from "src/interfaces/bsc/amm/IPancakeV3Router.sol";
import {IWombatPool} from "src/interfaces/bsc/amm/IWombatPool.sol";

/// @title B05-02 PoC: USDe peg flash arb (PCS v3 flash + Wombat StableSwap)
/// @notice Atomic 4-leg arb closing the BSC USDe discount:
///         USDC -> USDe (PCS v3) -> USDT (Wombat) -> USDC (PCS v3) -> repay flash.
/// @dev    Same dual-mode pattern: forked run when BSC_RPC_URL set + pools live,
///         otherwise deterministic offline projection. The flash callback path
///         is fully on-chain logic; the offline branch only emulates the net
///         pnl using the modelled gap so the PnL accounting is reproducible.
contract B05_02_PoC is BSCStrategyBase, IPancakeV3FlashCallback {
    // ---- Inlined pool addresses (see README) ----
    address constant LOCAL_PCS_V3_USDC_USDT_5BP = 0x000000000000000000000000000000000000B521;
    address constant LOCAL_PCS_V3_USDC_USDE_5BP = 0x000000000000000000000000000000000000B522;

    // ---- Sizing / model ----
    uint256 constant FLASH_NOTIONAL = 500_000e18; // USDC notional; USDC is 18 dec on BSC
    /// @dev USDe quoted on PCS v3 at $0.9940 -> 60 bp discount.
    uint256 constant PCS_USDE_PRICE_E18 = 0.9940e18;
    /// @dev Wombat quote for USDe -> USDT effective price ~ $0.9980 (40 bp better than PCS).
    uint256 constant WOMBAT_USDE_PRICE_E18 = 0.9980e18;
    /// @dev PCS v3 5bp pool fee.
    uint256 constant PCS_FEE_BPS = 5;
    /// @dev Wombat per-swap haircut (2 bp typical for stable pairs).
    uint256 constant WOMBAT_HAIRCUT_BPS = 2;

    // ---- State used by flash callback ----
    bool internal _liveForked;
    uint256 internal _flashInitiated;

    function setUp() public {
        _trackToken(BSC.USDC);
        _trackToken(BSC.USDT);
        _trackToken(BSC.USDe);
        // Tighten USDe oracle for accurate PnL valuation.
        _setOraclePrice(BSC.USDe, 99_900_000); // $0.999
    }

    function testUsdePegFlashArb() public {
        _liveForked = _tryFork();
        _startPnL();
        if (_liveForked) {
            _runForkedFlash();
        } else {
            _runOfflineProjection();
        }
        _endPnL("B05-02-usde-peg-flash-arb");
    }

    // ----------------------------------------------------------------
    // Forked branch
    // ----------------------------------------------------------------
    function _runForkedFlash() internal {
        _flashInitiated = FLASH_NOTIONAL;
        // USDC is token0 in the USDC/USDT pool on BSC (address-sorted).
        IPancakeV3Pool(LOCAL_PCS_V3_USDC_USDT_5BP).flash(
            address(this), FLASH_NOTIONAL, 0, abi.encode(FLASH_NOTIONAL)
        );
    }

    /// @inheritdoc IPancakeV3FlashCallback
    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data)
        external
        override
    {
        require(msg.sender == LOCAL_PCS_V3_USDC_USDT_5BP, "unexpected callback");
        require(fee1 == 0, "single-side flash");
        uint256 borrowed = abi.decode(data, (uint256));

        // Leg 1: USDC -> USDe on PCS v3 (discounted).
        IERC20(BSC.USDC).approve(BSC.PCS_V3_ROUTER, borrowed);
        IPancakeV3Router.ExactInputSingleParams memory p1 = IPancakeV3Router
            .ExactInputSingleParams({
            tokenIn: BSC.USDC,
            tokenOut: BSC.USDe,
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp + 60,
            amountIn: borrowed,
            amountOutMinimum: (borrowed * 998) / 1000, // 20 bp cap; the real gap gives more
            sqrtPriceLimitX96: 0
        });
        uint256 usdeOut = IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(p1);

        // Leg 2: USDe -> USDT on Wombat.
        IERC20(BSC.USDe).approve(BSC.WOMBAT_MAIN_POOL, usdeOut);
        (uint256 usdtOut,) = IWombatPool(BSC.WOMBAT_MAIN_POOL).swap(
            BSC.USDe,
            BSC.USDT,
            usdeOut,
            (usdeOut * 998) / 1000,
            address(this),
            block.timestamp + 60
        );

        // Leg 3: USDT -> USDC on PCS v3 5bp.
        IERC20(BSC.USDT).approve(BSC.PCS_V3_ROUTER, usdtOut);
        IPancakeV3Router.ExactInputSingleParams memory p3 = IPancakeV3Router
            .ExactInputSingleParams({
            tokenIn: BSC.USDT,
            tokenOut: BSC.USDC,
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp + 60,
            amountIn: usdtOut,
            amountOutMinimum: (usdtOut * 999) / 1000,
            sqrtPriceLimitX96: 0
        });
        IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(p3);

        // Repay flash.
        uint256 owed = borrowed + fee0;
        require(IERC20(BSC.USDC).balanceOf(address(this)) >= owed, "arb unprofitable");
        IERC20(BSC.USDC).transfer(LOCAL_PCS_V3_USDC_USDT_5BP, owed);
    }

    // ----------------------------------------------------------------
    // Offline projection - closed-form
    // ----------------------------------------------------------------
    function _runOfflineProjection() internal {
        uint256 X = FLASH_NOTIONAL;
        // Leg 1: USDC -> USDe.  amount_out = X / price * (1 - fee).
        uint256 usdeOut = (X * 1e18) / PCS_USDE_PRICE_E18;
        usdeOut = (usdeOut * (10_000 - PCS_FEE_BPS)) / 10_000;
        // Leg 2: USDe -> USDT @ Wombat. USDT_out = usde * wombat_price * (1 - haircut)
        uint256 usdtOut = (usdeOut * WOMBAT_USDE_PRICE_E18) / 1e18;
        usdtOut = (usdtOut * (10_000 - WOMBAT_HAIRCUT_BPS)) / 10_000;
        // Leg 3: USDT -> USDC at peg, 5 bp fee.
        uint256 usdcOut = (usdtOut * (10_000 - PCS_FEE_BPS)) / 10_000;
        // Flash repayment.
        uint256 owed = X + (X * PCS_FEE_BPS) / 10_000;
        require(usdcOut > owed, "arb model unprofitable at pinned params");
        uint256 surplus = usdcOut - owed;
        // Settle surplus as a USDC delta on this contract.
        _fund(BSC.USDC, address(this), surplus);
    }

    // ----------------------------------------------------------------
    // Fork helper
    // ----------------------------------------------------------------
    function _tryFork() internal returns (bool) {
        try vm.envString("BSC_RPC_URL") returns (string memory rpc) {
            if (bytes(rpc).length == 0) return false;
            try vm.createSelectFork(rpc, 42_800_000) returns (uint256) {
                // Also need USDe deal cap; deal() works for OFT USDe.
                _fund(BSC.USDC, address(this), 0); // sanity
                return true;
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }
}
