// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";

/// @notice Comptroller market enumeration.
interface IMarkets {
    function getAllMarkets() external view returns (address[] memory);
}

/// @title B06-06 Cross isolated-pool collateral migration (Core -> LST pool)
/// @notice Intended: atomically migrate a Core-pool slisBNB-collateralised USDT
///         loan into the Venus "Liquid Staked BNB" isolated pool (higher
///         slisBNB CF, lower USDT borrow APR) using a Venus flash loan.
///
///         INFEASIBLE AS SPECIFIED (verified on-chain at the pinned block):
///         - Venus **Core** does NOT list a slisBNB market, so there is no
///           Core slisBNB collateral position to migrate FROM.
///         - The LST isolated pool lists NO vUSDT, so the USDT debt leg cannot
///           be re-opened there (it only has ankrBNB/BNBx/stkBNB/WBNB/slisBNB).
///         - Venus Core vUSDT exposes no `flashLoan`.
///         Each of the three legs the migration needs is absent on BSC, so the
///         strategy verifies this on-chain and holds (net ~0, PASS) instead of
///         fabricating a cross-pool route that does not exist. (A native
///         slisBNB/WBNB position INSIDE the LST pool is the feasible variant -
///         see B06-03.)
contract B06_06_CrossPoolCollateralMigrationTest is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 44_000_000;

    address internal constant LOCAL_LST_COMPTROLLER = 0xd933909A4a2b7A4638903028f44D1d38ce27c352;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.USDT);
    }

    function testStrategy_B06_06() public {
        _startPnL();

        // Core has no slisBNB market (no migration source).
        bool coreHasSlis = _marketHasUnderlying(BSC.VENUS_COMPTROLLER, BSC.slisBNB);
        // LST pool has no USDT market (no destination debt leg).
        bool lstHasUsdt = _marketHasUnderlying(LOCAL_LST_COMPTROLLER, BSC.USDT);
        // Core vUSDT has no flash facility.
        (bool flashOk,) = BSC.vUSDT.staticcall(abi.encodeWithSignature("flashLoanEnabled()"));

        emit log_named_string("core_has_vslisbnb", coreHasSlis ? "yes" : "no");
        emit log_named_string("lst_has_vusdt", lstHasUsdt ? "yes" : "no");
        emit log_named_string("core_vusdt_flashloan", flashOk ? "yes" : "no");

        require(!coreHasSlis && !lstHasUsdt, "unexpected: migration legs now exist - re-enable");
        emit log_string("Cross-pool migration legs absent on BSC; holding.");

        _endPnL("B06-06: cross-pool collateral migration (infeasible, hold)");
    }

    function _marketHasUnderlying(address comptroller, address underlying) internal view returns (bool) {
        address[] memory mks = IMarkets(comptroller).getAllMarkets();
        for (uint256 i = 0; i < mks.length; i++) {
            try IVToken(mks[i]).underlying() returns (address u) {
                if (u == underlying) return true;
            } catch {}
        }
        return false;
    }
}
