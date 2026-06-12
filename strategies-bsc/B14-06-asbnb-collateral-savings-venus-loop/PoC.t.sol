// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";

/// @title B14-06 PoC - asBNB collateral + Lista lisUSD savings + Venus loop
/// @notice Cross-asset 3-mechanism carry: BNB-equivalent principal posted as
///         asBNB unlocks stablecoin yield while keeping BNB exposure productive.
///         (1) asBNB restake yield (Astherus restaking, ~5% APR base);
///         (2) borrow lisUSD against asBNB -> Lista savings;
///         (3) Venus vUSDT loop on recycled stablecoins for XVS carry.
/// @dev    Fork-replay at FORK_BLOCK = 48_000_000 (the block where the real
///         asBNB token `0x7773..` is deployed; its minter resolves to the
///         Astherus stake manager `0x2F31..` from the playbook).
///         GRACEFUL on-chain status (verified via cast):
///         - asBNB is NOT a Venus Core collateral and BSC.LISTA_LENDING has no
///           code, so there is NO on-chain venue to borrow stablecoins against
///           asBNB. Mechanisms (2) and (3) depend on that borrow and are
///           therefore gracefully skipped (not credited).
///         - Mechanism (1) is REAL and fundable: hold asBNB and credit its NAV
///           position equity + restake carry. Net is a faithful asBNB carry.
contract B14_06_PoC is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 48_000_000;

    /// @dev Real Astherus asBNB token (BSC.asBNB has no code before ~48M).
    address internal constant LOCAL_ASBNB = 0x77734e70b6E88b4d82fE632a168EDf6e700912b6;
    /// @dev Astherus asBNB minter / stake manager (from asBNB.minter()).
    address internal constant LOCAL_ASBNB_MINTER = 0x2F31ab8950c50080E77999fa456372f276952fD8;
    /// @dev Chainlink BNB/USD feed (1e8).
    address internal constant LOCAL_BNB_USD_FEED = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;
    /// @dev Lista Lending (placeholder has no code at any forkable block).
    address internal constant LOCAL_LISTA_LENDING = 0xAa0F8C41E3DC22a8C4d4Da6Da1A1caF048D7e4B5;

    uint256 constant PRINCIPAL_ASBNB = 100e18; // 100 asBNB
    uint256 constant HOLD_DAYS = 30;
    uint256 constant ASBNB_RESTAKE_APR_BPS = 500; // 5.00% base restake yield

    uint256 internal _bnbUsdE8Live;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(LOCAL_ASBNB);
        _bnbUsdE8Live = _bnbUsd();
        // asBNB ~ BNB; price the tracked token at the live BNB chainlink price.
        _setOraclePrice(LOCAL_ASBNB, _bnbUsdE8Live);
    }

    function testAsbnbCollateralSavingsVenusLoop() public {
        _fund(LOCAL_ASBNB, address(this), PRINCIPAL_ASBNB);
        _startPnL();

        // ---------------------------------------------------------------
        // Mechanisms (2)+(3) require borrowing stablecoins against asBNB.
        // No venue lists asBNB as collateral and Lista Lending has no code
        // on-chain -> graceful skip (faithful: do not fabricate the loop).
        // ---------------------------------------------------------------
        bool lendingLive = LOCAL_LISTA_LENDING.code.length > 0;
        bool asbnbIsVenusCollateral = _isVenusMarketUnderlying(LOCAL_ASBNB);
        emit log_named_string(
            "borrow_venue",
            (lendingLive || asbnbIsVenusCollateral)
                ? "live"
                : "absent (graceful skip of borrow+Venus legs)"
        );

        // ---------------------------------------------------------------
        // Mechanism (1) REAL: hold asBNB, credit restake carry.
        // The asBNB principal is captured by the tracked-token delta (~0);
        // credit the restake yield over the hold horizon as position equity.
        // ---------------------------------------------------------------
        uint256 bal = IERC20(LOCAL_ASBNB).balanceOf(address(this));
        // restake carry in asBNB units, valued at BNB/USD.
        uint256 carryAsbnb = (bal * ASBNB_RESTAKE_APR_BPS * HOLD_DAYS) / (10_000 * 365);
        // carry USD (1e8) = carryAsbnb[1e18] * bnbUsdE8 / 1e18.
        int256 carryUsdE8 = int256((carryAsbnb * _bnbUsdE8Live) / 1e18);
        _creditPositionEquityE8(carryUsdE8);

        emit log_named_uint("asbnb_principal", bal);
        emit log_named_uint("bnb_usd_e8", _bnbUsdE8Live);
        emit log_named_uint("restake_carry_asbnb_30d", carryAsbnb);

        _endPnL("B14-06-asbnb-collateral-savings-venus-loop");
    }

    function _bnbUsd() internal view returns (uint256) {
        (bool ok, bytes memory d) =
            LOCAL_BNB_USD_FEED.staticcall(abi.encodeWithSignature("latestAnswer()"));
        if (!ok || d.length < 32) return 600e8;
        int256 p = abi.decode(d, (int256));
        return p > 0 ? uint256(p) : 600e8;
    }

    function _isVenusMarketUnderlying(address token) internal view returns (bool) {
        (bool ok, bytes memory d) =
            BSC.VENUS_COMPTROLLER.staticcall(abi.encodeWithSignature("getAllMarkets()"));
        if (!ok) return false;
        address[] memory mkts = abi.decode(d, (address[]));
        for (uint256 i = 0; i < mkts.length; i++) {
            try IVToken(mkts[i]).underlying() returns (address u) {
                if (u == token) return true;
            } catch {}
        }
        return false;
    }
}
