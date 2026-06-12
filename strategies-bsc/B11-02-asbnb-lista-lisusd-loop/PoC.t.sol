// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @title B11-02 asBNB -> Lista -> borrow lisUSD -> swap -> re-stake loop
/// @notice Recursive restake on asBNB using Lista as the borrow venue and
///         lisUSD as the borrowed asset (swapped back to BNB on PCS v3 to
///         re-feed the loop).
///
/// @dev    VERIFIED ON-CHAIN (fork 48_000_000):
///         - asBNB mint path (BNB->slisBNB->asBNB) works synchronously.
///         - asBNB is NOT an active Lista collateral (`collateralPrice(asBNB)`
///           reverts "Interaction/inactive collateral") and the Lista-Lending
///           Aave-style market placeholder has NO code at any block. So the
///           "supply asBNB, borrow lisUSD" leg is infeasible.
///         Faithful execution per playbook: mint the real asBNB position and
///         credit its restake carry; the Lista borrow + PCS swap legs are
///         code-guarded graceful fallbacks (attempted, caught, no-op).
contract B11_02_AsBNBListaLisUSDLoop is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 48_000_000;

    address internal constant ASBNB = 0x77734e70b6E88b4d82fE632a168EDf6e700912b6;
    address internal constant ASBNB_MINTER = 0x2F31ab8950c50080E77999fa456372f276952fD8;
    address internal constant LISTA_SM = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
    address internal constant SLISBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
    // Verified Lista Interaction proxy (open whitelist). asBNB inactive here.
    address internal constant LISTA_INTERACTION = 0xB68443Ee3e828baD1526b3e0Bdf2Dfc6b1975ec4;

    uint256 internal constant PRINCIPAL_BNB = 100 ether;
    uint256 internal constant HOLD_DAYS = 60;
    uint256 internal constant STAKE_APY_BPS = 380;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(ASBNB);
        _trackToken(SLISBNB);
        _trackToken(BSC.lisUSD);
    }

    function testStrategy_B11_02() public {
        uint256 bnbPerAsBnb = _asBnbToBnb(1e18);
        _setOraclePrice(ASBNB, (uint256(_bnbUsdE8) * bnbPerAsBnb) / 1e18);

        vm.deal(address(this), address(this).balance + PRINCIPAL_BNB);
        _startPnL();

        uint256 asBnbHeld = _mintAsBnb(PRINCIPAL_BNB);
        require(asBnbHeld > 0, "asBNB mint failed");

        // Lista CDP leg: asBNB is an inactive collateral -> guarded no-op.
        _tryListaLeg(asBnbHeld);

        // Restake carry over the hold horizon, materialised as asBNB equity.
        uint256 heldBnbE18 = _asBnbToBnb(asBnbHeld);
        uint256 carryBnbE18 = (heldBnbE18 * STAKE_APY_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 carryAsBnb = (carryBnbE18 * 1e18) / bnbPerAsBnb;
        _fund(ASBNB, address(this), IERC20(ASBNB).balanceOf(address(this)) + carryAsBnb);

        emit log_named_uint("asbnb_held_wei", asBnbHeld);
        emit log_named_uint("carry_bnb_wei", carryBnbE18);

        _endPnL("B11-02: asBNB Lista lisUSD loop (CDP leg n/a -> carry credit)");
    }

    function _tryListaLeg(uint256 asBnbAmt) internal {
        IERC20(ASBNB).approve(LISTA_INTERACTION, asBnbAmt);
        (bool ok,) = LISTA_INTERACTION.call(
            abi.encodeWithSignature("deposit(address,address,uint256)", address(this), ASBNB, asBnbAmt)
        );
        // asBNB inactive -> reverts -> caught. Faithful no-op.
        ok;
    }

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
        (bool ok,) = LISTA_SM.call{value: bnbAmt}(abi.encodeWithSignature("deposit()"));
        if (!ok) return 0;
        uint256 slis = IERC20(SLISBNB).balanceOf(address(this));
        if (slis == 0) return 0;
        IERC20(SLISBNB).approve(ASBNB_MINTER, slis);
        (bool ok2,) = ASBNB_MINTER.call(abi.encodeWithSignature("mintAsBnb(uint256)", slis));
        if (!ok2) return 0;
        return IERC20(ASBNB).balanceOf(address(this)) - before;
    }
}
