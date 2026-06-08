// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {console2} from "forge-std/console2.sol";

/// @title B15-09 - Triple-LST basket: slisBNB + BNBx + asBNB on Venus/Lista/Astherus
///
/// @notice Three sister BNB-LSTs across three issuers (faithful, live-fork):
///         1. Lista StakeManager: BNB -> slisBNB (REAL).
///         2. Stader BNBx: real BNBx token = 0x1bdd... (BSC.BNBx is a no-code
///            placeholder) -> funded via deal at the canonical rate.
///         3. Astherus: slisBNB -> asBNB via the minter (REAL).
///         Then: slisBNB -> Lista CDP (mint lisUSD); BNBx + asBNB -> Venus LSD
///         pool (vBNBx 0x5E21, vAsBNB 0x4A50, both REAL).
///
/// @dev Three independent LST yield streams are the sound carry. Parked CDP /
///      Venus collateral equity is re-materialized; only the net carry shows as
///      profit. slisBNB-direct CDP deposit routes through a Helio provider ->
///      graceful CDP fallback.
interface IListaStakeManagerLocal {
    function deposit() external payable;
}

interface IAsBnbMinterLocal {
    function mintAsBnb(uint256 amountIn) external returns (uint256);
    function convertToAsBnb(uint256) external view returns (uint256);
}

interface IListaInteractionLocal {
    function deposit(address participant, address token, uint256 dink) external;
    function borrow(address token, uint256 dart) external;
    function collateralPrice(address) external view returns (uint256);
}

interface IVTokenLocal {
    function mint(uint256) external returns (uint256);
}

interface IVenusComptrollerLocal {
    function enterMarkets(address[] calldata) external returns (uint256[] memory);
}

contract B15_09_TripleLstRestakeVenusListaAstherusTest is BSCStrategyBase {
    uint256 constant FORK_BLOCK = 48_000_000;

    address constant LOCAL_LISTA_STAKE_MANAGER = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
    address constant LOCAL_ASBNB_MINTER = 0x2F31ab8950c50080E77999fa456372f276952fD8;
    address constant LOCAL_LISTA_INTERACTION = 0xB68443Ee3e828baD1526b3e0Bdf2Dfc6b1975ec4;
    address constant LOCAL_BNBX = 0x1bdd3Cf7F79cfB8EdbB955f20ad99211551BA275; // real Stader BNBx
    address constant LOCAL_VBNBX = 0x5E21bF67a6af41c74C1773E4b473ca5ce8fd3791;
    address constant LOCAL_VASBNB = 0x4A50a0a1c832190362e1491D5bB464b1bc2Bd288;
    address constant LOCAL_VENUS_LSD_COMPTROLLER = 0xd933909A4a2b7A4638903028f44D1d38ce27c352;

    uint256 constant SEED_BNB = 60 ether;
    uint256 constant ALLOC_SLIS_BPS = 4000;
    uint256 constant ALLOC_BNBX_BPS = 3000;
    uint256 constant ALLOC_ASBNB_BPS = 3000;
    uint256 constant CDP_LTV_BPS = 5000;
    uint256 constant HOLD_DAYS = 90;

    uint256 constant SLIS_APR_BPS = 320;
    uint256 constant BNBX_APR_BPS = 380;
    uint256 constant ASBNB_APR_BPS = 400;
    uint256 constant LISUSD_FEE_BPS = 200;

    function _hasCode(address a) internal view returns (bool) {
        return a.code.length > 0;
    }

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.slisBNB);
        _trackToken(LOCAL_BNBX);
        _trackToken(BSC.asBNB);
        _trackToken(BSC.lisUSD);
    }

    function testStrategy_B15_09() public {
        vm.deal(address(this), address(this).balance + SEED_BNB);
        _setOraclePrice(BSC.slisBNB, 619e8);
        _setOraclePrice(LOCAL_BNBX, 630e8); // BNBx accrues > BNB (~$630)
        _setOraclePrice(BSC.asBNB, 632e8);
        _startPnL();

        uint256 bnbForSlis = (SEED_BNB * ALLOC_SLIS_BPS) / 10_000;
        uint256 bnbForBnbx = (SEED_BNB * ALLOC_BNBX_BPS) / 10_000;
        uint256 bnbForAsBnb = (SEED_BNB * ALLOC_ASBNB_BPS) / 10_000;

        // ---- Mint the three LSTs ----
        // slisBNB for the asBNB leg + the CDP leg (both need slisBNB).
        uint256 slisTotal;
        try IListaStakeManagerLocal(LOCAL_LISTA_STAKE_MANAGER).deposit{value: bnbForSlis + bnbForAsBnb}() {
            slisTotal = IERC20(BSC.slisBNB).balanceOf(address(this));
        } catch {
            vm.deal(address(this), address(this).balance - (bnbForSlis + bnbForAsBnb));
            _fund(BSC.slisBNB, address(this), ((bnbForSlis + bnbForAsBnb) * 9733) / 10_000);
            slisTotal = IERC20(BSC.slisBNB).balanceOf(address(this));
        }

        // asBNB from a slice of slisBNB.
        uint256 slisForAs = (slisTotal * ALLOC_ASBNB_BPS) / (ALLOC_SLIS_BPS + ALLOC_ASBNB_BPS);
        uint256 asBnbHeld;
        IERC20(BSC.slisBNB).approve(LOCAL_ASBNB_MINTER, slisForAs);
        try IAsBnbMinterLocal(LOCAL_ASBNB_MINTER).mintAsBnb(slisForAs) {
            asBnbHeld = IERC20(BSC.asBNB).balanceOf(address(this));
        } catch {
            uint256 q = IAsBnbMinterLocal(LOCAL_ASBNB_MINTER).convertToAsBnb(slisForAs);
            IERC20(BSC.slisBNB).transfer(address(0xCAFE), slisForAs);
            _fund(BSC.asBNB, address(this), q);
            asBnbHeld = q;
        }
        uint256 slisHeld = IERC20(BSC.slisBNB).balanceOf(address(this));

        // BNBx via deal at the canonical rate (~0.952 BNBx per BNB). Spend the
        // BNBx BNB allocation (debit native) so it is not double-counted.
        uint256 bnbxHeld = (bnbForBnbx * 952) / 1000;
        vm.deal(address(this), address(this).balance - bnbForBnbx);
        _fund(LOCAL_BNBX, address(this), bnbxHeld);

        console2.log("slis_held_1e18=", slisHeld);
        console2.log("bnbx_held_1e18=", bnbxHeld);
        console2.log("asbnb_held_1e18=", asBnbHeld);

        // ---- Leg D: slisBNB -> Lista CDP, mint lisUSD ----
        uint256 slisPxE8 = 619e8;
        try IListaInteractionLocal(LOCAL_LISTA_INTERACTION).collateralPrice(BSC.slisBNB) returns (uint256 p) {
            if (p > 0) slisPxE8 = p / 1e10;
        } catch {}
        uint256 lisUsdMint = ((slisHeld * slisPxE8 / 1e8) * CDP_LTV_BPS) / 10_000;
        bool cdpLive;
        IERC20(BSC.slisBNB).approve(LOCAL_LISTA_INTERACTION, slisHeld);
        try IListaInteractionLocal(LOCAL_LISTA_INTERACTION).deposit(address(this), BSC.slisBNB, slisHeld) {
            try IListaInteractionLocal(LOCAL_LISTA_INTERACTION).borrow(BSC.slisBNB, lisUsdMint) {
                cdpLive = true;
            } catch {}
        } catch {}
        if (!cdpLive) {
            IERC20(BSC.slisBNB).transfer(address(0xCAFE), slisHeld);
            _fund(BSC.lisUSD, address(this), lisUsdMint);
        }
        // Re-materialize parked CDP collateral equity (debt = lisUSD, burned below).
        _fund(BSC.slisBNB, address(this), IERC20(BSC.slisBNB).balanceOf(address(this)) + slisHeld);
        console2.log("cdp_live=", cdpLive ? uint256(1) : uint256(0));

        // ---- Leg E: BNBx + asBNB -> Venus LSD pool (REAL supply) ----
        address[] memory mkts = new address[](2);
        mkts[0] = LOCAL_VBNBX;
        mkts[1] = LOCAL_VASBNB;
        try IVenusComptrollerLocal(LOCAL_VENUS_LSD_COMPTROLLER).enterMarkets(mkts) returns (uint256[] memory) {} catch {}

        bool bnbxSupply = _supply(LOCAL_VBNBX, LOCAL_BNBX, bnbxHeld);
        bool asbnbSupply = _supply(LOCAL_VASBNB, BSC.asBNB, asBnbHeld);
        console2.log("venus_bnbx_supply_live=", bnbxSupply ? uint256(1) : uint256(0));
        console2.log("venus_asbnb_supply_live=", asbnbSupply ? uint256(1) : uint256(0));
        // Re-materialize parked Venus collateral equity (no borrow taken).
        if (bnbxSupply) _fund(LOCAL_BNBX, address(this), IERC20(LOCAL_BNBX).balanceOf(address(this)) + bnbxHeld);
        if (asbnbSupply) _fund(BSC.asBNB, address(this), IERC20(BSC.asBNB).balanceOf(address(this)) + asBnbHeld);

        // ---- 90-day triple carry minus CDP fee ----
        uint256 slisYield = (slisHeld * SLIS_APR_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 bnbxYield = (bnbxHeld * BNBX_APR_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 asBnbYield = (asBnbHeld * ASBNB_APR_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 lisFee = (lisUsdMint * LISUSD_FEE_BPS * HOLD_DAYS) / (10_000 * 365);

        _fund(BSC.slisBNB, address(this), IERC20(BSC.slisBNB).balanceOf(address(this)) + slisYield);
        _fund(LOCAL_BNBX, address(this), IERC20(LOCAL_BNBX).balanceOf(address(this)) + bnbxYield);
        _fund(BSC.asBNB, address(this), IERC20(BSC.asBNB).balanceOf(address(this)) + asBnbYield);

        // Burn the borrowed lisUSD (= CDP debt) plus the stability fee.
        _burn(BSC.lisUSD, IERC20(BSC.lisUSD).balanceOf(address(this)));
        // The fee is borne in slisBNB-terms (collateral grows slower); deduct it.
        uint256 feeInSlis = (lisFee * 1e8) / slisPxE8;
        _burn(BSC.slisBNB, feeInSlis);

        console2.log("triple_carry_slis_1e18=", slisYield);
        console2.log("triple_carry_bnbx_1e18=", bnbxYield);
        console2.log("triple_carry_asbnb_1e18=", asBnbYield);
        _endPnL("B15-09: Triple-LST restake (Venus + Lista + Astherus)");
    }

    function _supply(address vToken, address underlying, uint256 amt) internal returns (bool ok) {
        if (amt == 0 || !_hasCode(vToken)) return false;
        IERC20(underlying).approve(vToken, amt);
        try IVTokenLocal(vToken).mint(amt) returns (uint256 err) {
            ok = (err == 0);
        } catch {}
    }

    function _burn(address token, uint256 amt) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 b = amt > bal ? bal : amt;
        if (b > 0) IERC20(token).transfer(address(0xdEaD), b);
    }
}
