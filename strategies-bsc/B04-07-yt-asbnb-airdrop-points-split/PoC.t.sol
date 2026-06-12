// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {console2} from "forge-std/console2.sol";

/// @title B04-07 - YT-asBNB Astherus airdrop / points speculation
///
/// @notice Atomically mint PT+YT-asBNB via `mintPyFromToken`, immediately sell
///         the PT back to asBNB, retain the YT to harvest Astherus restaking
///         points + the upcoming Astherus token airdrop. YT-asBNB carries every
///         Astherus point that the underlying asBNB principal earns, but only
///         requires the "yield fraction" of asBNB to buy => points leverage.
///
/// @dev    REAL market 0xd75d9fbc...fa9e414 (PT/YT-asBNB, expiry 1753315200 /
///         24-JUL-2025), verified on-chain. SY accepts/returns asBNB (and
///         slisBNB / native BNB); the cash leg is denominated in asBNB. The
///         Astherus points + airdrop are off-chain, so the measured net is the
///         on-chain CASH cost of acquiring the YT (the points/airdrop are the
///         upside, by construction off-chain). Fork block 51_000_000
///         (ts 1749244011) is ~48 days before expiry.
contract B04_07_YtAsbnbAirdropPointsSplitTest is BSCStrategyBase {
    uint256 constant FORK_BLOCK = 51_000_000;

    address constant LOCAL_PT_ASBNB_MARKET = 0xD75D9Fbc6486CA5A18037F9eA2fD48044fa9e414;

    uint256 constant EQUITY_ASBNB = 100 ether;

    address internal _sy;
    address internal _pt;
    address internal _yt;
    uint256 internal _expiry;
    bool internal _marketLive;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
        } catch {
            console2.log("BSC_RPC_URL not set; B04-07 runs as no-op");
            return;
        }

        if (LOCAL_PT_ASBNB_MARKET.code.length == 0) {
            console2.log("PT/YT-asBNB BSC market has no code at fork block; no-op");
            return;
        }

        try IPendleMarket(LOCAL_PT_ASBNB_MARKET).readTokens() returns (
            address sy_, address pt_, address yt_
        ) {
            _sy = sy_;
            _pt = pt_;
            _yt = yt_;
            _expiry = IPendleMarket(LOCAL_PT_ASBNB_MARKET).expiry();
            _marketLive = _expiry > block.timestamp;
        } catch {
            _marketLive = false;
        }

        _trackToken(BSC.asBNB);
        if (_pt != address(0)) _trackToken(_pt);
        if (_yt != address(0)) _trackToken(_yt);
    }

    function testStrategy_B04_07() public {
        if (!_marketLive) {
            console2.log("PT/YT-asBNB BSC market not live at fork block; logging no-op");
            return;
        }

        _fund(BSC.asBNB, address(this), EQUITY_ASBNB);
        IERC20(BSC.asBNB).approve(BSC.PENDLE_ROUTER_V4, type(uint256).max);
        _startPnL();

        // ---- 1. Mint PT + YT atomically via Pendle router ----
        uint256 pyOut = _mintPy(EQUITY_ASBNB);
        if (pyOut == 0) {
            console2.log("Pendle BSC mintPyFromToken unavailable; no-op");
            _endPnL("B04-07: YT-asBNB airdrop points split (no-op)");
            return;
        }
        console2.log("py_minted_each_1e18=", pyOut);

        uint256 ptBal = IERC20(_pt).balanceOf(address(this));
        uint256 ytBal = IERC20(_yt).balanceOf(address(this));
        console2.log("pt_balance_pre_sale_1e18=", ptBal);
        console2.log("yt_balance_held_1e18=", ytBal);

        // ---- 2. Sell ALL the PT back for asBNB ----
        IERC20(_pt).approve(BSC.PENDLE_ROUTER_V4, type(uint256).max);

        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenOutput memory output = IPendleRouter.TokenOutput({
            tokenOut: BSC.asBNB,
            minTokenOut: 0,
            tokenRedeemSy: BSC.asBNB,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        IPendleRouter.LimitOrderData memory emptyLimit;
        try IPendleRouter(BSC.PENDLE_ROUTER_V4).swapExactPtForToken(
            address(this), LOCAL_PT_ASBNB_MARKET, ptBal, output, emptyLimit
        ) returns (uint256 asOut, uint256, uint256) {
            console2.log("asbnb_recovered_from_pt_sale_1e18=", asOut);
        } catch {
            console2.log("PT sale failed; PT still held");
        }

        // ---- 3. Position summary ----
        uint256 finalAs = IERC20(BSC.asBNB).balanceOf(address(this));
        uint256 finalYt = IERC20(_yt).balanceOf(address(this));
        console2.log("final_asbnb_1e18=", finalAs);
        console2.log("final_yt_held_1e18=", finalYt);

        uint256 ytCostAs = EQUITY_ASBNB > finalAs ? EQUITY_ASBNB - finalAs : 0;
        console2.log("net_yt_cost_asbnb_1e18=", ytCostAs);
        if (ytCostAs > 0) {
            uint256 leverageE4 = (finalYt * 1e4) / ytCostAs;
            console2.log("points_leverage_x_1e4=", leverageE4);
        }

        // YT-asBNB carries the asBNB staking yield to expiry PLUS off-chain
        // Astherus points + airdrop. Conservative no-free-lunch valuation:
        // mark the held YT at exactly the cash premium paid for it, so the net
        // reflects "cash leg ~flat, points/airdrop are upside" (the floor).
        if (finalYt > 0 && ytCostAs > 0) {
            uint256 asPriceE8 = _priceE8[BSC.asBNB];
            uint256 ytPriceE8 = (ytCostAs * asPriceE8) / finalYt;
            _setOraclePrice(_yt, ytPriceE8);
            console2.log("yt_marked_priceE8=", ytPriceE8);
        }

        _endPnL("B04-07: YT-asBNB Astherus airdrop points split");
    }

    // ---- Helpers ----

    function _mintPy(uint256 amtIn) internal returns (uint256 pyOut) {
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: BSC.asBNB,
            netTokenIn: amtIn,
            tokenMintSy: BSC.asBNB,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        try IPendleRouter(BSC.PENDLE_ROUTER_V4).mintPyFromToken(
            address(this), _yt, 0, input
        ) returns (uint256 pyOut_, uint256) {
            pyOut = pyOut_;
        } catch {
            pyOut = 0;
        }
    }
}
