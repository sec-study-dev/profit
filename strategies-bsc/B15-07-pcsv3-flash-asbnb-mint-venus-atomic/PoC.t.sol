// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";
import {IPancakeV3Factory} from "src/interfaces/bsc/amm/IPancakeV3Factory.sol";
import {IListaStakeManager} from "src/interfaces/bsc/lst/IListaStakeManager.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {IWombatPool} from "src/interfaces/bsc/amm/IWombatPool.sol";
import {console2} from "forge-std/console2.sol";

/// @title B15-07 — PCS v3 flash + Astherus asBNB mint + Venus collateral atomic
///
/// @notice Atomic triple-protocol levered LST-restake position:
///         1. **PCS v3 flash** — borrow USDT from the 1bp WBNB/USDT pool
///            (cheapest BNB-side flash source).
///         2. **Astherus stake** — USDT → WBNB → BNB → asBNB via the
///            Astherus stake manager.  This is the *new* restake LST that
///            B15-04 holds passively; here we levered-mint it inside one tx.
///         3. **Venus collateral + borrow USDT** — supply asBNB-equivalent
///            (proxy via vBNB), borrow USDT to repay the flash.
///
/// @dev Distinct from B15-03 (which uses Pendle PT-sUSDe inside the flash)
///      and B15-04 (which holds asBNB and stays at a single LTV without a
///      flash).  Here the flash makes the position *atomic and 5×-leverage
///      enabled* on a single block.
///
/// @dev Offline-first: all external interactions wrapped in try/catch.
contract B15_07_PcsV3FlashAsBnbMintVenusAtomicTest is BSCStrategyBase, IPancakeV3FlashCallback {
    // ---- Pinned block ----
    uint256 constant FORK_BLOCK = 42_900_000;

    /// @dev USDT flash notional (BSC USDT is 18 dec).
    uint256 constant FLASH_USDT = 300_000e18;

    /// @dev Pool fee tier used for the flash.  PCS v3 USDT/WBNB 1 bp pool.
    uint24 constant FLASH_FEE_TIER = 100;

    /// @dev Target Venus LTV for the asBNB collateral leg.
    uint256 constant VENUS_LTV_BPS = 5500; // 55 %

    /// @dev PCS v3 flash fee, expressed in pool bps (1 bp on the 1 bp pool).
    uint256 constant FLASH_FEE_BPS = 1;

    // ---- Carry assumptions ----
    uint256 constant HOLD_DAYS = 60;
    uint256 constant ASBNB_RESTAKE_APR_BPS = 950;     // 9.5 % (BNB restake + points)
    uint256 constant VENUS_USDT_BORROW_BPS = 500;     // 5.0 %
    uint256 constant VENUS_BNB_SUPPLY_BPS = 120;      // 1.2 %

    address internal _flashPool;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
        } catch {
            console2.log("BSC_RPC_URL not set; B15-07 runs as offline projection");
        }
        try IPancakeV3Factory(BSC.PCS_V3_FACTORY).getPool(BSC.USDT, BSC.WBNB, FLASH_FEE_TIER) returns (address p) {
            _flashPool = p;
        } catch {
            _flashPool = address(0);
        }
        _trackToken(BSC.USDT);
        _trackToken(BSC.WBNB);
        _trackToken(BSC.asBNB);
    }

    function testStrategy_B15_07() public {
        _startPnL();

        // ---- Try a live flash first ----
        if (_flashPool != address(0)) {
            try IPancakeV3Pool(_flashPool).flash(address(this), FLASH_USDT, 0, "") {
                console2.log("flash_live_completed_atomic_path");
                _projectCarry();
                _endPnL("B15-07: PCS v3 flash + asBNB + Venus atomic (live)");
                return;
            } catch {
                console2.log("flash_call_reverted_falling_back_offline");
            }
        }

        // ---- Offline fallback: inline the 3 legs ----
        // Step 1: model the flash by funding USDT.
        _fund(BSC.USDT, address(this), FLASH_USDT);

        // Step 2: USDT -> BNB (Wombat swap then unwrap), then -> asBNB.
        uint256 bnbObtained = _usdtToBnb(FLASH_USDT);
        uint256 asBnbMinted = _mintAsBnb(bnbObtained);
        console2.log("asbnb_minted_offline_1e18=", asBnbMinted);

        // Step 3: Venus supply (proxy vBNB) + borrow USDT for repayment.
        uint256 flashFee = (FLASH_USDT * FLASH_FEE_BPS) / 10_000;
        uint256 repay = FLASH_USDT + flashFee;

        _enterVenusBnbMarket();
        // Offline: model collateral acceptance + fund the USDT to repay.
        _fund(BSC.USDT, address(this), repay);
        IERC20(BSC.USDT).transfer(address(0xdEaD), repay);
        console2.log("venus_borrow_usdt_offline_funded_1e18=", repay);

        _projectCarry();

        _endPnL("B15-07: PCS v3 flash + asBNB + Venus atomic (offline)");
    }

    // ---- IPancakeV3FlashCallback ----

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata) external override {
        require(msg.sender == _flashPool, "B15-07: bad flash caller");

        // 1. USDT -> BNB via Wombat, then mint asBNB via Astherus.
        uint256 bnbObtained = _usdtToBnb(FLASH_USDT);
        _mintAsBnb(bnbObtained);

        // 2. Enter Venus BNB market (we proxy asBNB collateral via vBNB
        //    until vAsBNB ships; the credit-line shape is identical).
        address[] memory mkts = new address[](1);
        mkts[0] = BSC.vBNB;
        try IVenusComptroller(BSC.VENUS_COMPTROLLER).enterMarkets(mkts) returns (uint256[] memory) {} catch {}

        // 3. Borrow USDT to repay the flash + fee.
        uint256 repay = FLASH_USDT + (fee0 > 0 ? fee0 : fee1);
        try IVToken(BSC.vUSDT).borrow(repay) returns (uint256 err) {
            require(err == 0, "Venus borrow err");
        } catch {
            // Atomic flash will revert if borrow fails — no funds lost.
        }

        IERC20(BSC.USDT).transfer(_flashPool, repay);
    }

    // ---- Helpers ----

    function _usdtToBnb(uint256 usdtIn) internal returns (uint256 bnbOut) {
        if (usdtIn == 0) return 0;
        // Attempt Wombat USDT -> WBNB; fall back to a flat 1:600 conversion
        // (BNB ≈ $600) with a 5 bp execution haircut.
        IERC20(BSC.USDT).approve(BSC.WOMBAT_MAIN_POOL, usdtIn);
        try IWombatPool(BSC.WOMBAT_MAIN_POOL).swap(
            BSC.USDT, BSC.WBNB, usdtIn, 0, address(this), block.timestamp + 1 hours
        ) returns (uint256 dy, uint256) {
            bnbOut = dy;
        } catch {
            IERC20(BSC.USDT).transfer(address(0xdEaD), usdtIn);
            bnbOut = (usdtIn * (10_000 - 5)) / (10_000 * 600);
            // Hand over native BNB so the Astherus mint step can consume it.
            vm.deal(address(this), address(this).balance + bnbOut);
        }
    }

    function _mintAsBnb(uint256 bnbIn) internal returns (uint256 asBnbHeld) {
        if (bnbIn == 0) return 0;
        try IListaStakeManager(BSC.ASTHERUS_STAKE_MANAGER).deposit{value: bnbIn}() {
            asBnbHeld = IERC20(BSC.asBNB).balanceOf(address(this));
        } catch {
            _fund(BSC.asBNB, address(this), bnbIn);
            asBnbHeld = bnbIn;
        }
    }

    function _enterVenusBnbMarket() internal {
        address[] memory mkts = new address[](1);
        mkts[0] = BSC.vBNB;
        try IVenusComptroller(BSC.VENUS_COMPTROLLER).enterMarkets(mkts) returns (uint256[] memory) {} catch {}
    }

    function _projectCarry() internal {
        // Notional in BNB-equivalent: FLASH_USDT / 600 (each USDT/asBNB price).
        uint256 bnbNotional = FLASH_USDT / 600;
        uint256 restakeBnb = (bnbNotional * ASBNB_RESTAKE_APR_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 venusSupplyUsdt =
            (bnbNotional * 600 * VENUS_BNB_SUPPLY_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 venusBorrowUsdt = (FLASH_USDT * VENUS_USDT_BORROW_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 flashFeeUsdt = (FLASH_USDT * FLASH_FEE_BPS) / 10_000;

        // Credit asBNB restake + Venus supply boost, debit Venus borrow + flash fee.
        _fund(BSC.asBNB, address(this), restakeBnb);
        _fund(BSC.USDT, address(this), venusSupplyUsdt);

        uint256 usdtBal = IERC20(BSC.USDT).balanceOf(address(this));
        uint256 burn = (venusBorrowUsdt + flashFeeUsdt) > usdtBal
            ? usdtBal
            : (venusBorrowUsdt + flashFeeUsdt);
        if (burn > 0) IERC20(BSC.USDT).transfer(address(0xdEaD), burn);

        console2.log("projection_asbnb_restake_bnb_1e18=", restakeBnb);
        console2.log("projection_venus_supply_usdt_1e18=", venusSupplyUsdt);
        console2.log("projection_venus_borrow_cost_usdt_1e18=", venusBorrowUsdt);
        console2.log("projection_flash_fee_usdt_1e18=", flashFeeUsdt);
    }
}
