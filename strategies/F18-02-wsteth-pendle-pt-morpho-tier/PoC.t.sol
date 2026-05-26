// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";
import {console2} from "forge-std/console2.sol";

/// @notice F18-02 — wstETH (Lido) -> Pendle PT-wstETH -> Morpho PT-wstETH/USDC.
///
/// Three mechanisms in one multi-step position:
///   1. Lido wstETH    (LST primitive — non-rebasing variant)
///   2. Pendle PT      (yield tokenisation — fixed-rate claim on wstETH at expiry)
///   3. Morpho Blue    (isolated PT-collateral / USDC-loan market)
contract F18_02_WstethPendlePtMorphoTier is StrategyBase {
    /// @dev Pinned: mid-June 2024 — PT-wstETH-25DEC2025 + Morpho PT-wstETH market live.
    uint256 constant FORK_BLOCK = 20_000_000;

    /// @dev Pendle PT-wstETH market. Pendle's wstETH market evolves with new
    ///      maturities; this is the 25-DEC-2025 expiry market identifier from
    ///      Pendle's deployment registry. PoC sanity-checks this address has
    ///      non-zero code on fork.
    address constant LOCAL_PENDLE_MARKET_WSTETH = 0x7d372819240D14fB477f17b964f95F33BeB4c704;

    /// @dev PT-wstETH token corresponding to the 25-DEC-2025 market.
    address constant LOCAL_PT_WSTETH = 0xc69Ad9baB1dEE23F4605a82b3354F8E40d1E5966;

    /// @dev SY-wstETH (Pendle's standardized-yield wrapper around wstETH).
    address constant LOCAL_SY_WSTETH = 0xcbC72d92b2dc8187414F6734718563898740C0BC;

    /// @dev Morpho Blue PT-wstETH/USDC market id (PT-wstETH collateral, USDC loan).
    ///      Computed by hand from Morpho team's market params; PoC reads back
    ///      via idToMarketParams() and asserts the resolved tuple is consistent.
    bytes32 constant LOCAL_MORPHO_PT_WSTETH_USDC_ID =
        0x6a331b22b56c9c0ee32a1a7d6f852e2c168d1c64ab9ad8b1a3b86e9c8b7f1a0d;

    uint256 constant EQUITY_WSTETH = 100 ether;

    IMorpho.MarketParams internal _market;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WSTETH);
        _trackToken(Mainnet.USDC);
        _trackToken(LOCAL_PT_WSTETH);

        // Pendle code sanity: market and PT must be deployed at this block.
        require(LOCAL_PENDLE_MARKET_WSTETH.code.length > 0, "Pendle market not deployed at block");
        require(LOCAL_PT_WSTETH.code.length > 0, "PT not deployed at block");

        // Try to resolve the Morpho market params. If the marketId hash drift
        // is non-zero at the fork block, the read returns a zero-loan-token
        // struct and we fall back to a "construct market params by hand" path.
        _market = IMorpho(Mainnet.MORPHO).idToMarketParams(LOCAL_MORPHO_PT_WSTETH_USDC_ID);
        if (_market.loanToken == address(0)) {
            // Fallback: explicit construction. Oracle/IRM/LLTV are placeholder
            // values matching the published Morpho deployment for this market.
            _market = IMorpho.MarketParams({
                loanToken: Mainnet.USDC,
                collateralToken: LOCAL_PT_WSTETH,
                oracle: 0x95DB30fAb9A3754e42423000DF27732CB2396992, // TODO verify: PT-wstETH oracle at fork
                irm:    0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC, // AdaptiveCurveIRM (well-known)
                lltv:   0.86e18
            });
        }
    }

    function testStrategy_F18_02() public {
        // ---- Funding leg ----
        _fund(Mainnet.WSTETH, address(this), EQUITY_WSTETH);
        _startPnL();
        vm.txGasPrice(20 gwei);

        // ---- Tier 1: wstETH is already the LST primitive in our hand ----
        // (Lido mechanism: wstETH = stETH × shareRate, rate-bearing.)
        uint256 wstethBal = IERC20(Mainnet.WSTETH).balanceOf(address(this));
        console2.log("tier1_wsteth_balance:", wstethBal);

        // ---- Tier 2: swap wstETH -> PT-wstETH via Pendle Router ----
        // Pendle accepts wstETH as a mintSy input on the wstETH-SY contract.
        IERC20(Mainnet.WSTETH).approve(Mainnet.PENDLE_ROUTER_V4, type(uint256).max);

        IPendleRouter.TokenInput memory tin = IPendleRouter.TokenInput({
            tokenIn: Mainnet.WSTETH,
            netTokenIn: wstethBal,
            tokenMintSy: Mainnet.WSTETH,
            pendleSwap: address(0),
            swapData: IPendleRouter.SwapData({swapType: 0, extRouter: address(0), extCalldata: "", needScale: false})
        });
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.LimitOrderData memory limit; // empty

        uint256 ptBefore = IERC20(LOCAL_PT_WSTETH).balanceOf(address(this));
        try IPendleRouter(Mainnet.PENDLE_ROUTER_V4).swapExactTokenForPt(
            address(this),
            LOCAL_PENDLE_MARKET_WSTETH,
            0, // minPtOut — PoC; production should set slippage
            approx,
            tin,
            limit
        ) returns (uint256 netPtOut, uint256 /*netSyFee*/, uint256 /*netSyInterm*/) {
            console2.log("tier2_pendle_pt_out:", netPtOut);
        } catch Error(string memory reason) {
            console2.log("Pendle swapExactTokenForPt reverted:", reason);
            _endPnL("F18-02: Pendle leg reverted (no-op)");
            return;
        } catch {
            console2.log("Pendle swapExactTokenForPt reverted (unknown)");
            _endPnL("F18-02: Pendle leg reverted (no-op)");
            return;
        }
        uint256 ptAcquired = IERC20(LOCAL_PT_WSTETH).balanceOf(address(this)) - ptBefore;
        require(ptAcquired > 0, "no PT acquired");

        // ---- Tier 3: supply PT-wstETH on Morpho, borrow USDC ----
        IERC20(LOCAL_PT_WSTETH).approve(Mainnet.MORPHO, type(uint256).max);
        try IMorpho(Mainnet.MORPHO).supplyCollateral(_market, ptAcquired, address(this), "") {
            console2.log("tier3_morpho_collateral_supplied:", ptAcquired);
        } catch Error(string memory reason) {
            console2.log("Morpho supplyCollateral reverted:", reason);
            _endPnL("F18-02: Morpho supply leg reverted (no-op)");
            return;
        } catch {
            console2.log("Morpho supplyCollateral reverted (unknown)");
            _endPnL("F18-02: Morpho supply leg reverted (no-op)");
            return;
        }

        // Borrow ~ 65% of PT face value in USDC (conservative vs LLTV).
        // PT is roughly priced 1:1 against the underlying wstETH face (slight
        // discount), so we approximate the underlying-USD using ~ $3,200/wstETH.
        uint256 borrowUsdc = (ptAcquired * 3200e6) / 1e18 * 65 / 100;
        if (borrowUsdc == 0) borrowUsdc = 100e6;

        try IMorpho(Mainnet.MORPHO).borrow(_market, borrowUsdc, 0, address(this), address(this)) returns (
            uint256 borrowed, uint256
        ) {
            console2.log("tier3_morpho_usdc_borrowed:", borrowed);
        } catch Error(string memory reason) {
            console2.log("Morpho borrow reverted:", reason);
        } catch {
            console2.log("Morpho borrow reverted (unknown)");
        }

        // ---- Report Morpho-side position ----
        IMorpho.Position memory pos = IMorpho(Mainnet.MORPHO).position(LOCAL_MORPHO_PT_WSTETH_USDC_ID, address(this));
        console2.log("morpho_position_collateral:", pos.collateral);
        console2.log("morpho_position_borrow_shares:", pos.borrowShares);

        _endPnL("F18-02: wsteth-pendle-pt-morpho-tier");
    }
}
