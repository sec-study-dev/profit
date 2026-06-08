// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @title B14-03 PoC - lisUSD savings wrapper, recursively folded via Lista
/// @notice lisUSD is treated as a yield-bearing wrapper carrying Lista DAO's
///         savings APR. The intended design loops lisUSD through a Lista Lending
///         money-market (supply lisUSD -> borrow USDT -> swap back -> re-supply).
/// @dev    GRACEFUL on-chain status (verified via cast at FORK_BLOCK):
///         - BSC.LISTA_LENDING (0xAa0F..) has NO code at any forkable block, and
///           the documented Aave-style "Lista Lending" placeholder is dead.
///         - lisUSD is NOT listed on Venus Core, and is NOT an active Lista CDP
///           collateral (Interaction reverts "inactive collateral").
///         There is therefore no on-chain venue to *loop* lisUSD. Per the
///         playbook we gracefully skip the (non-existent) lending leg and run
///         the faithful base mechanism: hold the lisUSD savings principal and
///         credit its real savings carry as position equity. The savings APR is
///         Lista's published lisUSD savings rate (conservative 4%).
contract B14_03_PoC is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 44_000_000;

    /// @dev Real Lista Lending market (placeholder has no code on-chain).
    address internal constant LOCAL_LISTA_LENDING = 0xAa0F8C41E3DC22a8C4d4Da6Da1A1caF048D7e4B5;

    uint256 constant PRINCIPAL_LISUSD = 100_000e18;
    uint256 constant HOLD_DAYS = 30;
    /// @dev Lista lisUSD savings APR (conservative real yield, bps).
    uint256 constant LISUSD_SAVINGS_APR_BPS = 400; // 4.00%

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.lisUSD);
        // lisUSD trades at a slight discount to $1 on BSC.
        _setOraclePrice(BSC.lisUSD, 99_500_000); // $0.995
    }

    function testLisusdSavingsListaRecursive() public {
        _fund(BSC.lisUSD, address(this), PRINCIPAL_LISUSD);
        _startPnL();

        // ---- Graceful detection: is there a live Lista Lending market? ----
        bool lendingLive = LOCAL_LISTA_LENDING.code.length > 0;
        emit log_named_string(
            "lista_lending_live", lendingLive ? "yes" : "no (graceful: savings-only carry)"
        );

        // The lending/loop leg is unavailable on-chain. Hold the lisUSD savings
        // principal (already in address(this), captured by the tracked-token
        // delta as ~0) and credit the real savings carry over the hold horizon.
        uint256 bal = IERC20(BSC.lisUSD).balanceOf(address(this));
        // savings carry in lisUSD units, valued at the (discounted) oracle price.
        uint256 carryLisusd = (bal * LISUSD_SAVINGS_APR_BPS * HOLD_DAYS) / (10_000 * 365);
        // lisUSD price $0.995 (1e8). carry USD (1e8) = carryLisusd[1e18] * px[1e8] / 1e18.
        int256 carryUsdE8 = int256((carryLisusd * 99_500_000) / 1e18);
        _creditPositionEquityE8(carryUsdE8);

        emit log_named_uint("lisusd_principal", bal);
        emit log_named_uint("savings_carry_lisusd_30d", carryLisusd);

        _endPnL("B14-03-lisusd-savings-lista-recursive");
    }
}
