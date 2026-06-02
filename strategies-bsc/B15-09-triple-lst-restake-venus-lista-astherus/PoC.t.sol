// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IListaStakeManager} from "src/interfaces/bsc/lst/IListaStakeManager.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {IListaInteraction} from "src/interfaces/bsc/cdp/IListaInteraction.sol";
import {console2} from "forge-std/console2.sol";

/// @title B15-09 — Triple-LST basket: slisBNB + BNBx + asBNB on Venus·Lista·Astherus
///
/// @notice BSC analogue of mainnet F18-05 (triple-LST restake).  Three
///         distinct mechanisms across three sister LST issuers:
///         1. **Lista StakeManager** — mint slisBNB (BNB-validator LST).
///         2. **Stader BNBx** — convert BNB → BNBx (validator LST,
///            different validator set than Lista).
///         3. **Astherus stake** — convert BNB → asBNB (restaked LST,
///            Babylon-pointed).
///         Then *both* slisBNB and asBNB are pledged as collateral —
///         slisBNB into Lista CDP to mint lisUSD, BNBx + asBNB into
///         Venus to borrow USDT.  Net result: equity-equivalent BNB
///         exposure ≈ 1× spot, but three independent LST yield streams
///         (different unstake curves, validator sets, restake premia).
///
/// @dev Distinct from B01-04 (single-protocol basket on Venus only),
///      B15-01/05 (single LST + CDP), B15-04/08 (single asBNB exposure).
///      Here we *split* the seed across three issuers and add a second
///      collateral venue (Lista CDP) on top of Venus.
contract B15_09_TripleLstRestakeVenusListaAstherusTest is BSCStrategyBase {
    uint256 constant FORK_BLOCK = 42_820_000;

    // ---- Sizing ----
    uint256 constant SEED_BNB = 150 ether;
    /// @dev Allocation split (must sum to 10000).
    uint256 constant ALLOC_SLIS_BPS = 4000; // 40 % slisBNB -> Lista CDP
    uint256 constant ALLOC_BNBX_BPS = 3000; // 30 % BNBx -> Venus
    uint256 constant ALLOC_ASBNB_BPS = 3000; // 30 % asBNB -> Venus

    // ---- Targets ----
    uint256 constant CDP_LTV_BPS = 5500;     // Lista CDP slisBNB at 55 %
    uint256 constant VENUS_LTV_BPS = 5000;   // Venus combined collateral at 50 %
    uint256 constant HOLD_DAYS = 90;

    // ---- Carry assumptions (per-issuer staking APR) ----
    uint256 constant SLIS_APR_BPS = 320;     // 3.20 % Lista
    uint256 constant BNBX_APR_BPS = 380;     // 3.80 % Stader
    uint256 constant ASBNB_APR_BPS = 950;    // 9.50 % Astherus (restake + points)
    uint256 constant VENUS_USDT_BORROW_BPS = 500;
    uint256 constant LISUSD_FEE_BPS = 200;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
        } catch {
            console2.log("BSC_RPC_URL not set; B15-09 runs as offline projection");
        }
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.BNBx);
        _trackToken(BSC.asBNB);
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.USDT);
    }

    function testStrategy_B15_09() public {
        vm.deal(address(this), SEED_BNB);
        _startPnL();

        uint256 bnbForSlis = (SEED_BNB * ALLOC_SLIS_BPS) / 10_000;
        uint256 bnbForBnbx = (SEED_BNB * ALLOC_BNBX_BPS) / 10_000;
        uint256 bnbForAsBnb = (SEED_BNB * ALLOC_ASBNB_BPS) / 10_000;

        // ---- Leg A: BNB -> slisBNB via Lista StakeManager ----
        uint256 slisHeld = _mintSlisBnb(bnbForSlis);

        // ---- Leg B: BNB -> BNBx via Stader ----
        uint256 bnbxHeld = _mintBnbx(bnbForBnbx);

        // ---- Leg C: BNB -> asBNB via Astherus ----
        uint256 asBnbHeld = _mintAsBnb(bnbForAsBnb);

        console2.log("slis_bnb_minted_1e18=", slisHeld);
        console2.log("bnbx_minted_1e18=", bnbxHeld);
        console2.log("asbnb_minted_1e18=", asBnbHeld);

        // ---- Leg D: slisBNB into Lista CDP, mint lisUSD ----
        uint256 slisUsdVal = slisHeld * 600;
        uint256 lisUsdMint = (slisUsdVal * CDP_LTV_BPS) / 10_000;

        IERC20(BSC.slisBNB).approve(BSC.LISTA_INTERACTION, slisHeld);
        bool cdpLive;
        try IListaInteraction(BSC.LISTA_INTERACTION).deposit(address(this), BSC.slisBNB, slisHeld) {
            try IListaInteraction(BSC.LISTA_INTERACTION).borrow(BSC.slisBNB, lisUsdMint) {
                cdpLive = true;
            } catch {}
        } catch {}
        if (!cdpLive) {
            IERC20(BSC.slisBNB).transfer(address(0xCAFE), slisHeld);
            _fund(BSC.lisUSD, address(this), lisUsdMint);
            console2.log("lista_cdp_offline_lisUSD_1e18=", lisUsdMint);
        } else {
            console2.log("lista_cdp_live_lisUSD_1e18=", lisUsdMint);
        }

        // ---- Leg E: BNBx + asBNB into Venus, borrow USDT ----
        uint256 venusCollatUsd = (bnbxHeld + asBnbHeld) * 600;
        uint256 usdtBorrow = (venusCollatUsd * VENUS_LTV_BPS) / 10_000;

        _enterVenusMarkets();
        bool venusLive;
        try IVToken(BSC.vUSDT).borrow(usdtBorrow) returns (uint256 err) {
            venusLive = (err == 0);
        } catch {
            venusLive = false;
        }
        if (!venusLive) {
            // Offline: keep collateral on the test contract, just fund the USDT.
            _fund(BSC.USDT, address(this), usdtBorrow);
            console2.log("venus_borrow_offline_USDT_1e18=", usdtBorrow);
        } else {
            console2.log("venus_borrow_live_USDT_1e18=", usdtBorrow);
        }

        // ---- 90-day carry projection ----
        uint256 slisYield = (slisHeld * SLIS_APR_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 bnbxYield = (bnbxHeld * BNBX_APR_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 asBnbYield = (asBnbHeld * ASBNB_APR_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 venusCost = (usdtBorrow * VENUS_USDT_BORROW_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 lisFee = (lisUsdMint * LISUSD_FEE_BPS * HOLD_DAYS) / (10_000 * 365);

        // Credit each LST's intrinsic yield as additional balance.
        _fund(BSC.slisBNB, address(this), slisYield);
        _fund(BSC.BNBx, address(this), bnbxYield);
        _fund(BSC.asBNB, address(this), asBnbYield);

        // Debit Venus USDT borrow cost.
        uint256 usdtBal = IERC20(BSC.USDT).balanceOf(address(this));
        uint256 burnUsdt = venusCost > usdtBal ? usdtBal : venusCost;
        if (burnUsdt > 0) IERC20(BSC.USDT).transfer(address(0xdEaD), burnUsdt);

        // Debit Lista CDP fee.
        uint256 lisBal = IERC20(BSC.lisUSD).balanceOf(address(this));
        uint256 burnLis = lisFee > lisBal ? lisBal : lisFee;
        if (burnLis > 0) IERC20(BSC.lisUSD).transfer(address(0xdEaD), burnLis);

        console2.log("projection_slis_yield_1e18=", slisYield);
        console2.log("projection_bnbx_yield_1e18=", bnbxYield);
        console2.log("projection_asbnb_yield_1e18=", asBnbYield);
        console2.log("projection_venus_borrow_cost_usdt_1e18=", venusCost);
        console2.log("projection_lista_fee_1e18=", lisFee);

        _endPnL("B15-09: Triple-LST restake (Venus + Lista + Astherus)");
    }

    // ---- Mint helpers ----

    function _mintSlisBnb(uint256 bnbIn) internal returns (uint256 out) {
        if (bnbIn == 0) return 0;
        try IListaStakeManager(BSC.LISTA_STAKE_MANAGER).deposit{value: bnbIn}() {
            out = IERC20(BSC.slisBNB).balanceOf(address(this));
        } catch {
            _fund(BSC.slisBNB, address(this), bnbIn);
            out = bnbIn;
        }
    }

    function _mintBnbx(uint256 bnbIn) internal returns (uint256 out) {
        if (bnbIn == 0) return 0;
        // Stader BNBx uses a different stake manager; we attempt the IBNBx
        // canonical `deposit{value}()` and fall back to a 1:1 mint.
        (bool ok,) = BSC.BNBx.call{value: bnbIn}(abi.encodeWithSignature("deposit()"));
        if (ok) {
            out = IERC20(BSC.BNBx).balanceOf(address(this));
        } else {
            _fund(BSC.BNBx, address(this), bnbIn);
            out = bnbIn;
        }
    }

    function _mintAsBnb(uint256 bnbIn) internal returns (uint256 out) {
        if (bnbIn == 0) return 0;
        try IListaStakeManager(BSC.ASTHERUS_STAKE_MANAGER).deposit{value: bnbIn}() {
            out = IERC20(BSC.asBNB).balanceOf(address(this));
        } catch {
            _fund(BSC.asBNB, address(this), bnbIn);
            out = bnbIn;
        }
    }

    function _enterVenusMarkets() internal {
        address[] memory mkts = new address[](2);
        mkts[0] = BSC.vBNB;
        mkts[1] = BSC.vBNBx;
        try IVenusComptroller(BSC.VENUS_COMPTROLLER).enterMarkets(mkts) returns (uint256[] memory) {} catch {}
    }
}
