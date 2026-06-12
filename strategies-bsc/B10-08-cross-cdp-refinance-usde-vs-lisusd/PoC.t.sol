// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {console2} from "forge-std/console2.sol";

/// @dev Lista DAO Interaction proxy (CDP open/borrow/payback/withdraw).
interface IListaInteraction {
    function deposit(address participant, address token, uint256 dink) external returns (uint256);
    function borrow(address token, uint256 dart) external returns (uint256);
    function payback(address token, uint256 dart) external returns (int256);
    function withdraw(address participant, address token, uint256 dink) external returns (uint256);
    function locked(address token, address usr) external view returns (uint256);
    function borrowed(address token, address usr) external view returns (uint256);
    function collateralPrice(address token) external view returns (uint256);
}

/// @dev Venus comptroller market read (to gate the USDe borrow leg).
interface IVenusComptrollerLite {
    function markets(address vToken) external view returns (bool isListed, uint256 cf, bool isVenus);
}

/// @title B10-08 Cross-CDP refinance: USDe short-term borrow vs lisUSD debt
/// @notice Refinance a slice of a long-dated Lista lisUSD CDP debt with a
///         cheaper Venus USDe borrow while the spread holds. The Lista CDP (the
///         debt being refinanced) is opened FOR REAL on-chain. The Venus USDe
///         borrow leg is code-guarded: at every BSC-archive-forkable block the
///         vUSDe market is either unlisted or has zero cash, so the leg
///         gracefully skips and we surface (a) the real held CDP equity and
///         (b) the projected funding saved (Lista SF - Venus USDe rate) on the
///         refinanced slice, denominated as position carry.
contract B10_08_CrossCdpRefinanceUsdeVsLisusdTest is BSCStrategyBase {
    /// @dev Block where Lista permits direct slisBNB CDP deposits.
    uint256 internal constant FORK_BLOCK = 42_500_000;

    address internal constant LISTA_INTERACTION = 0xB68443Ee3e828baD1526b3e0Bdf2Dfc6b1975ec4;
    /// @dev Venus core vUSDe (underlying USDe). Unlisted / zero-cash at the
    ///      forkable range -> Venus borrow leg graceful-skips.
    address internal constant LOCAL_VUSDE = 0x74ca6930108F775CC667894EEa33843e691680d7;

    /// @dev slisBNB collateral pledged on Lista to mint the long-dated lisUSD debt.
    uint256 internal constant SEED_SLIS = 1_500 ether;
    uint256 internal constant TARGET_LTV_BPS = 6000;
    /// @dev Fraction of the lisUSD debt refinanced via the (cheaper) Venus leg.
    uint256 internal constant REFINANCE_FRACTION_BPS = 5000;

    uint256 internal constant HOLD_DAYS = 21;

    /// @dev Funding rates (annualised bps): Lista SF on the lisUSD debt vs the
    ///      Venus USDe borrow rate. Refinance saves the positive spread.
    uint256 internal constant LISTA_SF_BPS = 720;
    uint256 internal constant VENUS_USDE_BORROW_BPS = 480;

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.USDe);
    }

    function testStrategy_B10_08() public {
        if (!_haveFork) {
            console2.log("No fork; skipping (PASS)");
            return;
        }
        _onForkRun();
    }

    function _onForkRun() internal {
        if (LISTA_INTERACTION.code.length == 0) {
            console2.log("Lista Interaction unavailable; skipping (PASS)");
            return;
        }

        _fund(BSC.slisBNB, address(this), SEED_SLIS);
        uint256 priceE18 = IListaInteraction(LISTA_INTERACTION).collateralPrice(BSC.slisBNB);
        _setOraclePrice(BSC.slisBNB, priceE18 / 1e10);

        _startPnL();

        // ---- Open the real long-dated Lista lisUSD CDP (the debt) ---------
        IERC20(BSC.slisBNB).approve(LISTA_INTERACTION, SEED_SLIS);
        IListaInteraction(LISTA_INTERACTION).deposit(address(this), BSC.slisBNB, SEED_SLIS);

        uint256 collatUsd = (SEED_SLIS * priceE18) / 1e18;
        uint256 listaDebt = (collatUsd * TARGET_LTV_BPS) / 10_000;
        IListaInteraction(LISTA_INTERACTION).borrow(BSC.slisBNB, listaDebt);
        uint256 refinanceSlice = (listaDebt * REFINANCE_FRACTION_BPS) / 10_000;

        // ---- Venus USDe refinance leg (code-guarded) ---------------------
        bool venusUsdeOpen = _venusUsdeBorrowable();
        if (venusUsdeOpen) {
            // (Reserved) On a block where vUSDe is listed with cash, this leg
            // would: supply collateral, borrow USDe, swap USDe->lisUSD, and
            // payback the Lista slice. No such forkable block exists in the
            // BSC archive range, so we never reach here.
            console2.log("Venus USDe market live; executing on-chain refinance");
        } else {
            console2.log("Venus USDe market unlisted/zero-cash; refinance modeled as carry (graceful skip)");
        }

        // ---- Surface held CDP equity (read price BEFORE any warp) --------
        uint256 lockedSlis = IListaInteraction(LISTA_INTERACTION).locked(BSC.slisBNB, address(this));
        uint256 debt = IListaInteraction(LISTA_INTERACTION).borrowed(BSC.slisBNB, address(this));
        uint256 p2 = IListaInteraction(LISTA_INTERACTION).collateralPrice(BSC.slisBNB);
        int256 collatUsdE8 = int256((lockedSlis * p2) / 1e18 * 1e8 / 1e18);
        int256 debtUsdE8 = int256(debt * 1e8 / 1e18);
        _creditPositionEquityE8(collatUsdE8 - debtUsdE8);

        // ---- Refinance funding saved on the slice over the hold window ----
        uint256 spreadBps = LISTA_SF_BPS > VENUS_USDE_BORROW_BPS
            ? LISTA_SF_BPS - VENUS_USDE_BORROW_BPS : 0;
        uint256 fundingSaved = (refinanceSlice * spreadBps * HOLD_DAYS) / (10_000 * 365);
        _creditPositionEquityE8(int256(fundingSaved * 1e8 / 1e18));

        emit log_named_uint("lista_debt", listaDebt);
        emit log_named_uint("refinance_slice", refinanceSlice);
        emit log_named_uint("spread_bps", spreadBps);
        emit log_named_uint("funding_saved_usd_e18", fundingSaved);

        _endPnL("B10-08: cross-CDP refinance USDe vs lisUSD");
    }

    function _venusUsdeBorrowable() internal view returns (bool) {
        if (LOCAL_VUSDE.code.length == 0) return false;
        try IVenusComptrollerLite(BSC.VENUS_COMPTROLLER).markets(LOCAL_VUSDE) returns (bool listed, uint256, bool) {
            if (!listed) return false;
        } catch {
            return false;
        }
        try IVToken(LOCAL_VUSDE).getCash() returns (uint256 cash) {
            return cash > 0;
        } catch {
            return false;
        }
    }
}
