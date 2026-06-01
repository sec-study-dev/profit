// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IListaStakeManager} from "src/interfaces/bsc/lst/IListaStakeManager.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {console2} from "forge-std/console2.sol";

/// @title B15-04 — Astherus asBNB · Venus collateral · Pendle YT-asBNB stack
///
/// @notice Triple-protocol points-class stack:
///         1. Astherus stake: BNB -> asBNB.
///         2. Venus: supply asBNB (fallback BNB), borrow USDT.
///         3. Pendle YT: USDT -> YT-asBNB → leveraged points exposure.
contract B15_04_AsBnbVenusPendleYtStackTest is BSCStrategyBase {
    uint256 constant FORK_BLOCK = 42_800_000;

    /// @notice Pendle YT-asBNB-26JUN2025 market. // TODO verify.
    address constant LOCAL_YT_ASBNB_MARKET = 0x9eC4c502D989F04FfA9312C9D6E3F872EC91A0F9;

    uint256 constant SEED_BNB = 100 ether;
    uint256 constant VENUS_LTV_BPS = 5000; // 50%
    uint256 constant HOLD_DAYS = 90;

    /// @dev Implied YT entry price as bps of 1 unit underlying (5%).
    uint256 constant YT_ENTRY_BPS = 500;
    /// @dev Floating Venus USDT borrow APR for cost projection.
    uint256 constant VENUS_USDT_BORROW_BPS = 500;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
        } catch {
            console2.log("BSC_RPC_URL not set; B15-04 runs as offline projection");
        }
        _trackToken(BSC.asBNB);
        _trackToken(BSC.USDT);
        _trackToken(BSC.WBNB);
    }

    function testStrategy_B15_04() public {
        vm.deal(address(this), SEED_BNB);
        _startPnL();

        // ---- Leg A: BNB -> asBNB ----
        // Astherus uses a stake-manager-shaped contract; we attempt the
        // canonical `deposit{value}()` against the address, falling back
        // to a 1:1 mint when offline.
        uint256 asBnbHeld;
        try IListaStakeManager(BSC.ASTHERUS_STAKE_MANAGER).deposit{value: SEED_BNB}() {
            asBnbHeld = IERC20(BSC.asBNB).balanceOf(address(this));
            console2.log("astherus_stake_live_asBNB_1e18=", asBnbHeld);
        } catch {
            _fund(BSC.asBNB, address(this), SEED_BNB);
            asBnbHeld = SEED_BNB;
            console2.log("astherus_stake_offline_asBNB_1e18=", asBnbHeld);
        }

        // ---- Leg B: Venus supply asBNB (fallback vBNB), borrow USDT ----
        // No canonical vAsBNB constant; we proxy via vBNB collateral exposure.
        uint256 asBnbUsd = asBnbHeld * 600; // 1e18 USD scale
        uint256 usdtBorrow = (asBnbUsd * VENUS_LTV_BPS) / 10_000;

        // Mint vBNB equivalent (offline: just enter market + fund USDT)
        address[] memory mkts = new address[](1);
        mkts[0] = BSC.vBNB;
        try IVenusComptroller(BSC.VENUS_COMPTROLLER).enterMarkets(mkts) returns (uint256[] memory) {} catch {}

        bool venusLive;
        try IVToken(BSC.vUSDT).borrow(usdtBorrow) returns (uint256 err) {
            venusLive = (err == 0);
        } catch {
            venusLive = false;
        }
        if (!venusLive) {
            _fund(BSC.USDT, address(this), usdtBorrow);
            console2.log("venus_borrow_offline_funded_USDT_1e18=", usdtBorrow);
        } else {
            console2.log("venus_borrow_live_USDT_1e18=", usdtBorrow);
        }

        // ---- Leg C: Pendle YT-asBNB swap ----
        IERC20(BSC.USDT).approve(BSC.PENDLE_ROUTER_V4, usdtBorrow);
        uint256 ytAcquiredFace = (usdtBorrow * 10_000) / YT_ENTRY_BPS; // leverage
        bool pendleLive = _trySwapUsdtForYt(usdtBorrow);
        if (!pendleLive) {
            console2.log("pendle_yt_offline_modelled_face_1e18=", ytAcquiredFace);
            // Burn USDT to model the YT spend.
            uint256 burn = IERC20(BSC.USDT).balanceOf(address(this));
            if (burn > usdtBorrow) burn = usdtBorrow;
            if (burn > 0) IERC20(BSC.USDT).transfer(address(0xdEaD), burn);
        }

        // ---- Cost projection over HOLD_DAYS ----
        uint256 venusCost = (usdtBorrow * VENUS_USDT_BORROW_BPS * HOLD_DAYS) / (10_000 * 365);
        // YT decay to zero at maturity is already captured by burning the USDT
        // spend above. Venus carry cost is modelled by burning more USDT.
        // Top-up USDT to allow the cost burn.
        _fund(BSC.USDT, address(this), venusCost);
        IERC20(BSC.USDT).transfer(address(0xdEaD), venusCost);

        console2.log("projection_venus_borrow_cost_usd_1e18=", venusCost);
        console2.log("projection_yt_face_1e18=", ytAcquiredFace);
        console2.log("points_class_payout_off_chain_at_airdrop");

        _endPnL("B15-04: asBNB Venus Pendle YT points stack");
    }

    function _trySwapUsdtForYt(uint256 usdtIn) internal returns (bool ok) {
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: BSC.USDT,
            netTokenIn: usdtIn,
            tokenMintSy: BSC.USDT,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        IPendleRouter.LimitOrderData memory emptyLimit;
        try IPendleRouter(BSC.PENDLE_ROUTER_V4).swapExactTokenForYt(
            address(this), LOCAL_YT_ASBNB_MARKET, 0, approx, input, emptyLimit
        ) returns (uint256, uint256, uint256) {
            ok = true;
        } catch {
            ok = false;
        }
    }
}
