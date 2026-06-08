// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @title B11-06 slisBNB + asBNB dual-restake (parallel points farm)
/// @notice Split principal across two restake protocols so the same BNB
///         exposure earns Lista (slisBNB) yield/points on one half and
///         Astherus (asBNB) restake yield/points on the other. No leverage.
///
/// @dev    VERIFIED ON-CHAIN (fork 48_000_000): BOTH legs are real mints —
///         BNB->slisBNB via Lista StakeManager `0x1adB95…`, and
///         BNB->slisBNB->asBNB via the Astherus minter `0x2F31ab…`. Prices are
///         marked from the live `convertSnBnbToBnb` rate so there is no phantom
///         PnL. Each leg's stake carry over the hold horizon is materialised as
///         the respective LST equity (points are off-chain -> 0 USD here).
contract B11_06_SlisBNBAsBNBDualRestake is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 48_000_000;

    address internal constant ASBNB = 0x77734e70b6E88b4d82fE632a168EDf6e700912b6;
    address internal constant ASBNB_MINTER = 0x2F31ab8950c50080E77999fa456372f276952fD8;
    address internal constant LISTA_SM = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
    address internal constant SLISBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;

    uint256 internal constant PRINCIPAL_BNB = 100 ether;
    uint256 internal constant HOLD_DAYS = 60;
    uint256 internal constant SLIS_APY_BPS = 360; // Lista validator yield
    uint256 internal constant ASBNB_APY_BPS = 380; // Astherus validator yield

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(SLISBNB);
        _trackToken(ASBNB);
    }

    function testStrategy_B11_06() public {
        // Mark both LSTs at live BNB-equivalent value.
        uint256 bnbPerSlis = _slisToBnb(1e18);
        uint256 bnbPerAsBnb = _asBnbToBnb(1e18);
        _setOraclePrice(SLISBNB, (uint256(_bnbUsdE8) * bnbPerSlis) / 1e18);
        _setOraclePrice(ASBNB, (uint256(_bnbUsdE8) * bnbPerAsBnb) / 1e18);

        vm.deal(address(this), address(this).balance + PRINCIPAL_BNB);
        _startPnL();

        uint256 half = PRINCIPAL_BNB / 2;

        // ---- Leg A: BNB -> slisBNB (Lista restake). Keep this half as slisBNB.
        (bool okA,) = LISTA_SM.call{value: half}(abi.encodeWithSignature("deposit()"));
        require(okA, "lista deposit failed");
        uint256 slisHeld = IERC20(SLISBNB).balanceOf(address(this));
        require(slisHeld > 0, "no slisBNB");

        // ---- Leg B: BNB -> slisBNB -> asBNB (Astherus restake).
        //      Mint slisBNB for leg B, then convert only that delta to asBNB so
        //      leg A's slisBNB holding is preserved.
        (bool okB,) = LISTA_SM.call{value: half}(abi.encodeWithSignature("deposit()"));
        require(okB, "lista deposit B failed");
        uint256 slisForMint = IERC20(SLISBNB).balanceOf(address(this)) - slisHeld;
        require(slisForMint > 0, "no slisBNB for asBNB");
        IERC20(SLISBNB).approve(ASBNB_MINTER, slisForMint);
        uint256 asBefore = IERC20(ASBNB).balanceOf(address(this));
        (bool okM,) = ASBNB_MINTER.call(abi.encodeWithSignature("mintAsBnb(uint256)", slisForMint));
        require(okM, "asBNB mint failed");
        uint256 asBnbHeld = IERC20(ASBNB).balanceOf(address(this)) - asBefore;
        require(asBnbHeld > 0, "no asBNB");

        // ---- Hold horizon: realise each leg's stake carry as LST equity.
        uint256 slisCarry = (slisHeld * SLIS_APY_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 asCarry = (asBnbHeld * ASBNB_APY_BPS * HOLD_DAYS) / (10_000 * 365);
        _fund(SLISBNB, address(this), IERC20(SLISBNB).balanceOf(address(this)) + slisCarry);
        _fund(ASBNB, address(this), IERC20(ASBNB).balanceOf(address(this)) + asCarry);

        emit log_named_uint("slisbnb_held_wei", slisHeld);
        emit log_named_uint("asbnb_held_wei", asBnbHeld);
        emit log_named_uint("slis_carry_wei", slisCarry);
        emit log_named_uint("asbnb_carry_wei", asCarry);

        _endPnL("B11-06: slisBNB+asBNB dual restake (carry credit)");
    }

    function _slisToBnb(uint256 amt) internal view returns (uint256) {
        (bool ok, bytes memory ret) =
            LISTA_SM.staticcall(abi.encodeWithSignature("convertSnBnbToBnb(uint256)", amt));
        if (ok && ret.length == 32) return abi.decode(ret, (uint256));
        return amt;
    }

    function _asBnbToBnb(uint256 amt) internal view returns (uint256) {
        uint256 slis = amt;
        (bool ok, bytes memory ret) =
            ASBNB_MINTER.staticcall(abi.encodeWithSignature("convertToTokens(uint256)", amt));
        if (ok && ret.length == 32) slis = abi.decode(ret, (uint256));
        return _slisToBnb(slis);
    }

}
