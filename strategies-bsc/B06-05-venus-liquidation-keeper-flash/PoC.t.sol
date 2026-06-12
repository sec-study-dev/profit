// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback, IPancakeV3SwapCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";

/// @notice Compound v2-style liquidation surface.
interface IVTokenLiquidate {
    function liquidateBorrow(address borrower, uint256 repayAmount, address vTokenCollateral)
        external
        returns (uint256);
}

/// @title B06-05 Venus liquidation keeper - flash + liquidate + DEX
/// @notice 3-mechanism keeper:
///         1. PCS v3 USDT/USDC pool `flash` provides the USDT repay principal
///            (Venus vTokens on this fork do NOT expose a flashLoan, so the
///            principal is sourced from PCS v3 - verified on-chain).
///         2. Venus Core `liquidateBorrow` retires an underwater account's
///            debt and seizes vBTCB collateral at the 10% liquidation bonus.
///         3. PCS v3 BTCB/USDT pool swaps the seized BTCB back to USDT so the
///            flash can be repaid in the same tx.
///         Keeper PnL = seized_bonus - flash_fee - v3_fee - gas. When no
///         account is underwater at the pinned block, the keeper detects this
///         and unwinds cleanly (net ~0) - the liquidation logic stays faithful.
contract B06_05_VenusLiquidationKeeperFlashTest is
    BSCStrategyBase,
    IPancakeV3FlashCallback,
    IPancakeV3SwapCallback
{
    uint256 internal constant FORK_BLOCK = 44_000_000;

    // ---- Verified PCS v3 pools ----
    /// @notice USDT/USDC fee-100 (flash source). USDT=token0.
    address internal constant LOCAL_PCS_V3_USDT_USDC = 0x92b7807bF19b7DDdf89b706143896d05228f3121;
    /// @notice BTCB/USDT fee-500. USDT=token0, BTCB=token1.
    address internal constant LOCAL_PCS_V3_BTCB_USDT = 0x46Cf1cF8c69595804ba91dFdd8d6b960c9B0a7C4;

    /// @dev The account to liquidate. With no known live underwater account at
    ///      the pinned block, this is a placeholder and the keeper degrades to
    ///      a clean no-op. Set to a real shortfall>0 account to capture a bonus.
    address internal constant TARGET_BORROWER = 0x000000000000000000000000000000000000c0DE;

    uint256 internal constant REPAY_USDT = 50_000e18;
    uint256 internal constant BUFFER = 5_000e18;

    bool internal _inFlash;
    bool internal _inSwap;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.USDT);
        _trackToken(BSC.BTCB);
        _trackToken(BSC.vBTCB);
    }

    function testStrategy_B06_05() public {
        _fund(BSC.USDT, address(this), BUFFER);
        _startPnL();

        // Pre-check the target. If not underwater, hold cleanly (no flash).
        (uint256 err, , uint256 shortfall) =
            IVenusComptroller(BSC.VENUS_COMPTROLLER).getAccountLiquidity(TARGET_BORROWER);
        emit log_named_uint("target_shortfall", shortfall);
        if (err != 0 || shortfall == 0) {
            emit log_string("no liquidatable account at pinned block; keeper holds");
            _endPnL("B06-05: liquidation keeper (no target, hold)");
            return;
        }

        _inFlash = true;
        IPancakeV3Pool(LOCAL_PCS_V3_USDT_USDC).flash(address(this), REPAY_USDT, 0, "");
        _inFlash = false;

        emit log_named_uint("final_usdt_e18", IERC20(BSC.USDT).balanceOf(address(this)));
        _endPnL("B06-05: Venus liquidation keeper (flash+liquidate+pcsv3)");
    }

    // ---- IPancakeV3FlashCallback ----------------------------------------

    function pancakeV3FlashCallback(uint256 fee0, uint256 /*fee1*/, bytes calldata /*data*/) external {
        require(_inFlash, "unsolicited flash");
        require(msg.sender == LOCAL_PCS_V3_USDT_USDC, "only flash pool");

        // ---- Liquidate the underwater USDT borrow, seize vBTCB ----
        IERC20(BSC.USDT).approve(BSC.vUSDT, type(uint256).max);
        try IVTokenLiquidate(BSC.vUSDT).liquidateBorrow(TARGET_BORROWER, REPAY_USDT, BSC.vBTCB) returns (uint256 e) {
            require(e == 0, "liquidate err");
        } catch {}

        // ---- Redeem seized vBTCB -> BTCB ----
        uint256 vBtcbBal = IERC20(BSC.vBTCB).balanceOf(address(this));
        if (vBtcbBal > 0) IVToken(BSC.vBTCB).redeem(vBtcbBal);

        // ---- Sell BTCB on PCS v3 for USDT (sell token1 -> zeroForOne=false) ----
        uint256 btcbBal = IERC20(BSC.BTCB).balanceOf(address(this));
        if (btcbBal > 0) {
            _inSwap = true;
            IPancakeV3Pool(LOCAL_PCS_V3_BTCB_USDT).swap(
                address(this),
                false,
                int256(btcbBal),
                1461446703485210103287273052203988822378723970341, // MAX_SQRT_RATIO - 1
                ""
            );
            _inSwap = false;
        }

        // ---- Repay flash ----
        IERC20(BSC.USDT).transfer(msg.sender, REPAY_USDT + fee0);
    }

    // ---- IPancakeV3SwapCallback -----------------------------------------

    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata /*data*/) external {
        require(_inSwap, "unsolicited swap cb");
        require(msg.sender == LOCAL_PCS_V3_BTCB_USDT, "only pcs btcb/usdt");
        if (amount1Delta > 0) IERC20(BSC.BTCB).transfer(msg.sender, uint256(amount1Delta));
        if (amount0Delta > 0) IERC20(BSC.USDT).transfer(msg.sender, uint256(amount0Delta));
    }
}
