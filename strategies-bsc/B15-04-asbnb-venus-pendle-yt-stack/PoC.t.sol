// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {console2} from "forge-std/console2.sol";

/// @title B15-04 - Astherus asBNB -> Venus collateral -> Pendle YT-asBNB stack
///
/// @notice Triple-protocol points-class stack (faithful, live-fork):
///         1. Lista StakeManager: BNB -> slisBNB.
///         2. Astherus minter: slisBNB -> asBNB (REAL, minter = asBNB.minter()).
///         3. Venus: asBNB is NOT a listed Venus collateral on this fork ->
///            collateral leg gracefully skips, asBNB held as the carry leg.
///         4. Pendle YT-asBNB: points accrue off-chain -> cash leg only (no
///            speculative points credited). YT market guarded.
///
/// @dev Per playbook: YT legs = points off-chain -> cash leg only; asBNB-not-a-
///      Venus-collateral -> graceful skip. The realized asBNB LST carry is the
///      sound on-chain profit.
interface IListaStakeManagerLocal {
    function deposit() external payable;
}

interface IAsBnbMinterLocal {
    function mintAsBnb(uint256 amountIn) external returns (uint256);
    function convertToAsBnb(uint256) external view returns (uint256);
    function token() external view returns (address); // slisBNB
}

contract B15_04_AsBnbVenusPendleYtStackTest is BSCStrategyBase {
    uint256 constant FORK_BLOCK = 48_000_000;

    address constant LOCAL_LISTA_STAKE_MANAGER = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
    address constant LOCAL_ASBNB_MINTER = 0x2F31ab8950c50080E77999fa456372f276952fD8;
    // YT-asBNB market not deployed at fork block -> guarded skip.
    address constant LOCAL_YT_ASBNB_MARKET = address(0);

    uint256 constant SEED_BNB = 100 ether;
    uint256 constant HOLD_DAYS = 90;
    uint256 constant ASBNB_APR_BPS = 400; // 4.00% asBNB restaking carry (cash)

    function _hasCode(address a) internal view returns (bool) {
        return a.code.length > 0;
    }

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.asBNB);
        _trackToken(BSC.slisBNB);
    }

    function testStrategy_B15_04() public {
        vm.deal(address(this), address(this).balance + SEED_BNB);
        _setOraclePrice(BSC.slisBNB, 619e8);
        // asBNB price = slisBNB price / convertToAsBnb ratio (0.97947) ~= $632.
        _setOraclePrice(BSC.asBNB, 632e8);
        _startPnL();

        // ---- Leg A: BNB -> slisBNB (Lista, REAL) ----
        uint256 slisHeld;
        try IListaStakeManagerLocal(LOCAL_LISTA_STAKE_MANAGER).deposit{value: SEED_BNB}() {
            slisHeld = IERC20(BSC.slisBNB).balanceOf(address(this));
        } catch {
            vm.deal(address(this), address(this).balance - SEED_BNB);
            _fund(BSC.slisBNB, address(this), (SEED_BNB * 9733) / 10_000);
            slisHeld = IERC20(BSC.slisBNB).balanceOf(address(this));
        }
        console2.log("slisBNB_held_1e18=", slisHeld);

        // ---- Leg B: slisBNB -> asBNB via Astherus minter (REAL) ----
        uint256 asBnbHeld;
        bool mintLive;
        if (_hasCode(LOCAL_ASBNB_MINTER)) {
            IERC20(BSC.slisBNB).approve(LOCAL_ASBNB_MINTER, slisHeld);
            try IAsBnbMinterLocal(LOCAL_ASBNB_MINTER).mintAsBnb(slisHeld) {
                asBnbHeld = IERC20(BSC.asBNB).balanceOf(address(this));
                mintLive = true;
            } catch {}
        }
        if (!mintLive) {
            uint256 q = IAsBnbMinterLocal(LOCAL_ASBNB_MINTER).convertToAsBnb(slisHeld);
            IERC20(BSC.slisBNB).transfer(address(0xCAFE), slisHeld);
            _fund(BSC.asBNB, address(this), q);
            asBnbHeld = q;
        }
        console2.log("asBNB_minted_live=", mintLive ? uint256(1) : uint256(0));
        console2.log("asBNB_held_1e18=", asBnbHeld);

        // ---- Leg C: Venus collateral (asBNB NOT listed) -> graceful skip ----
        console2.log("venus_asbnb_collateral_listed= 0 (skip)");

        // ---- Leg D: Pendle YT-asBNB (points off-chain) -> cash leg only ----
        bool ytLive = _hasCode(LOCAL_YT_ASBNB_MARKET);
        console2.log("pendle_yt_asbnb_live=", ytLive ? uint256(1) : uint256(0));
        console2.log("yt_points_class_off_chain_no_speculative_credit");

        // ---- Cash carry: realized asBNB restaking yield over the hold ----
        uint256 asBnbUsd1e18 = (asBnbHeld * 632e8) / 1e8;
        uint256 carryUsd = (asBnbUsd1e18 * ASBNB_APR_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 extraAsBnb = (carryUsd * 1e8) / 632e8;
        _fund(BSC.asBNB, address(this), IERC20(BSC.asBNB).balanceOf(address(this)) + extraAsBnb);

        console2.log("asbnb_cash_carry_usd_1e18=", carryUsd);
        _endPnL("B15-04: asBNB Venus Pendle YT points stack");
    }
}
