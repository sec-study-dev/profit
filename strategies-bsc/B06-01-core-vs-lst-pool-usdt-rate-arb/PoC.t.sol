// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";

/// @notice Comptroller market enumeration.
interface IMarkets {
    function getAllMarkets() external view returns (address[] memory);
}

/// @title B06-01 Venus Core <-> LST isolated pool USDT rate arb
/// @notice Intended atomic carry: flash USDT, supply+borrow it across the two
///         Comptrollers to harvest a USDT borrow/supply rate spread.
///
///         INFEASIBLE AS SPECIFIED (verified on-chain at the pinned block):
///         - The Venus "Liquid Staked BNB" isolated pool
///           (Comptroller 0xd933909A4a2b7A4638903028f44D1d38ce27c352) lists
///           ONLY ankrBNB / BNBx / stkBNB / WBNB / slisBNB vTokens. There is
///           NO vUSDT in that pool, so a USDT supply/borrow leg cannot exist.
///         - Venus Core vUSDT does NOT expose `flashLoan` (the legacy Core
///           vTokens are not the V4 flash-enabled variant) - flashLoanEnabled
///           reverts.
///         With no second USDT venue and no flash source, there is no USDT
///         rate arb to capture. The strategy verifies both facts on-chain and
///         holds (net ~0, PASS) rather than fabricating an edge.
contract B06_01_VenusCoreLSTPoolUSDTArbTest is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 44_000_000;

    /// @notice Verified Venus LST (Liquid Staked BNB) isolated-pool Comptroller.
    address internal constant LOCAL_LST_COMPTROLLER = 0xd933909A4a2b7A4638903028f44D1d38ce27c352;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.USDT);
    }

    function testStrategy_B06_01() public {
        _startPnL();

        // Confirm the LST pool carries no USDT market (so the arb is impossible).
        address[] memory mks = IMarkets(LOCAL_LST_COMPTROLLER).getAllMarkets();
        bool lstHasUsdt = false;
        for (uint256 i = 0; i < mks.length; i++) {
            try IVToken(mks[i]).underlying() returns (address u) {
                if (u == BSC.USDT) lstHasUsdt = true;
            } catch {}
        }
        emit log_named_uint("lst_pool_market_count", mks.length);
        emit log_named_string("lst_pool_has_vusdt", lstHasUsdt ? "yes" : "no");

        // Confirm Core vUSDT has no flash-loan facility.
        bool coreFlash = _hasFlashLoan(BSC.vUSDT);
        emit log_named_string("core_vusdt_flashloan", coreFlash ? "yes" : "no");

        require(!lstHasUsdt, "unexpected: LST pool now lists vUSDT - re-enable arb");
        emit log_string("No USDT rate arb available (no LST vUSDT, no Core flash); holding.");

        _endPnL("B06-01: Core<->LST USDT rate arb (infeasible, hold)");
    }

    function _hasFlashLoan(address vToken) internal view returns (bool) {
        (bool ok,) = vToken.staticcall(abi.encodeWithSignature("flashLoanEnabled()"));
        return ok;
    }
}
