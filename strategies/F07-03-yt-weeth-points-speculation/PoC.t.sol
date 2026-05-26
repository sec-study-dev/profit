// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IPYieldToken} from "src/interfaces/pendle/IPYieldToken.sol";

/// @title F07-03 — YT-weETH point speculation
///
/// @notice Buys YT-weETH-26DEC2024 with WETH equity. YT carries the underlying
///         eETH staking yield AND streams EtherFi + EigenLayer points to the
///         holder until maturity. Decays to zero at maturity; upside is the
///         post-TGE $/point realisation.
contract F07_03_YtWeethPointsSpecTest is StrategyBase {
    // ---- Block ----
    /// @dev Mid-Aug 2024. ~4.5 months remaining to maturity; YT cheap, points
    ///      accrual rate not yet diluted by Pendle multiplier sunset.
    uint256 constant FORK_BLOCK = 20_650_000;

    // ---- Pendle market (PT/YT-weETH-26DEC2024) ----
    address constant LOCAL_MARKET = 0x7d372819240D14fB477f17b964f95F33BeB4c704;

    // ---- Equity ----
    uint256 constant EQUITY_WETH = 100 ether;

    // ---- State ----
    address internal _sy;
    address internal _pt;
    address internal _yt;

    function setUp() public {
        _fork(FORK_BLOCK);
        (_sy, _pt, _yt) = IPendleMarket(LOCAL_MARKET).readTokens();

        _trackToken(Mainnet.WETH);
        _trackToken(_sy);
        _trackToken(_pt);
        _trackToken(_yt);
        _trackToken(Mainnet.WEETH);
    }

    function testStrategy_F07_03() public {
        _fund(Mainnet.WETH, address(this), EQUITY_WETH);
        _startPnL();

        IERC20(Mainnet.WETH).approve(Mainnet.PENDLE_ROUTER_V4, type(uint256).max);

        // ---- 1. Buy YT-weETH with all WETH ----
        uint256 ytOut = _swapWethForYt(EQUITY_WETH, 0);
        emit log_named_uint("yt_received_1e18", ytOut);
        emit log_named_uint("implied_notional_weETH_1e18", ytOut); // 1:1 YT:SY notional units

        // ---- 2. Time travel near maturity (5 months later, last block before expiry) ----
        // Simulate accrued interest path. EtherFi/EigenLayer points are off-chain
        // so the on-chain PnL only captures the implied-yield component delivered
        // through the SY exchange rate; the points value is computed in README.
        vm.warp(block.timestamp + 150 days);
        vm.roll(block.number + (150 days / 12));

        // ---- 3. Crystallise accrued interest + on-chain reward tokens ----
        // Pendle's YT contract streams the SY-side interest as redeemable SY
        // shares; reward tokens (if any are on-chain ERC20 rewards) come out as
        // a separate array.
        try IPYieldToken(_yt).redeemDueInterestAndRewards(address(this), true, true) returns (
            uint256 interestOut, uint256[] memory
        ) {
            emit log_named_uint("accrued_interest_sy_1e18", interestOut);
        } catch {
            // Some YT variants gate the call to non-expired only; ignore here.
        }

        // ---- 4. Report ----
        // The on-chain net is: SY interest accrual + (whatever YT spot is worth
        // pre-expiry, if any). The off-chain points value is asserted in README
        // PnL math (explicit assumption: $0.001/EF-point, $0.005/EL-point).
        emit log_named_uint("sy_balance_post_accrual_1e18", IERC20(_sy).balanceOf(address(this)));
        emit log_named_uint("yt_balance_post_accrual_1e18", IERC20(_yt).balanceOf(address(this)));

        _endPnL("F07-03: YT-weETH point speculation");
    }

    // ---- Helpers ----

    function _swapWethForYt(uint256 wethIn, uint256 minYtOut) internal returns (uint256 netYtOut) {
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: Mainnet.WETH,
            netTokenIn: wethIn,
            tokenMintSy: Mainnet.WETH,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        IPendleRouter.LimitOrderData memory emptyLimit;

        (netYtOut, , ) = IPendleRouter(Mainnet.PENDLE_ROUTER_V4).swapExactTokenForYt(
            address(this), LOCAL_MARKET, minYtOut, approx, input, emptyLimit
        );
    }
}
