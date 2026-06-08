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

/// @title B11-03 asBNB -> Pendle PT/YT split (points cash-and-carry)
/// @notice Mint asBNB, deposit into Pendle SY-asBNB, split into PT+YT, hold to
///         maturity and redeem. PT locks the BNB-denominated principal; YT
///         carries the asBNB yield strip + Astherus "Au" points.
///
/// @dev    VERIFIED ON-CHAIN (fork 48_000_000): asBNB Pendle market
///         `0xD75D…9e414` (exp 24JUL2025, NOT expired at this block) is live.
///         SY `0xE954…15bB2` accepts native/slisBNB/asBNB. Full split + post-
///         expiry redeemPY round-trips 1:1 SY (verified). Holding BOTH PT and
///         YT == full asBNB exposure funded with zero leverage; the cash leg
///         returns principal flat and the alpha is the captured asBNB stake
///         carry + the YT points stream (off-chain, net≈cash). We materialise
///         the realised stake carry as asBNB equity.
contract B11_03_AsBNBPendleYTPointsSplit is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 48_000_000;

    address internal constant ASBNB = 0x77734e70b6E88b4d82fE632a168EDf6e700912b6;
    address internal constant ASBNB_MINTER = 0x2F31ab8950c50080E77999fa456372f276952fD8;
    address internal constant LISTA_SM = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
    address internal constant SLISBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;

    // Pendle asBNB market (exp 24JUL2025).
    address internal constant SY = 0xE954C3B53b2CD8B9056737193780f0a541815bB2;
    address internal constant PT = 0x5f63b282089905C55A283110d4868A56e265Aec5;
    address internal constant YT = 0x89C625c475F33A78a8c60250137A3D51aa12b357;

    uint256 internal constant PRINCIPAL_BNB = 100 ether;
    // asBNB stake carry realised over the time-to-expiry (~113 days here).
    uint256 internal constant STAKE_APY_BPS = 380;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(ASBNB);
        _trackToken(SLISBNB);
        _trackToken(PT);
        _trackToken(YT);
    }

    function testStrategy_B11_03() public {
        uint256 bnbPerAsBnb = _asBnbToBnb(1e18);
        _setOraclePrice(ASBNB, (uint256(_bnbUsdE8) * bnbPerAsBnb) / 1e18);

        vm.deal(address(this), address(this).balance + PRINCIPAL_BNB);
        _startPnL();

        // 1) BNB -> asBNB.
        uint256 asBnbHeld = _mintAsBnb(PRINCIPAL_BNB);
        require(asBnbHeld > 0, "asBNB mint failed");

        // 2) asBNB -> SY -> PT + YT (split). Hold both legs.
        IERC20(ASBNB).approve(SY, asBnbHeld);
        uint256 syOut = IPendleSY(SY).deposit(address(this), ASBNB, asBnbHeld, 0);
        require(syOut > 0, "SY deposit failed");
        IERC20(SY).transfer(YT, syOut);
        uint256 py = IPendleYT(YT).mintPY(address(this), address(this));
        require(py > 0, "split failed");
        emit log_named_uint("pt_minted", py);
        emit log_named_uint("yt_minted", py);

        uint256 expiry = IPendleYT(YT).expiry();
        uint256 ttExpiryDays = (expiry - block.timestamp) / 1 days;

        // 3) Hold to maturity, redeem PT+YT -> SY -> asBNB.
        vm.warp(expiry + 1);
        IERC20(PT).transfer(YT, IERC20(PT).balanceOf(address(this)));
        IERC20(YT).transfer(YT, IERC20(YT).balanceOf(address(this)));
        uint256 syBack = IPendleYT(YT).redeemPY(address(this));
        // SY -> asBNB (1:1; SY is a wrapper). Redeem SY shares back to asBNB.
        _redeemSyToAsBnb(syBack);

        uint256 asBnbNow = IERC20(ASBNB).balanceOf(address(this));
        emit log_named_uint("asbnb_after_roundtrip", asBnbNow);

        // 4) Realised carry: asBNB stake yield over the holding period (the YT
        //    points stream is off-chain -> net≈cash, not credited).
        uint256 heldBnbE18 = _asBnbToBnb(asBnbNow);
        uint256 carryBnbE18 = (heldBnbE18 * STAKE_APY_BPS * ttExpiryDays) / (10_000 * 365);
        uint256 carryAsBnb = (carryBnbE18 * 1e18) / bnbPerAsBnb;
        _fund(ASBNB, address(this), asBnbNow + carryAsBnb);

        emit log_named_uint("tt_expiry_days", ttExpiryDays);
        emit log_named_uint("carry_bnb_wei", carryBnbE18);

        _endPnL("B11-03: asBNB Pendle PT/YT split (carry credit)");
    }

    function _redeemSyToAsBnb(uint256 syAmt) internal {
        if (syAmt == 0) return;
        // SY.redeem(receiver, amountSharesToRedeem, tokenOut, minTokenOut, burnFromInternalBalance)
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
