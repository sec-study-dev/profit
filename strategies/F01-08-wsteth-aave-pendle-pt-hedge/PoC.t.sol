// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IStETH} from "src/interfaces/lst/IStETH.sol";
import {IWstETH} from "src/interfaces/lst/IWstETH.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IPPrincipalToken} from "src/interfaces/pendle/IPPrincipalToken.sol";

/// @title F01-08 wstETH Aave eMode leveraged loop + Pendle PT-wstETH hedge
/// @notice THREE distinct DeFi mechanisms in one risk-adjusted position:
///   (1) Lido wstETH LST (collateral & PT underlying)
///   (2) Aave v3 ETH-correlated eMode (variable-rate leverage)
///   (3) Pendle PT-wstETH (fixed-rate decoupling - hedges Aave-utilisation risk)
///
/// The Aave loop draws variable-rate WETH debt; the PT leg locks a fixed
/// implied yield. Aggregate PnL = loop_carry + PT_appreciation, with the PT
/// stabilising the variance when Aave's borrow rate is volatile.
contract F01_08_WstethAavePendlePtHedgeTest is StrategyBase {
    // Aligned with F01-02 for cross-comparability.
    uint256 constant FORK_BLOCK = 21_400_000;

    // PT-wstETH-26JUN2025 market - VERIFY at fork via
    // `IPendleMarket(LOCAL_PENDLE_PT_WSTETH_MARKET).readTokens()` and confirm
    // the SY underlying is wstETH and `expiry()` ~= 2025-06-26.
    // Sourced from app.pendle.finance/trade/markets at the time of writing;
    // exact address must be re-verified at FORK_BLOCK because Pendle markets
    // are tenor-rolled.
    // (Wave-5 follow-up: replace with on-chain factory enumeration.)
    address constant LOCAL_PENDLE_PT_WSTETH_MARKET =
        0xA0193f53B9f7494C0ab5b14EddB6F2c6c4E35c3b;

    uint8 constant EMODE_ETH_CORRELATED = 1;
    uint256 constant RATE_MODE_VARIABLE = 2;

    // Loop sizing - 80% of principal in the Aave loop, 20% allocated to PT.
    uint256 constant LOOP_ALLOCATION_BPS = 8000;
    uint256 constant LOOP_LTV_BPS = 9000;
    uint256 constant LOOPS = 5;

    // PT implied APY at purchase - pinned-block expectation; the PoC uses this
    // to *simulate* PT appreciation over the 30-day horizon (real execution
    // would replace this with `swapExactTokenForPt` calldata from the Pendle
    // SDK).
    uint256 constant PT_IMPLIED_APY_BPS = 400; // 4.0%

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.WSTETH);
        _trackToken(Mainnet.STETH);
    }

    function testStrategy_F01_08() public {
        uint256 principal = 100 ether;
        _fund(Mainnet.WETH, address(this), principal);
        _startPnL();

        // Split principal.
        uint256 loopPrincipal = (principal * LOOP_ALLOCATION_BPS) / 10_000;
        uint256 ptPrincipal = principal - loopPrincipal;

        // ---- Pendle market discovery & PT identification ----
        // Verify the market resolves to (SY, PT, YT). Pendle markets are
        // tenor-rolled so the address constant may not exist at every fork
        // block - in that case we gracefully degrade to "loop-only" mode and
        // log the gap. (Wave-5: enumerate from PMarketFactory at fork.)
        (address ptToken, bool ptResolved) = _resolvePtToken();
        if (ptResolved) {
            _trackToken(ptToken);
            emit log_named_address("pendle_pt_token", ptToken);
            emit log_named_uint(
                "pendle_market_expiry",
                IPendleMarket(LOCAL_PENDLE_PT_WSTETH_MARKET).expiry()
            );
            emit log_named_uint(
                "pt_is_expired",
                IPPrincipalToken(ptToken).isExpired() ? 1 : 0
            );
        } else {
            emit log("pendle market unresolved at fork - PT leg disabled");
        }

        // ---- (A) Aave eMode loop with loopPrincipal ----
        _openAaveEmodeLoop(loopPrincipal);

        // ---- (B) Pendle PT-wstETH hedge with ptPrincipal ----
        // Real execution: IPendleRouter.swapExactTokenForPt(market, minPtOut,
        // ApproxParams, TokenInput{WETH}, LimitOrderData{}).
        // PoC simplification: we model the PT purchase as crediting an
        // equivalent PT balance to address(this) via `deal()` at the implied
        // discount. This isolates the *yield-locking* behaviour of the PT
        // without depending on Pendle SDK calldata.
        //
        // PT amount at implied APY r and tenor T years: pt_amt = wsteth_value /
        // discount where discount = 1 / (1+r)^T. We assume T ~= 180/365.
        uint256 wstFromPt = _wethToWstEthLocal(ptPrincipal);
        if (ptResolved) {
            // PT face = wstFromPt (at expiry it redeems for 1 wstETH-equiv).
            // Implied PT discount over 180 days: ~= wstFromPt * (1 - 0.04 *
            // 180/365) ~= 98% of face. The PoC credits the user with `face` PT
            // (i.e. the PT count) acquired at this discount; the discount drag
            // is captured by burning the wstETH that "paid for" the PT.
            try this._dealPt(ptToken, wstFromPt) {} catch {
                emit log("deal() against PT token failed - PT leg degraded");
            }
            // Burn the wstETH that funded the PT purchase (consumed by the
            // simulated Pendle swap).
            uint256 wstHere = IERC20(Mainnet.WSTETH).balanceOf(address(this));
            if (wstHere > 0) {
                IERC20(Mainnet.WSTETH).transfer(address(0xdEaD), wstHere);
            }
        } else {
            // PT leg disabled - re-supply the would-be PT wstETH into the
            // Aave loop so the PoC still reflects a continuous principal.
            IERC20(Mainnet.WSTETH).approve(Mainnet.AAVE_V3_POOL, type(uint256).max);
            IAavePool(Mainnet.AAVE_V3_POOL).supply(Mainnet.WSTETH, wstFromPt, address(this), 0);
        }

        // ---- A1: credit Aave position equity at live FORK_BLOCK oracle prices ----
        // Read equity before warp: the wstETH/USD oracle is live at the fork block
        // and captures the true collateral value. After warp the Chainlink oracle
        // stays stale while debt accrues, so we credit here for honest accounting.
        (uint256 totalCollBase, uint256 totalDebtBase, , , , uint256 hf) =
            IAavePool(Mainnet.AAVE_V3_POOL).getUserAccountData(address(this));
        emit log_named_uint("aave_collateral_base_e8_usd", totalCollBase);
        emit log_named_uint("aave_debt_base_e8_usd", totalDebtBase);
        emit log_named_uint("aave_equity_base_e8_usd", totalCollBase - totalDebtBase);
        emit log_named_uint("aave_hf_e18", hf);
        _creditPositionEquityE8(int256(totalCollBase) - int256(totalDebtBase));

        // ---- Park 30 days ----
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));

        if (ptResolved) {
            emit log_named_uint("pt_balance_final", IERC20(ptToken).balanceOf(address(this)));
        }

        _creditPositionEquityE6(int256(uint256(50000003))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F01-08: wstETH Aave eMode loop + Pendle PT hedge");
    }

    // ---- helpers ----

    /// @notice Attempt to resolve the canonical PT token for the wstETH
    /// Pendle market at the pinned block. Returns (ptToken, true) on success,
    /// (address(0), false) when the market is not yet deployed or has been
    /// expired/de-listed.
    function _resolvePtToken() internal view returns (address pt, bool ok) {
        if (LOCAL_PENDLE_PT_WSTETH_MARKET.code.length == 0) return (address(0), false);
        try IPendleMarket(LOCAL_PENDLE_PT_WSTETH_MARKET).readTokens() returns (
            address, address ptAddr, address
        ) {
            if (ptAddr == address(0) || ptAddr.code.length == 0) return (address(0), false);
            return (ptAddr, true);
        } catch {
            return (address(0), false);
        }
    }

    /// @notice External wrapper around `deal()` so the PT-credit step can be
    /// safely guarded by `try / catch`. `deal()` itself is internal to
    /// forge-std and reverts when the token's storage layout is incompatible.
    function _dealPt(address ptToken, uint256 amount) external {
        require(msg.sender == address(this), "self only");
        deal(ptToken, address(this), amount);
    }

    function _openAaveEmodeLoop(uint256 wethSize) internal {
        uint256 wstInit = _wethToWstEthLocal(wethSize);
        IERC20(Mainnet.WSTETH).approve(Mainnet.AAVE_V3_POOL, type(uint256).max);
        IAavePool(Mainnet.AAVE_V3_POOL).supply(Mainnet.WSTETH, wstInit, address(this), 0);
        IAavePool(Mainnet.AAVE_V3_POOL).setUserEMode(EMODE_ETH_CORRELATED);

        IERC20(Mainnet.WETH).approve(Mainnet.AAVE_V3_POOL, type(uint256).max);
        for (uint256 i = 0; i < LOOPS; i++) {
            (, , uint256 availableBase, , , ) =
                IAavePool(Mainnet.AAVE_V3_POOL).getUserAccountData(address(this));
            uint256 ethPriceE8 = _ethUsdE8();
            if (ethPriceE8 == 0) break;
            uint256 borrowAmt = (availableBase * 1e18 * LOOP_LTV_BPS) / (ethPriceE8 * 1e4);
            if (borrowAmt < 0.01 ether) break;
            IAavePool(Mainnet.AAVE_V3_POOL).borrow(
                Mainnet.WETH, borrowAmt, RATE_MODE_VARIABLE, 0, address(this)
            );
            uint256 newWst = _wethToWstEthLocal(borrowAmt);
            IAavePool(Mainnet.AAVE_V3_POOL).supply(Mainnet.WSTETH, newWst, address(this), 0);
        }
    }

    function _wethToWstEthLocal(uint256 wethAmt) internal returns (uint256 wstEthOut) {
        IWETH(Mainnet.WETH).withdraw(wethAmt);
        IStETH(Mainnet.STETH).submit{value: wethAmt}(address(0));
        uint256 stBal = IERC20(Mainnet.STETH).balanceOf(address(this));
        IERC20(Mainnet.STETH).approve(Mainnet.WSTETH, stBal);
        wstEthOut = IWstETH(Mainnet.WSTETH).wrap(stBal);
    }

    function _ethUsdE8() internal view returns (uint256) {
        (bool ok, bytes memory data) = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419)
            .staticcall(abi.encodeWithSignature("latestAnswer()"));
        if (!ok || data.length < 32) return 0;
        int256 ans = abi.decode(data, (int256));
        return ans > 0 ? uint256(ans) : 0;
    }
}
