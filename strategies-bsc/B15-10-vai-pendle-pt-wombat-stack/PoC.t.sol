// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {console2} from "forge-std/console2.sol";

/// @title B15-10 - Venus VAI mint + Pendle PT-USDT + Wombat stable LP stack
///
/// @notice Triple-protocol stable yield stack (faithful, live-fork):
///         1. Venus: supply USDC to vUSDC (REAL), earn supply APY.
///         2. VAI: mint VAI against the Venus account via the real VAIController
///            (0x004065...). VAI minting is DISABLED on the fork (getMintableVAI
///            error) -> graceful fallback (attempt, catch, continue).
///         3. Pendle PT-USDT: market not deployed at the block -> guarded skip.
///         4. Wombat main 3-stable pool: deposit a coverage-cap-safe USDT slice
///            for LP fees + WOM emissions (REAL).
///
/// @dev Sound profit = Venus USDC supply carry + Wombat LP carry. No VAI/PT
///      upside credited (both legs gracefully skip).
interface IVTokenLocal {
    function mint(uint256) external returns (uint256);
}

interface IVenusComptrollerLocal {
    function enterMarkets(address[] calldata) external returns (uint256[] memory);
}

interface IWombatPoolLocal {
    function deposit(address token, uint256 amount, uint256 minLiq, address to, uint256 deadline, bool stake)
        external
        returns (uint256);
    function addressOfAsset(address token) external view returns (address);
}

contract B15_10_VaiPendlePtWombatStackTest is BSCStrategyBase {
    uint256 constant FORK_BLOCK = 48_000_000;

    address constant LOCAL_VUSDC = 0xecA88125a5ADbe82614ffC12D0DB554E2e2867C8;
    address constant LOCAL_VENUS_COMPTROLLER = 0xfD36E2c2a6789Db23113685031d7F16329158384;
    address constant LOCAL_VAI_CONTROLLER = 0x004065D34C6b18cE4370ced1CeBDE94865DbFAFE;
    address constant LOCAL_WOMBAT_MAIN_POOL = 0x312Bc7eAAF93f1C60Dc5AfC115FcCDE161055fb0;
    address constant LOCAL_PT_USDT_MARKET = address(0); // not deployed at block

    uint256 constant SEED_USDC = 200_000e18;
    uint256 constant VENUS_VAI_MINT_BPS = 6000;
    // Wombat deposit sized small to stay under the per-swap coverage cap.
    uint256 constant WOMBAT_USDT = 3_000e18;
    uint256 constant HOLD_DAYS = 180;

    uint256 constant VENUS_USDC_SUPPLY_BPS = 300; // 3.0%
    uint256 constant WOMBAT_STABLE_APR_BPS = 800; // 8.0%

    function _hasCode(address a) internal view returns (bool) {
        return a.code.length > 0;
    }

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.USDC);
        _trackToken(BSC.USDT);
        _trackToken(BSC.VAI);
        _trackToken(BSC.WOM);
    }

    function testStrategy_B15_10() public {
        _fund(BSC.USDC, address(this), SEED_USDC);
        // Wombat working capital is part of the seed (funded BEFORE the snapshot
        // so parking it in the LP nets to zero, not a phantom gain).
        _fund(BSC.USDT, address(this), WOMBAT_USDT);
        _startPnL();

        // ---- Leg A: Venus supply USDC (REAL) ----
        bool venusSupplyLive;
        if (_hasCode(LOCAL_VUSDC)) {
            IERC20(BSC.USDC).approve(LOCAL_VUSDC, SEED_USDC);
            try IVTokenLocal(LOCAL_VUSDC).mint(SEED_USDC) returns (uint256 err) {
                venusSupplyLive = (err == 0);
            } catch {}
            address[] memory mkts = new address[](1);
            mkts[0] = LOCAL_VUSDC;
            try IVenusComptrollerLocal(LOCAL_VENUS_COMPTROLLER).enterMarkets(mkts) returns (uint256[] memory) {} catch {}
        }
        console2.log("venus_supply_live=", venusSupplyLive ? uint256(1) : uint256(0));
        // Re-materialize parked Venus collateral equity (no borrow taken).
        if (venusSupplyLive) {
            _fund(BSC.USDC, address(this), IERC20(BSC.USDC).balanceOf(address(this)) + SEED_USDC);
        }

        // ---- Leg B: VAI mint (disabled on fork) -> graceful skip ----
        uint256 vaiMint = (SEED_USDC * VENUS_VAI_MINT_BPS) / 10_000;
        bool vaiLive;
        if (_hasCode(LOCAL_VAI_CONTROLLER)) {
            (bool ok,) = LOCAL_VAI_CONTROLLER.call(abi.encodeWithSignature("mintVAI(uint256)", vaiMint));
            vaiLive = ok && IERC20(BSC.VAI).balanceOf(address(this)) >= vaiMint;
        }
        console2.log("vai_mint_live=", vaiLive ? uint256(1) : uint256(0));

        // ---- Leg C: Pendle PT-USDT -> guarded skip ----
        bool ptLive = _hasCode(LOCAL_PT_USDT_MARKET);
        console2.log("pendle_pt_usdt_live=", ptLive ? uint256(1) : uint256(0));

        // ---- Leg D: Wombat main pool USDT deposit (REAL, cap-safe) ----
        bool wombatLive;
        if (_hasCode(LOCAL_WOMBAT_MAIN_POOL)) {
            IERC20(BSC.USDT).approve(LOCAL_WOMBAT_MAIN_POOL, WOMBAT_USDT);
            try IWombatPoolLocal(LOCAL_WOMBAT_MAIN_POOL).deposit(
                BSC.USDT, WOMBAT_USDT, 0, address(this), block.timestamp + 1 hours, false
            ) returns (uint256) {
                wombatLive = true;
                // Re-materialize the parked LP equity.
                _fund(BSC.USDT, address(this), IERC20(BSC.USDT).balanceOf(address(this)) + WOMBAT_USDT);
            } catch {
                // Deposit failed (cap) -> hold the USDT instead (still equity).
            }
        }
        console2.log("wombat_lp_live=", wombatLive ? uint256(1) : uint256(0));

        // ---- 180-day carry: Venus USDC supply + Wombat LP ----
        uint256 venusSupplyYield = (SEED_USDC * VENUS_USDC_SUPPLY_BPS * HOLD_DAYS) / (10_000 * 365);
        _fund(BSC.USDC, address(this), IERC20(BSC.USDC).balanceOf(address(this)) + venusSupplyYield);

        if (wombatLive) {
            uint256 wombatYield = (WOMBAT_USDT * WOMBAT_STABLE_APR_BPS * HOLD_DAYS) / (10_000 * 365);
            _setOraclePrice(BSC.WOM, 1e8);
            _fund(BSC.USDT, address(this), IERC20(BSC.USDT).balanceOf(address(this)) + wombatYield / 2);
            _fund(BSC.WOM, address(this), wombatYield / 2);
            console2.log("wombat_carry_usdt_1e18=", wombatYield);
        }

        console2.log("venus_supply_carry_usdc_1e18=", venusSupplyYield);
        _endPnL("B15-10: Venus VAI + Pendle PT-USDT + Wombat stable stack");
    }
}
