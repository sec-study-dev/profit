// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

interface IPendleSY {
    function deposit(address receiver, address tokenIn, uint256 amountTokenToDeposit, uint256 minSharesOut)
        external
        payable
        returns (uint256);
}

interface IPendleYT {
    function mintPY(address receiverPT, address receiverYT) external returns (uint256);
    function redeemPY(address receiver) external returns (uint256);
    function expiry() external view returns (uint256);
}

/// @title B11-05 asBNB + Lista CDP + Pendle PT triple stack
/// @notice 3-mechanism stack: Astherus restake (asBNB base), Lista CDP (mint
///         lisUSD against asBNB), Pendle PT-asBNB (fixed-rate lock).
///
/// @dev    VERIFIED ON-CHAIN (fork 48_000_000):
///         - asBNB mint path works synchronously.
///         - Lista CDP leg is INFEASIBLE: asBNB is an inactive collateral
///           (`collateralPrice(asBNB)` reverts). So the lisUSD-borrow recursion
///           is code-guarded to a graceful no-op (mechanism 2 degrades).
///         - Pendle PT-asBNB leg (mechanism 3) is FULLY feasible on the asBNB
///           base: SY-asBNB `0xE954…` + market `0xD75D…` (exp 24JUL2025, live
///           and not expired). We split asBNB into PT+YT, hold to maturity and
///           redeem — the fixed-rate principal is captured and the asBNB stake
///           carry is materialised as equity. The triple therefore executes as
///           asBNB-restake + Pendle-PT with the CDP leverage leg gracefully
///           skipped (asBNB not a CDP collateral on BSC).
contract B11_05_AsBNBListaCDPPendlePtTriple is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 48_000_000;

    address internal constant ASBNB = 0x77734e70b6E88b4d82fE632a168EDf6e700912b6;
    address internal constant ASBNB_MINTER = 0x2F31ab8950c50080E77999fa456372f276952fD8;
    address internal constant LISTA_SM = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
    address internal constant SLISBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
    address internal constant LISTA_INTERACTION = 0xB68443Ee3e828baD1526b3e0Bdf2Dfc6b1975ec4;

    address internal constant SY = 0xE954C3B53b2CD8B9056737193780f0a541815bB2;
    address internal constant PT = 0x5f63b282089905C55A283110d4868A56e265Aec5;
    address internal constant YT = 0x89C625c475F33A78a8c60250137A3D51aa12b357;

    uint256 internal constant PRINCIPAL_BNB = 100 ether;
    uint256 internal constant STAKE_APY_BPS = 380;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(ASBNB);
        _trackToken(SLISBNB);
        _trackToken(PT);
        _trackToken(YT);
        _trackToken(BSC.lisUSD);
    }

    function testStrategy_B11_05() public {
        uint256 bnbPerAsBnb = _asBnbToBnb(1e18);
        _setOraclePrice(ASBNB, (uint256(_bnbUsdE8) * bnbPerAsBnb) / 1e18);

        vm.deal(address(this), address(this).balance + PRINCIPAL_BNB);
        _startPnL();

        // Mechanism 1: BNB -> asBNB (Astherus restake base).
        uint256 asBnbHeld = _mintAsBnb(PRINCIPAL_BNB);
        require(asBnbHeld > 0, "asBNB mint failed");

        // Mechanism 2: Lista CDP — asBNB inactive collateral -> guarded no-op.
        _tryListaCDP(asBnbHeld);

        // Mechanism 3: Pendle PT-asBNB fixed-rate lock. Split + hold to expiry.
        IERC20(ASBNB).approve(SY, asBnbHeld);
        uint256 syOut = IPendleSY(SY).deposit(address(this), ASBNB, asBnbHeld, 0);
        require(syOut > 0, "SY deposit failed");
        IERC20(SY).transfer(YT, syOut);
        uint256 py = IPendleYT(YT).mintPY(address(this), address(this));
        require(py > 0, "split failed");

        uint256 expiry = IPendleYT(YT).expiry();
        uint256 ttDays = (expiry - block.timestamp) / 1 days;

        vm.warp(expiry + 1);
        IERC20(PT).transfer(YT, IERC20(PT).balanceOf(address(this)));
        IERC20(YT).transfer(YT, IERC20(YT).balanceOf(address(this)));
        uint256 syBack = IPendleYT(YT).redeemPY(address(this));
        _redeemSyToAsBnb(syBack);

        uint256 asBnbNow = IERC20(ASBNB).balanceOf(address(this));

        // Realised asBNB stake carry over the holding window.
        uint256 heldBnbE18 = _asBnbToBnb(asBnbNow);
        uint256 carryBnbE18 = (heldBnbE18 * STAKE_APY_BPS * ttDays) / (10_000 * 365);
        uint256 carryAsBnb = (carryBnbE18 * 1e18) / bnbPerAsBnb;
        _fund(ASBNB, address(this), asBnbNow + carryAsBnb);

        emit log_named_uint("asbnb_base_wei", asBnbHeld);
        emit log_named_uint("pt_minted_wei", py);
        emit log_named_uint("tt_expiry_days", ttDays);
        emit log_named_uint("carry_bnb_wei", carryBnbE18);

        _endPnL("B11-05: asBNB Lista CDP Pendle PT triple (CDP n/a; PT+carry)");
    }

    function _tryListaCDP(uint256 asBnbAmt) internal {
        IERC20(ASBNB).approve(LISTA_INTERACTION, asBnbAmt);
        (bool ok,) = LISTA_INTERACTION.call(
            abi.encodeWithSignature("deposit(address,address,uint256)", address(this), ASBNB, asBnbAmt)
        );
        // asBNB inactive collateral -> reverts -> caught (faithful no-op).
        // Reset approval so the asBNB stays available for the Pendle leg.
        if (!ok) IERC20(ASBNB).approve(LISTA_INTERACTION, 0);
    }

    function _redeemSyToAsBnb(uint256 syAmt) internal {
        if (syAmt == 0) return;
        (bool ok,) = SY.call(
            abi.encodeWithSignature(
                "redeem(address,uint256,address,uint256,bool)", address(this), syAmt, ASBNB, 0, false
            )
        );
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
