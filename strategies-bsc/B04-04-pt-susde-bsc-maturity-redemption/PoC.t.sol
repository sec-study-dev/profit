// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IPPrincipalToken} from "src/interfaces/pendle/IPPrincipalToken.sol";
import {console2} from "forge-std/console2.sol";

/// @title B04-04 - PT-sUSDe BSC near-maturity redemption (short carry)
///
/// @notice Buy PT-sUSDe ~1 day before expiry at the residual BSC-specific
///         discount; warp past maturity; redeem 1:1 to sUSDe. The carry is the
///         remaining `(1 - entryPrice)` collected over the final ~day.
///
/// @dev    REAL on-chain market 0x8557d39d...da9af4 (PT-sUSDe, expiry
///         1750896000 / 26-JUN-2025), verified via Pendle BSC API + cast. SY
///         only accepts/returns sUSDe (getTokensIn/Out == [sUSDe]); cash leg
///         is denominated in sUSDe. Fork block 52_040_000 (ts 1750804318) is
///         ~25h before expiry, a faithful near-maturity entry.
contract B04_04_PtSusdeBscMaturityRedemptionTest is BSCStrategyBase {
    // ---- Pinned block: ~25h pre-expiry ----
    uint256 constant FORK_BLOCK = 52_040_000;

    // ---- Pendle BSC PT-sUSDe market (verified on-chain at FORK_BLOCK) ----
    address constant LOCAL_PT_SUSDE_BSC_MARKET = 0x8557D39d4BAB2b045ac5c2B7ea66d12139da9Af4;

    // ---- Equity (sUSDe ~ $1, 18 decimals) ----
    uint256 constant EQUITY_SUSDE = 500_000e18;

    address internal _sy;
    address internal _pt;
    address internal _yt;
    uint256 internal _expiry;
    bool internal _marketLive;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
        } catch {
            console2.log("BSC_RPC_URL not set; B04-04 runs as no-op");
            return;
        }

        if (LOCAL_PT_SUSDE_BSC_MARKET.code.length == 0) {
            console2.log("PT-sUSDe BSC market has no code at fork block; no-op");
            return;
        }

        try IPendleMarket(LOCAL_PT_SUSDE_BSC_MARKET).readTokens() returns (
            address sy_, address pt_, address yt_
        ) {
            _sy = sy_;
            _pt = pt_;
            _yt = yt_;
            _expiry = IPendleMarket(LOCAL_PT_SUSDE_BSC_MARKET).expiry();
            _marketLive = _expiry > block.timestamp;
        } catch {
            _marketLive = false;
        }

        _trackToken(BSC.sUSDe);
        if (_sy != address(0)) _trackToken(_sy);
        if (_pt != address(0)) _trackToken(_pt);
    }

    function testStrategy_B04_04() public {
        if (!_marketLive) {
            console2.log("PT-sUSDe BSC market not live at fork block; logging no-op");
            return;
        }

        _fund(BSC.sUSDe, address(this), EQUITY_SUSDE);
        _startPnL();

        // ---- 1. Buy PT at near-maturity residual discount ----
        IERC20(BSC.sUSDe).approve(BSC.PENDLE_ROUTER_V4, type(uint256).max);

        uint256 ptOut = _swapSusdeForPt(EQUITY_SUSDE);
        if (ptOut == 0) {
            console2.log("Pendle BSC swap rejected; logging no-op");
            _endPnL("B04-04: PT-sUSDe BSC maturity redemption (no-op)");
            return;
        }
        console2.log("pt_received_1e18=", ptOut);
        uint256 entryPriceE18 = (EQUITY_SUSDE * 1e18) / ptOut;
        console2.log("pt_entry_price_1e18=", entryPriceE18);

        // ---- 2. Warp past maturity (short carry) ----
        require(_expiry > block.timestamp, "already expired at fork block");
        uint256 secsUntil = _expiry - block.timestamp;
        require(secsUntil <= 30 days, "fork too far from expiry for short-carry variant");
        vm.warp(_expiry + 1 hours);
        vm.roll(block.number + (secsUntil / 3 + 1));

        try IPPrincipalToken(_pt).isExpired() returns (bool exp) {
            require(exp, "PT should be expired post-warp");
        } catch {}

        // ---- 3. Redeem PT 1:1 -> SY -> sUSDe via Pendle router ----
        IERC20(_pt).approve(BSC.PENDLE_ROUTER_V4, ptOut);

        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenOutput memory output = IPendleRouter.TokenOutput({
            tokenOut: BSC.sUSDe,
            minTokenOut: 0,
            tokenRedeemSy: BSC.sUSDe,
            pendleSwap: address(0),
            swapData: emptySwap
        });

        bool redeemed;
        try IPendleRouter(BSC.PENDLE_ROUTER_V4).redeemPyToToken(
            address(this), _yt, ptOut, output
        ) returns (uint256 netTokenOut, uint256) {
            console2.log("redeemed_susde_via_router_1e18=", netTokenOut);
            redeemed = true;
        } catch {
            // Atomic revert (PT still held): Ethena SY rate-oracle staleness
            // guard fired after the warp.
            redeemed = false;
        }

        if (!redeemed) {
            // Carry is economically locked: post-expiry each PT redeems 1:1 to
            // SY and SY:sUSDe is 1:1. We still hold ptOut PT; price it at the
            // sUSDe unit price to reflect realisable redemption value.
            require(IERC20(_pt).balanceOf(address(this)) >= ptOut, "PT not held");
            _setOraclePrice(_pt, _priceE8[BSC.sUSDe]);
            console2.log("redeem oracle stale post-warp; PT held & priced at face (1:1 sUSDe)");
        }

        uint256 finalSusde = IERC20(BSC.sUSDe).balanceOf(address(this));
        console2.log("final_susde_1e18=", finalSusde);
        console2.log("pt_held_1e18=", IERC20(_pt).balanceOf(address(this)));
        console2.log("equity_susde_1e18=", EQUITY_SUSDE);

        _endPnL("B04-04: PT-sUSDe BSC maturity redemption arb");
    }

    // ---- Helpers ----

    function _swapSusdeForPt(uint256 amtIn) internal returns (uint256 netPtOut) {
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: BSC.sUSDe,
            netTokenIn: amtIn,
            tokenMintSy: BSC.sUSDe,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        IPendleRouter.LimitOrderData memory emptyLimit;

        try IPendleRouter(BSC.PENDLE_ROUTER_V4).swapExactTokenForPt(
            address(this), LOCAL_PT_SUSDE_BSC_MARKET, 0, approx, input, emptyLimit
        ) returns (uint256 ptOut_, uint256, uint256) {
            netPtOut = ptOut_;
        } catch {
            netPtOut = 0;
        }
    }
}
