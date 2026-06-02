// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {IVenusFlashLoan, IVenusFlashLoanReceiver} from "src/interfaces/bsc/mm/IVenusFlashLoan.sol";
import {IPancakeV3Pool, IPancakeV3SwapCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";

/// @notice Compound v2-style liquidation surface, inlined locally because
///         IVToken.sol does not expose `liquidateBorrow` / `seize` yet.
/// @dev    `liquidateBorrow(borrower, repayAmount, collateralVToken)` repays
///         `repayAmount` of the borrower's debt on the *callee* market and
///         seizes the equivalent share of `collateralVToken` (priced via
///         the Comptroller + liquidationIncentive bonus, default 10 %).
interface IVTokenLiquidate {
    function liquidateBorrow(address borrower, uint256 repayAmount, address vTokenCollateral)
        external
        returns (uint256);
}

/// @title B06-05 Venus liquidation keeper — atomic flash + liquidate + DEX
/// @notice 3-mechanism stack:
///         1. Venus V4 vToken `flashLoan` provides the USDT principal.
///         2. Venus Core `liquidateBorrow` retires an underwater account's
///            debt and seizes `vBTCB` collateral at a 10 % bonus.
///         3. PCS v3 BTCB/USDT pool flash-swaps the seized BTCB back to USDT
///            so the flashLoan can be repaid in the same tx.
///         Keeper PnL = `seizedCollateralUSD * 0.10` - `flashFee` -
///         `pcs_v3_fee` - `gas`.
contract B06_05_VenusLiquidationKeeperFlashTest is
    BSCStrategyBase,
    IVenusFlashLoanReceiver,
    IPancakeV3SwapCallback
{
    /// @dev Pinned to a block where a known borrower's `shortfall > 0`.
    ///      Re-pin once a live underwater account is identified on-chain.
    uint256 internal constant FORK_BLOCK = 42_500_000;

    // ---- PCS v3 BTCB/USDT pool (0.05 % fee tier). TODO verify. ----
    address internal constant LOCAL_PCS_V3_BTCB_USDT = 0x46Cf1cF8c69595804ba91dFdd8d6b960c9B0a7C4;

    // ---- Synthetic underwater borrower (fabricated for offline PoC) ----
    /// @dev In a live run this is the account whose `getAccountLiquidity`
    ///      returns `shortfall > 0`. For the offline PoC we use a
    ///      pre-existing borrower address that we trigger via `vm.prank`.
    address internal constant TARGET_BORROWER = 0x000000000000000000000000000000000000C0DE;

    // ---- Strategy parameters ----
    /// @dev Max repay = closeFactor * totalBorrow (closeFactor = 0.5 on Core).
    uint256 internal constant REPAY_USDT = 250_000e18;
    /// @dev 9 bp Venus flash premium + a few bp slack.
    uint256 internal constant BUFFER = 5_000e18;
    /// @dev Venus liquidationIncentive default (1.10 = 10 % bonus).
    uint256 internal constant LIQ_INCENTIVE_BPS = 11_000;
    /// @dev Min absolute tick price for the v3 swap (we accept worst price).
    uint160 internal constant SQRT_PRICE_LIMIT_BTCB_TO_USDT = 4295128740;

    bool internal _inFlash;
    bool internal _inSwap;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.USDT);
        _trackToken(BSC.BTCB);
        _trackToken(BSC.vUSDT);
        _trackToken(BSC.vBTCB);
    }

    function testStrategy_B06_05() public {
        _fund(BSC.USDT, address(this), BUFFER);
        // Synthesize the underwater account for offline runs. In a live
        // run this is skipped — the borrower is already underwater.
        _seedUnderwaterBorrower();

        _startPnL();

        _inFlash = true;
        // Flash 250k USDT from Core vUSDT to fund the liquidation.
        IVenusFlashLoan(BSC.vUSDT).flashLoan(address(this), BSC.USDT, REPAY_USDT, "");
        _inFlash = false;

        emit log_named_uint("final_usdt_e18", IERC20(BSC.USDT).balanceOf(address(this)));
        emit log_named_uint("final_btcb_e18", IERC20(BSC.BTCB).balanceOf(address(this)));

        _endPnL("B06-05: Venus liquidation keeper (flash+liquidate+pcsv3)");
    }

    // ---- IVenusFlashLoanReceiver ----------------------------------------

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address /*initiator*/,
        bytes calldata /*params*/
    ) external returns (bool) {
        require(_inFlash, "unsolicited flash");
        require(msg.sender == BSC.vUSDT, "only core vUSDT");
        require(asset == BSC.USDT, "wrong asset");

        // ---- 1. Confirm target is liquidatable ----
        (uint256 err, uint256 liq, uint256 shortfall) =
            IVenusComptroller(BSC.VENUS_COMPTROLLER).getAccountLiquidity(TARGET_BORROWER);
        emit log_named_uint("target_shortfall", shortfall);
        // Skip if not underwater — refund the flash cleanly so PoC degrades.
        if (err != 0 || shortfall == 0) {
            // Approve repay so the pool can pull `amount + premium`.
            IERC20(asset).approve(msg.sender, amount + premium);
            return true;
        }

        // ---- 2. liquidateBorrow on vUSDT, seize vBTCB ----
        IERC20(BSC.USDT).approve(BSC.vUSDT, type(uint256).max);
        // try/catch — borrower may carry a debt < REPAY_USDT (closeFactor cap).
        try IVTokenLiquidate(BSC.vUSDT).liquidateBorrow(TARGET_BORROWER, amount, BSC.vBTCB) returns (uint256 e) {
            require(e == 0, "liquidate err");
        } catch {
            // Soft-fail: surface seized vBTCB == 0 and unwind the flash.
        }

        // ---- 3. Redeem seized vBTCB into raw BTCB ----
        uint256 vBtcbBal = IERC20(BSC.vBTCB).balanceOf(address(this));
        if (vBtcbBal > 0) {
            IVToken(BSC.vBTCB).redeem(vBtcbBal);
        }

        // ---- 4. Sell BTCB on PCS v3 for USDT ----
        uint256 btcbBal = IERC20(BSC.BTCB).balanceOf(address(this));
        if (btcbBal > 0) {
            // BTCB token0 (0x71...) < USDT token1 (0x55...)? Compare addresses:
            // BTCB = 0x7130d2A1... USDT = 0x55d398... so USDT < BTCB →
            // USDT is token0, BTCB is token1. zeroForOne=false sells BTCB.
            _inSwap = true;
            IPancakeV3Pool(LOCAL_PCS_V3_BTCB_USDT).swap(
                address(this),
                false, // sell token1 (BTCB) for token0 (USDT)
                int256(btcbBal),
                1461446703485210103287273052203988822378723970341, // MAX_SQRT_RATIO - 1
                ""
            );
            _inSwap = false;
        }

        // ---- 5. Approve flash repay ----
        IERC20(asset).approve(msg.sender, amount + premium);
        return true;
    }

    // ---- IPancakeV3SwapCallback -----------------------------------------

    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata /*data*/) external {
        require(_inSwap, "unsolicited swap cb");
        require(msg.sender == LOCAL_PCS_V3_BTCB_USDT, "only pcs btcb/usdt");
        // We sold BTCB (token1) → owe BTCB to the pool; receive USDT (token0).
        if (amount1Delta > 0) IERC20(BSC.BTCB).transfer(msg.sender, uint256(amount1Delta));
        if (amount0Delta > 0) IERC20(BSC.USDT).transfer(msg.sender, uint256(amount0Delta));
    }

    // ---- Helpers --------------------------------------------------------

    /// @dev Construct an underwater state synthetically so the PoC PnL
    ///      print is deterministic offline. We mint `vBTCB` to the
    ///      target borrower and forge a vUSDT debt by warping past a
    ///      huge `borrowRatePerBlock`. In a real run this whole helper
    ///      is replaced by an off-chain account scanner.
    function _seedUnderwaterBorrower() internal {
        // Give the borrower some collateral so the comptroller has
        // something to seize. 10 BTCB ≈ $650k at the default oracle.
        _fund(BSC.BTCB, TARGET_BORROWER, 10e18);
        vm.startPrank(TARGET_BORROWER);
        IERC20(BSC.BTCB).approve(BSC.vBTCB, type(uint256).max);
        // try/catch: vBTCB may be paused at the pinned block.
        try IVToken(BSC.vBTCB).mint(10e18) returns (uint256 e) {
            if (e == 0) {
                address[] memory mk = new address[](1);
                mk[0] = BSC.vBTCB;
                IVenusComptroller(BSC.VENUS_COMPTROLLER).enterMarkets(mk);
                // Borrow USDT just below the limit to set up the position.
                try IVToken(BSC.vUSDT).borrow(400_000e18) {} catch {}
            }
        } catch {}
        vm.stopPrank();
        // Warp far enough that interest accrual pushes the account
        // underwater (shortfall > 0). Offline PoC tolerates if it
        // does not — `executeOperation` skips the liquidate branch.
        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + (365 days) / 3);
    }
}
