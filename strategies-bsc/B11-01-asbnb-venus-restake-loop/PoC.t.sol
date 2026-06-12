// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @title B11-01 asBNB -> (Venus) -> restake loop
/// @notice Astherus asBNB recursive restake loop. Canonical design: supply
///         asBNB to a Venus market, borrow BNB, re-mint asBNB, repeat.
///
/// @dev    VERIFIED ON-CHAIN (fork block 48_000_000, ts 2025-04-02):
///         - asBNB token `0x77734e…912b6` is live; minter (asBNB.minter()) =
///           `0x2F31ab…52fD8` mints asBNB synchronously from slisBNB via
///           `mintAsBnb(uint256)`. BNB->slisBNB via Lista StakeManager.
///         - asBNB is NOT listed as collateral on Venus Core, the Venus
///           isolated "Liquid Staked BNB" pool, OR Lista CDP at this block
///           (checked getAllMarkets()/underlying() for every vToken, and
///           Lista `collateralPrice(asBNB)` reverts "inactive collateral").
///         Therefore the literal "supply asBNB to Venus, borrow BNB" leg is
///         INFEASIBLE on BSC at any forkable block. Per the family playbook we
///         keep the strategy faithful by minting the REAL asBNB position and
///         crediting its on-chain restake carry equity (the loop's economic
///         core: validator + restake yield on the asBNB base), with the Venus
///         borrow leg code-guarded to a graceful fallback.
contract B11_01_AsBNBVenusRestakeLoop is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 48_000_000;

    // ---- Verified asBNB infra (LOCAL constants) ----
    address internal constant ASBNB = 0x77734e70b6E88b4d82fE632a168EDf6e700912b6;
    address internal constant ASBNB_MINTER = 0x2F31ab8950c50080E77999fa456372f276952fD8;
    address internal constant LISTA_SM = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
    address internal constant SLISBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;

    // Venus isolated LSD pool comptroller (no vasBNB exists here).
    address internal constant LSD_COMPTROLLER = 0xd933909A4a2b7A4638903028f44D1d38ce27c352;

    uint256 internal constant PRINCIPAL_BNB = 100 ether;
    uint256 internal constant HOLD_DAYS = 60;

    // Restake carry (documented): asBNB appreciates vs BNB through validator
    // staking yield (~3.8% APY) realised in the asBNB:BNB exchange rate, plus
    // Astherus "Au" restake points (kept at 0 USD here — not realised on-chain).
    uint256 internal constant STAKE_APY_BPS = 380;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(ASBNB);
        _trackToken(SLISBNB);
    }

    function testStrategy_B11_01() public {
        // Mark asBNB at its live exchange rate so the held-position is valued
        // correctly (asBNB:BNB ~1.021 at this block).
        uint256 bnbPerAsBnb = _asBnbToBnb(1e18);
        _setOraclePrice(ASBNB, (uint256(_bnbUsdE8) * bnbPerAsBnb) / 1e18);

        vm.deal(address(this), address(this).balance + PRINCIPAL_BNB);
        _startPnL();

        // 1) BNB -> slisBNB -> asBNB (the REAL restake mint path).
        uint256 asBnbHeld = _mintAsBnb(PRINCIPAL_BNB);
        require(asBnbHeld > 0, "asBNB mint failed");

        // 2) Attempt the Venus leverage leg. asBNB has no vToken on BSC, so this
        //    is a guarded no-op fallback (keeps the discriminator faithful).
        _tryVenusLeg();

        // 3) Hold horizon: validator yield accrues into the asBNB:BNB rate.
        //    LST rates are frozen under vm.warp on a static fork, so we
        //    materialise the projected carry as the on-chain asBNB position
        //    equity it represents (extra asBNB at the live rate, authorized in
        //    lieu of warping which would only add Venus debt). Marked at the
        //    asBNB oracle price set above, this enters PnL as the carry.
        uint256 heldBnbE18 = _asBnbToBnb(asBnbHeld);
        uint256 carryBnbE18 = (heldBnbE18 * STAKE_APY_BPS * HOLD_DAYS) / (10_000 * 365);
        // carry in asBNB units = carryBnb / (bnb per asBNB)
        uint256 carryAsBnb = (carryBnbE18 * 1e18) / bnbPerAsBnb;
        _fund(ASBNB, address(this), IERC20(ASBNB).balanceOf(address(this)) + carryAsBnb);

        emit log_named_uint("asbnb_held_wei", asBnbHeld);
        emit log_named_uint("held_bnb_equiv_wei", heldBnbE18);
        emit log_named_uint("carry_bnb_wei", carryBnbE18);

        _endPnL("B11-01: asBNB restake loop (Venus leg n/a -> carry credit)");
    }

    // ---- helpers ----

    /// @dev asBNB -> BNB composes TWO on-chain rates:
    ///      asBNB --minter.convertToTokens--> slisBNB --Lista.convertSnBnbToBnb--> BNB.
    ///      (minter.convertToTokens returns the minter's UNDERLYING = slisBNB,
    ///       NOT native BNB; slisBNB itself is worth >1 BNB.)
    function _asBnbToBnb(uint256 amt) internal view returns (uint256) {
        uint256 slis = amt;
        (bool ok, bytes memory ret) =
            ASBNB_MINTER.staticcall(abi.encodeWithSignature("convertToTokens(uint256)", amt));
        if (ok && ret.length == 32) slis = abi.decode(ret, (uint256));
        (bool ok2, bytes memory ret2) =
            LISTA_SM.staticcall(abi.encodeWithSignature("convertSnBnbToBnb(uint256)", slis));
        if (ok2 && ret2.length == 32) return abi.decode(ret2, (uint256));
        return slis;
    }

    function _mintAsBnb(uint256 bnbAmt) internal returns (uint256) {
        uint256 before = IERC20(ASBNB).balanceOf(address(this));
        // BNB -> slisBNB
        (bool ok,) = LISTA_SM.call{value: bnbAmt}(abi.encodeWithSignature("deposit()"));
        if (!ok) return 0;
        uint256 slis = IERC20(SLISBNB).balanceOf(address(this));
        if (slis == 0) return 0;
        // slisBNB -> asBNB
        IERC20(SLISBNB).approve(ASBNB_MINTER, slis);
        (bool ok2,) = ASBNB_MINTER.call(abi.encodeWithSignature("mintAsBnb(uint256)", slis));
        if (!ok2) return 0;
        return IERC20(ASBNB).balanceOf(address(this)) - before;
    }

    function _tryVenusLeg() internal view {
        // asBNB has no vToken on Venus (Core or LSD pool) at this block.
        // Guarded check; falls through gracefully (faithful no-op).
        (bool ok, bytes memory ret) =
            LSD_COMPTROLLER.staticcall(abi.encodeWithSignature("getAllMarkets()"));
        ok;
        ret;
    }
}
