// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IListaInteraction} from "src/interfaces/bsc/cdp/IListaInteraction.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IPPrincipalToken} from "src/interfaces/pendle/IPPrincipalToken.sol";
import {IPYieldToken} from "src/interfaces/pendle/IPYieldToken.sol";
import {IStandardizedYield} from "src/interfaces/pendle/IStandardizedYield.sol";
import {IPancakeV3Router} from "src/interfaces/bsc/amm/IPancakeV3Router.sol";
import {console2} from "forge-std/console2.sol";

/// @title B04-06 - PT-USDe BSC + Lista CDP recursive loop (3-mechanism)
///
/// @notice Buy PT-USDe (or PT-sUSDe) on Pendle BSC, deposit it as collateral
///         into Lista's CDP module, mint lisUSD against it, swap lisUSD -> USDC
///         via PCS v3, and recycle into a second PT-USDe lot. Two iterations
///         of this loop give ~1.5x effective PT exposure while keeping the
///         lisUSD debt non-volatile (USD-denominated).
///
/// @dev    3-mechanism: Pendle + Lista CDP + PCS v3 swap leg. Offline-safe.
contract B04_06_PtUsdeListaCdpRecursiveTest is BSCStrategyBase {
    // ---- Pinned block ----
    uint256 constant FORK_BLOCK = 42_000_000;

    // ---- Pendle market ----
    /// @notice PT-sUSDe-26JUN2025 on BSC (same as B04-01). TODO verify.
    address constant LOCAL_PT_SUSDE_BSC_MARKET = 0x9eC4c502D989F04FfA9312C9D6E3F872EC91A0F9;
    uint256 constant ASSUMED_EXPIRY = 1_750_896_000;

    // ---- Equity & loop config ----
    uint256 constant EQUITY_USDC = 500_000e18;
    /// @dev Conservative LTV - Lista's PT-class collateral typically 50-65%.
    uint256 constant TARGET_LTV_BPS = 5_500; // 55 %
    uint8 constant LOOP_ITERS = 2;

    // ---- Discovered at setUp ----
    address internal _sy;
    address internal _pt;
    address internal _yt;
    uint256 internal _expiry;
    bool internal _marketLive;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
        } catch {
            console2.log("BSC_RPC_URL not set; B04-06 runs as no-op");
            return;
        }

        try IPendleMarket(LOCAL_PT_SUSDE_BSC_MARKET).readTokens() returns (
            address sy_, address pt_, address yt_
        ) {
            _sy = sy_;
            _pt = pt_;
            _yt = yt_;
            try IPendleMarket(LOCAL_PT_SUSDE_BSC_MARKET).expiry() returns (uint256 e_) {
                _expiry = e_;
            } catch {
                _expiry = ASSUMED_EXPIRY;
            }
            _marketLive = true;
        } catch {
            _expiry = ASSUMED_EXPIRY;
            _marketLive = false;
        }

        _trackToken(BSC.USDC);
        _trackToken(BSC.USDT);
        _trackToken(BSC.USDe);
        _trackToken(BSC.sUSDe);
        _trackToken(BSC.lisUSD);
        if (_sy != address(0)) _trackToken(_sy);
        if (_pt != address(0)) _trackToken(_pt);
    }

    function testStrategy_B04_06() public {
        if (!_marketLive) {
            console2.log("PT-sUSDe BSC market not resolvable; logging no-op");
            return;
        }

        _fund(BSC.USDC, address(this), EQUITY_USDC);
        _startPnL();

        IERC20(BSC.USDC).approve(BSC.PENDLE_ROUTER_V4, type(uint256).max);
        uint256 totalPt;
        uint256 cycleUsdc = EQUITY_USDC;

        for (uint8 i = 0; i < LOOP_ITERS; i++) {
            // ---- 1. Swap USDC -> PT ----
            uint256 ptOut = _swapUsdcForPt(cycleUsdc);
            if (ptOut == 0) {
                console2.log("Pendle BSC swap rejected at iter", i);
                break;
            }
            totalPt += ptOut;
            console2.log("iter_pt_received_1e18=", ptOut);

            // ---- 2. Deposit PT into Lista CDP, mint lisUSD ----
            IERC20(_pt).approve(BSC.LISTA_INTERACTION, ptOut);
            bool depositOK = false;
            try IListaInteraction(BSC.LISTA_INTERACTION).deposit(address(this), _pt, ptOut) {
                depositOK = true;
                console2.log("lista deposit OK");
            } catch {
                console2.log("Lista deposit reverted (PT collateral not whitelisted?)");
            }
            if (!depositOK) break;

            // Mint lisUSD at target LTV.
            uint256 mintAmt = (ptOut * TARGET_LTV_BPS) / 10_000;
            uint256 lisBefore = IERC20(BSC.lisUSD).balanceOf(address(this));
            try IListaInteraction(BSC.LISTA_INTERACTION).borrow(_pt, mintAmt) {
                console2.log("lista borrow OK; lisUSD minted");
            } catch {
                console2.log("Lista borrow reverted");
                break;
            }
            uint256 lisMinted = IERC20(BSC.lisUSD).balanceOf(address(this)) - lisBefore;
            if (lisMinted == 0) break;

            // ---- 3. Swap lisUSD -> USDC on PCS v3 ----
            cycleUsdc = _swapLisUsdForUsdc(lisMinted);
            if (cycleUsdc == 0) {
                console2.log("lisUSD->USDC swap failed; loop terminates");
                break;
            }
        }

        console2.log("total_pt_accumulated_1e18=", totalPt);

        // ---- 4. Warp past maturity ----
        require(_expiry > block.timestamp, "already expired");
        uint256 secsToWarp = _expiry - block.timestamp + 1 hours;
        vm.warp(_expiry + 1 hours);
        vm.roll(block.number + (secsToWarp / 3 + 1));

        // ---- 5. Unwind: repay lisUSD, withdraw PT, redeem ----
        // (Repay leg is mostly informational; in production the loop would
        //  unwind iteratively. PoC unwinds in one shot via best-effort.)
        uint256 lisDebt = _borrowedSafe();
        if (lisDebt > 0) {
            // Need lisUSD to repay; if we don't have enough, this will fail.
            IERC20(BSC.lisUSD).approve(BSC.LISTA_INTERACTION, type(uint256).max);
            try IListaInteraction(BSC.LISTA_INTERACTION).payback(_pt, lisDebt) {
                console2.log("lista payback OK");
            } catch {
                console2.log("lista payback failed (insufficient lisUSD)");
            }
        }

        // Try to withdraw all PT.
        uint256 locked = _lockedSafe();
        if (locked > 0) {
            try IListaInteraction(BSC.LISTA_INTERACTION).withdraw(address(this), _pt, locked) {
                console2.log("lista withdraw OK; pt_recovered=", locked);
            } catch {
                console2.log("lista withdraw failed");
            }
        }

        uint256 ptHeld = IERC20(_pt).balanceOf(address(this));
        if (ptHeld > 0) {
            IERC20(_pt).approve(BSC.PENDLE_ROUTER_V4, ptHeld);
            IPendleRouter.SwapData memory emptySwap;
            IPendleRouter.TokenOutput memory output = IPendleRouter.TokenOutput({
                tokenOut: BSC.USDC,
                minTokenOut: 0,
                tokenRedeemSy: BSC.USDC,
                pendleSwap: address(0),
                swapData: emptySwap
            });
            try IPendleRouter(BSC.PENDLE_ROUTER_V4).redeemPyToToken(
                address(this), _yt, ptHeld, output
            ) returns (uint256 netTokenOut, uint256) {
                console2.log("redeemed_usdc_via_router_1e18=", netTokenOut);
            } catch {
                _fallbackRedeem(ptHeld);
            }
        }

        console2.log("final_usdc_1e18=", IERC20(BSC.USDC).balanceOf(address(this)));
        console2.log("equity_usdc_1e18=", EQUITY_USDC);

        _endPnL("B04-06: PT-USDe Lista CDP recursive (Pendle+Lista+PCS)");
    }

    // ---- Helpers ----

    function _swapUsdcForPt(uint256 usdcIn) internal returns (uint256 netPtOut) {
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: BSC.USDC,
            netTokenIn: usdcIn,
            tokenMintSy: BSC.USDC,
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

    function _swapLisUsdForUsdc(uint256 lisIn) internal returns (uint256 usdcOut) {
        IERC20(BSC.lisUSD).approve(BSC.PCS_V3_ROUTER, lisIn);
        IPancakeV3Router.ExactInputSingleParams memory params = IPancakeV3Router.ExactInputSingleParams({
            tokenIn: BSC.lisUSD,
            tokenOut: BSC.USDC,
            fee: 500, // 5 bp pool first; PCS lists both
            recipient: address(this),
            deadline: block.timestamp + 1 hours,
            amountIn: lisIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        try IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(params) returns (uint256 out) {
            usdcOut = out;
        } catch {
            // Try 100bp tier
            params.fee = 100;
            try IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(params) returns (uint256 out2) {
                usdcOut = out2;
            } catch {
                usdcOut = 0;
            }
        }
    }

    function _borrowedSafe() internal view returns (uint256) {
        try IListaInteraction(BSC.LISTA_INTERACTION).borrowed(_pt, address(this)) returns (uint256 b) {
            return b;
        } catch {
            return 0;
        }
    }

    function _lockedSafe() internal view returns (uint256) {
        try IListaInteraction(BSC.LISTA_INTERACTION).locked(_pt, address(this)) returns (uint256 l) {
            return l;
        } catch {
            return 0;
        }
    }

    function _fallbackRedeem(uint256 ptAmount) internal {
        IERC20(_pt).transfer(_yt, ptAmount);
        try IPYieldToken(_yt).redeemPY(address(this)) returns (uint256 syOut) {
            try IStandardizedYield(_sy).redeem(address(this), syOut, BSC.USDC, 0, false)
                returns (uint256 usdcOut)
            {
                console2.log("redeemed_usdc_via_sy_1e18=", usdcOut);
            } catch {
                console2.log("SY.redeem(USDC) failed");
            }
        } catch {
            console2.log("YT.redeemPY failed");
        }
    }
}
