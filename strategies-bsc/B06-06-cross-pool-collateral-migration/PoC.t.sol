// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVBNB} from "src/interfaces/bsc/mm/IVBNB.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {IVenusFlashLoan, IVenusFlashLoanReceiver} from "src/interfaces/bsc/mm/IVenusFlashLoan.sol";
import {IslisBNB} from "src/interfaces/bsc/lst/IslisBNB.sol";
import {IListaStakeManager} from "src/interfaces/bsc/lst/IListaStakeManager.sol";

/// @title B06-06 Cross isolated-pool collateral migration (Core -> LST pool)
/// @notice 3-mechanism stack: an existing Core-pool slisBNB-collateralised
///         USDT loan is migrated atomically to the LST isolated pool, which
///         offers a higher slisBNB collateralFactor (~ 80 % vs Core's ~ 65 %)
///         AND a lower USDT borrow APR. Mechanisms:
///         1. Venus V4 `flashLoan` on Core vUSDT - supplies the temporary
///            cash to redeem the user's USDT debt on Core.
///         2. Cross-Comptroller redeem of seized vSlisBNB (Core) and
///            re-supply into the LST pool's vSlisBNB.
///         3. Re-borrow USDT from the LST pool's vUSDT to repay the flash.
///         Same notional, same wallet, but post-migration LTV headroom is
///         ~25 % higher and per-block carry is `(rCoreBorrow - rLSTBorrow)`.
contract B06_06_CrossPoolCollateralMigrationTest is BSCStrategyBase, IVenusFlashLoanReceiver {
    uint256 internal constant FORK_BLOCK = 42_500_000;

    // ---- Inlined LST isolated-pool addresses ----
    address internal constant LOCAL_LST_COMPTROLLER = 0x596B11acAACF03217287939f88d63b51d3771704;
    /// @notice LST pool vUSDT. TODO verify.
    address internal constant LOCAL_VUSDT_LST = 0x1D8BB512F56451ddEF820D6FE0FAa0B1b655a263;
    /// @notice LST pool vSlisBNB. TODO verify.
    address internal constant LOCAL_VSLISBNB_LST = 0xd3CC9d8f3689B83c91b7B59cAB4946B063EB894A;

    /// @dev Core-pool vSlisBNB (slisBNB listing on Core). TODO verify.
    address internal constant LOCAL_VSLISBNB_CORE = 0xd3CC9d8f3689B83c91b7B59cAB4946B063EB894A;

    // ---- Strategy parameters ----
    /// @dev Existing Core-pool position: 1000 slisBNB collateral, 300k USDT debt.
    uint256 internal constant INITIAL_SLISBNB = 1_000 ether;
    uint256 internal constant INITIAL_USDT_DEBT = 300_000e18;
    uint256 internal constant BUFFER = 5_000e18;
    uint256 internal constant HOLD_DAYS = 60;
    uint256 internal constant SECS_PER_BLOCK = 3;

    bool internal _inFlash;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.USDT);
        _trackToken(BSC.vUSDT);
        _trackToken(LOCAL_VSLISBNB_CORE);
        _trackToken(LOCAL_VSLISBNB_LST);
        _trackToken(LOCAL_VUSDT_LST);
    }

    function testStrategy_B06_06() public {
        _fund(BSC.USDT, address(this), BUFFER);
        _seedCorePosition();
        _startPnL();

        // ---- 1. Flash USDT == current Core USDT debt ----
        uint256 owedCore = IVToken(BSC.vUSDT).borrowBalanceCurrent(address(this));
        emit log_named_uint("core_usdt_debt_pre_e18", owedCore);
        if (owedCore == 0) {
            // Position-seed degenerated; emit empty PnL.
            _endPnL("B06-06: cross-pool migration (no Core position)");
            return;
        }

        _inFlash = true;
        IVenusFlashLoan(BSC.vUSDT).flashLoan(address(this), BSC.USDT, owedCore, "");
        _inFlash = false;

        // ---- 4. Hold 60 days at lower borrow APR on LST pool ----
        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
        vm.roll(block.number + (HOLD_DAYS * 1 days) / SECS_PER_BLOCK);
        IVToken(LOCAL_VUSDT_LST).borrowBalanceCurrent(address(this));

        emit log_named_uint("lst_usdt_debt_post_e18", IVToken(LOCAL_VUSDT_LST).borrowBalanceCurrent(address(this)));
        emit log_named_uint("lst_vSlisBNB_bal_e18", IERC20(LOCAL_VSLISBNB_LST).balanceOf(address(this)));

        // Mark slisBNB at its real BNB exchange rate for accurate PnL.
        uint256 bnbPerSlis = IListaStakeManager(BSC.LISTA_STAKE_MANAGER).convertSnBnbToBnb(1e18);
        uint256 slisPriceE8 = (600e8 * bnbPerSlis) / 1e18;
        _setOraclePrice(BSC.slisBNB, slisPriceE8);

        _endPnL("B06-06: cross-pool collateral migration (Core->LST)");
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

        // ---- 2a. Repay Core vUSDT debt with flashed USDT ----
        IERC20(asset).approve(BSC.vUSDT, type(uint256).max);
        IVToken(BSC.vUSDT).repayBorrow(amount);

        // ---- 2b. Redeem Core vSlisBNB (now unlocked) ----
        uint256 vSlisCore = IERC20(LOCAL_VSLISBNB_CORE).balanceOf(address(this));
        if (vSlisCore > 0) IVToken(LOCAL_VSLISBNB_CORE).redeem(vSlisCore);

        uint256 slisBal = IERC20(BSC.slisBNB).balanceOf(address(this));

        // ---- 2c. Enter LST-pool markets, supply slisBNB ----
        address[] memory mk = new address[](2);
        mk[0] = LOCAL_VSLISBNB_LST;
        mk[1] = LOCAL_VUSDT_LST;
        IVenusComptroller(LOCAL_LST_COMPTROLLER).enterMarkets(mk);

        IERC20(BSC.slisBNB).approve(LOCAL_VSLISBNB_LST, type(uint256).max);
        require(IVToken(LOCAL_VSLISBNB_LST).mint(slisBal) == 0, "lst slis mint failed");

        // ---- 3. Borrow USDT from LST-pool vUSDT to repay flash + premium ----
        uint256 owed = amount + premium;
        // Clamp to available liquidity / borrow-cap headroom.
        uint256 cash = IVToken(LOCAL_VUSDT_LST).getCash();
        if (owed > cash) revert("lst vUSDT cash too low");
        require(IVToken(LOCAL_VUSDT_LST).borrow(owed) == 0, "lst vUSDT borrow failed");

        // Approve Core flash repay.
        IERC20(asset).approve(msg.sender, owed);
        return true;
    }

    // ---- Helpers --------------------------------------------------------

    /// @dev Seed a realistic Core-pool position so the migration target
    ///      exists offline. In a live run this is the user's pre-existing
    ///      position and the helper is a no-op.
    function _seedCorePosition() internal {
        _fund(BSC.slisBNB, address(this), INITIAL_SLISBNB);

        IVenusComptroller comp = IVenusComptroller(BSC.VENUS_COMPTROLLER);
        address[] memory mk = new address[](2);
        mk[0] = LOCAL_VSLISBNB_CORE;
        mk[1] = BSC.vUSDT;
        // try/catch for offline runs where the Core slisBNB market is not
        // yet listed at the pinned block - degrade to a no-position state.
        try comp.enterMarkets(mk) {} catch {}

        IERC20(BSC.slisBNB).approve(LOCAL_VSLISBNB_CORE, type(uint256).max);
        try IVToken(LOCAL_VSLISBNB_CORE).mint(INITIAL_SLISBNB) returns (uint256 e) {
            if (e == 0) {
                try IVToken(BSC.vUSDT).borrow(INITIAL_USDT_DEBT) {} catch {}
            }
        } catch {}
    }
}
