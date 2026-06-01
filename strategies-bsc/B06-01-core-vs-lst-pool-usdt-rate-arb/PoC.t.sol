// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {IVenusFlashLoan, IVenusFlashLoanReceiver} from "src/interfaces/bsc/mm/IVenusFlashLoan.sol";

/// @title B06-01 Venus Core ↔ LST isolated pool USDT rate arb
/// @notice Atomic flashLoan from Core vUSDT, supply→borrow on LST isolated
///         pool's vUSDT, hold the spread for 30 days. Demonstrates that the
///         same EOA can simultaneously hold positions in two Comptrollers,
///         and that Venus V4 flash loans can bootstrap an arb with only the
///         premium + safety buffer as principal.
contract B06_01_VenusCoreLSTPoolUSDTArbTest is BSCStrategyBase, IVenusFlashLoanReceiver {
    /// @dev LST pool Comptroller has been live for several weeks; rates have
    ///      settled into a ~200 bp band. Re-pin after BSC_RPC_URL is set.
    uint256 internal constant FORK_BLOCK = 42_500_000;

    // ---- Inlined isolated-pool addresses (BSC.sol carries only Core) ----

    /// @notice Venus V4 LST (Liquid Staked BNB) isolated-pool Comptroller.
    /// TODO verify: PoolRegistry-deployed Unitroller for the LST pool.
    address internal constant LOCAL_LST_COMPTROLLER = 0x596B11acAACF03217287939f88d63b51d3771704;
    /// @notice LST pool's vUSDT listing. TODO verify.
    address internal constant LOCAL_VUSDT_LST = 0x1D8BB512F56451ddEF820D6FE0FAa0B1b655a263;

    // ---- Strategy parameters ----

    /// @dev 1M USDT notional flashed from Core vUSDT.
    uint256 internal constant FLASH_AMOUNT = 1_000_000e18;
    /// @dev Borrow back ~90 % of the supplied notional from LST pool.
    uint256 internal constant BORROW_BPS = 9_000;
    /// @dev Pre-funded buffer to cover flash premium + safety.
    uint256 internal constant BUFFER = 100_000e18;
    /// @dev Hold horizon for the carry leg.
    uint256 internal constant HOLD_DAYS = 30;
    /// @dev BSC averages ~3 s per block.
    uint256 internal constant SECS_PER_BLOCK = 3;

    bool internal _inFlash;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.USDT);
        _trackToken(BSC.vUSDT);
        _trackToken(LOCAL_VUSDT_LST);
    }

    function testStrategy_B06_01() public {
        // Fund the safety buffer in real USDT.
        _fund(BSC.USDT, address(this), BUFFER);
        _startPnL();

        // Kick off the flash. The callback (`executeOperation`) does the
        // actual supply/borrow on the LST pool and returns enough USDT to
        // repay the flash + premium.
        _inFlash = true;
        IVenusFlashLoan(BSC.vUSDT).flashLoan(address(this), BSC.USDT, FLASH_AMOUNT, "");
        _inFlash = false;

        // Now we hold: supplier-side LST pool position (~FLASH_AMOUNT) minus
        // a borrower-side debt (~FLASH_AMOUNT * 0.9), plus the buffer minus
        // the flash premium that was burned.
        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
        vm.roll(block.number + (HOLD_DAYS * 1 days) / SECS_PER_BLOCK);

        // Force interest accrual on both legs.
        IVToken(LOCAL_VUSDT_LST).balanceOfUnderlying(address(this));
        uint256 debt = IVToken(LOCAL_VUSDT_LST).borrowBalanceCurrent(address(this));
        emit log_named_uint("lst_pool_vusdt_debt_e18", debt);

        // For PnL, redeem all and repay debt — net cash is the spread.
        // 1. Borrow more USDT from buffer-side, repay LST debt.
        uint256 dbtNow = IVToken(LOCAL_VUSDT_LST).borrowBalanceCurrent(address(this));
        IERC20(BSC.USDT).approve(LOCAL_VUSDT_LST, type(uint256).max);
        // If buffer + redeem can't fully cover, repay max of buffer.
        uint256 myUsdt = IERC20(BSC.USDT).balanceOf(address(this));
        uint256 repay = dbtNow < myUsdt ? dbtNow : myUsdt;
        if (repay > 0) IVToken(LOCAL_VUSDT_LST).repayBorrow(repay);

        // 2. Redeem entire LST supply (after partial repay there is room).
        uint256 vBal = IERC20(LOCAL_VUSDT_LST).balanceOf(address(this));
        if (vBal > 0) IVToken(LOCAL_VUSDT_LST).redeem(vBal);

        // 3. Use redeemed USDT to repay remaining debt.
        uint256 stillOwed = IVToken(LOCAL_VUSDT_LST).borrowBalanceCurrent(address(this));
        uint256 cash = IERC20(BSC.USDT).balanceOf(address(this));
        if (stillOwed > 0 && cash > 0) {
            uint256 r2 = stillOwed < cash ? stillOwed : cash;
            IVToken(LOCAL_VUSDT_LST).repayBorrow(r2);
        }

        _endPnL("B06-01: Venus Core->LST isolated pool USDT rate arb");
    }

    // ---- IVenusFlashLoanReceiver -----------------------------------------

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

        // ---- Enter LST pool USDT market ----
        address[] memory mk = new address[](1);
        mk[0] = LOCAL_VUSDT_LST;
        IVenusComptroller(LOCAL_LST_COMPTROLLER).enterMarkets(mk);

        // ---- Supply all flashed USDT to LST pool ----
        IERC20(asset).approve(LOCAL_VUSDT_LST, type(uint256).max);
        require(IVToken(LOCAL_VUSDT_LST).mint(amount) == 0, "lst mint failed");

        // ---- Borrow ~90 % back from the LST pool ----
        uint256 borrowAmt = (amount * BORROW_BPS) / 10_000;
        require(IVToken(LOCAL_VUSDT_LST).borrow(borrowAmt) == 0, "lst borrow failed");

        // ---- Approve Core vUSDT to pull the flash repayment ----
        // We owe `amount + premium` to Core vUSDT. We have:
        //  - `borrowAmt` of fresh USDT from LST borrow
        //  - the BUFFER (already in contract before flash)
        // So premium + (amount - borrowAmt) is drawn from buffer.
        IERC20(asset).approve(msg.sender, amount + premium);

        return true;
    }
}
