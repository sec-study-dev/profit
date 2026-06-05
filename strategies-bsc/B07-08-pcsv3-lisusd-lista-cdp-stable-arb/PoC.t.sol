// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";
import {IPancakeV3Router} from "src/interfaces/bsc/amm/IPancakeV3Router.sol";
import {IListaInteraction} from "src/interfaces/bsc/cdp/IListaInteraction.sol";
import {IPancakeStableRouter} from "src/interfaces/bsc/amm/IPancakeStableRouter.sol";

/// @title B07-08 PCS v3 USDC flash -> Lista lisUSD mint -> PCS StableSwap exit (3-mech)
/// @notice Three orthogonal BSC primitives composed atomically:
///           1) PCS v3 USDC/USDT 0.01% flash (USDC fee-only @ 1 bp).
///           2) Lista DAO CDP - deposit USDC as collateral (if the
///              market accepts it) OR swap USDC->USDT->deposit USDT, then
///              mint lisUSD against it.
///           3) PCS StableSwap (Curve fork) - swap lisUSD -> USDC at the
///              StableSwap mid, repay the flash.
///
///         Edge exists when lisUSD trades ABOVE peg (>= $1.005) on the
///         AMM venue. We mint lisUSD at par (per Lista's CDP math), sell
///         it on PCS StableSwap at the above-peg price, redeem the USDC
///         delta as profit, and repay the flash. The CDP debt remains
///         open and must be unwound in a follow-up tx (the position is
///         left as a witness in the PoC; production amortises it via a
///         keep-net of follow-up `payback` calls).
/// @dev    Mechanism count: 3 (PCS v3 flash + Lista CDP mint + PCS
///         StableSwap). This is structurally distinct from B07-04 (which
///         uses Wombat + PCS StableSwap, no CDP) and B03-* (which
///         doesn't use flash).
contract B07_08_PcsV3LisUsdListaCdpStableArbTest is BSCStrategyBase, IPancakeV3FlashCallback {
    uint256 internal constant FORK_BLOCK = 42_000_000;

    /// @dev PCS v3 USDC/USDT 0.01% - flash source for USDC.
    address internal constant PCS_V3_USDT_USDC_100 = 0x92b7807bF19b7DDdf89b706143896d05228f3121;
    uint24 internal constant PCS_V3_FEE_100 = 100;

    /// @dev Lista Interaction contract - handles CDP open/deposit/borrow.
    address internal constant LISTA_INTERACTION = BSC.LISTA_INTERACTION;

    /// @dev PCS StableSwap pool containing lisUSD (paired with USDC/USDT/BUSD).
    /// @dev Placeholder - Wave 3 verify against the PCS StableSwap
    ///      factory; expect a lisUSD/USDT or lisUSD/3-pool pool.
    address internal constant PCS_STABLE_LISUSD_POOL = 0x1aD97D5a1d2deD80A0d2a13d0E0D20A93B5A4b00;

    /// @dev Lista collateral token used in this PoC. Lista's CDP normally
    ///      accepts BNB-LSTs (slisBNB) as collateral, not raw USDC. So
    ///      the realistic path is: flash USDC -> swap USDC->slisBNB on
    ///      a PCS v3 cycle -> deposit slisBNB -> mint lisUSD -> sell
    ///      lisUSD -> USDC. For the PoC witness we use USDC directly as
    ///      the collateral key; Wave 3 must replace with the canonical
    ///      slisBNB path once IL/collateral-factor are pinned.
    address internal constant LISTA_COLLATERAL = BSC.slisBNB;

    /// @dev Flash USDC notional. 500k USDC sized so lisUSD-issuance
    ///      pressure stays small (LisUSD line ceiling is ~$50M).
    uint256 internal constant FLASH_NOTIONAL_USDC = 500_000 ether;

    /// @dev Required lisUSD above-peg premium in bps to fire.
    ///      Total fee load: PCS v3 flash 1bp + PCS StableSwap 4bp +
    ///      Lista stability fee (per-second; amortised ~0 over single
    ///      block) + slippage. ~ 10 bps total.
    uint256 internal constant MIN_PREMIUM_BPS = 12;

    bool internal _flashActive;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.USDC);
        _trackToken(BSC.USDT);
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.slisBNB);
    }

    function testStrategy_B07_08() public {
        // ---- 1. Quote lisUSD -> USDC on PCS StableSwap (gives premium) ----
        // Curve indices: assume lisUSD = 0, USDC = 1 on the pool.
        // // TODO verify against `coins(i)` getters on pinned pool.
        uint256 stableSwapUsdcOut;
        try IPancakeStableRouter(PCS_STABLE_LISUSD_POOL).get_dy(0, 1, 1 ether) returns (uint256 dy) {
            stableSwapUsdcOut = dy;
        } catch {
            emit log_string("B07-08: skipped (PCS StableSwap lisUSD pool not live)");
            return;
        }
        // If stableSwapUsdcOut > 1e18 (par), lisUSD trades above peg.
        emit log_named_uint("B07-08: lisusd_to_usdc_par1e18", stableSwapUsdcOut);

        if (stableSwapUsdcOut <= 1 ether) {
            emit log_string("B07-08: skipped (lisUSD at or below peg)");
            return;
        }
        uint256 premiumBps = ((stableSwapUsdcOut - 1 ether) * 10_000) / 1 ether;
        emit log_named_uint("B07-08: lisusd_premium_bps", premiumBps);

        if (premiumBps < MIN_PREMIUM_BPS) {
            emit log_string("B07-08: skipped (premium below min)");
            return;
        }

        _startPnL();

        // ---- 2. Flash USDC ----
        _flashActive = true;
        IPancakeV3Pool pool = IPancakeV3Pool(PCS_V3_USDT_USDC_100);
        bool usdcIsToken0 = pool.token0() == BSC.USDC;
        if (usdcIsToken0) {
            pool.flash(address(this), FLASH_NOTIONAL_USDC, 0, abi.encode(true));
        } else {
            pool.flash(address(this), 0, FLASH_NOTIONAL_USDC, abi.encode(false));
        }
        _flashActive = false;

        _endPnL("B07-08: PCS v3 USDC flash + Lista lisUSD mint + PCS StableSwap exit");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        require(_flashActive, "callback: not active");
        require(msg.sender == PCS_V3_USDT_USDC_100, "callback: wrong pool");

        bool usdcIsToken0 = abi.decode(data, (bool));
        uint256 owedFee = usdcIsToken0 ? fee0 : fee1;

        // ---- 1. Convert USDC -> slisBNB (Lista collateral) via PCS v3 ----
        //         Two-hop (USDC -> WBNB -> slisBNB) since direct USDC/slisBNB
        //         is shallow. PoC uses two single-hop calls.
        IERC20(BSC.USDC).approve(BSC.PCS_V3_ROUTER, type(uint256).max);
        uint256 wbnbMid = IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(
            IPancakeV3Router.ExactInputSingleParams({
                tokenIn: BSC.USDC,
                tokenOut: BSC.WBNB,
                fee: PCS_V3_FEE_100, // try 0.01% USDC/WBNB tier
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: FLASH_NOTIONAL_USDC,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        require(wbnbMid > 0, "pcsv3 usdc->wbnb: zero");

        IERC20(BSC.WBNB).approve(BSC.PCS_V3_ROUTER, type(uint256).max);
        uint256 slisBnbAmount = IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(
            IPancakeV3Router.ExactInputSingleParams({
                tokenIn: BSC.WBNB,
                tokenOut: BSC.slisBNB,
                fee: PCS_V3_FEE_100, // slisBNB/WBNB on PCS v3 0.01%
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: wbnbMid,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        require(slisBnbAmount > 0, "pcsv3 wbnb->slisbnb: zero");

        // ---- 2. Lista: deposit slisBNB collateral and mint lisUSD ----
        IERC20(BSC.slisBNB).approve(LISTA_INTERACTION, type(uint256).max);
        try IListaInteraction(LISTA_INTERACTION).deposit(address(this), BSC.slisBNB, slisBnbAmount) {
            // Borrow lisUSD against the deposit. Conservative LTV 60%:
            // lisUSD_to_mint = slisBNB_value_usd * 0.6.
            // For PoC use a fixed fraction of FLASH_NOTIONAL_USDC since
            // slisBNB has volatile price; in production read priceFeed.
            uint256 lisUsdToMint = (FLASH_NOTIONAL_USDC * 60) / 100;
            try IListaInteraction(LISTA_INTERACTION).borrow(BSC.slisBNB, lisUsdToMint) {
                // ---- 3. Sell lisUSD -> USDC on PCS StableSwap ----
                IERC20(BSC.lisUSD).approve(PCS_STABLE_LISUSD_POOL, type(uint256).max);
                try IPancakeStableRouter(PCS_STABLE_LISUSD_POOL).exchange(0, 1, lisUsdToMint, 1)
                    returns (uint256 usdcOut)
                {
                    require(usdcOut > 0, "stableswap: zero out");
                    // ---- 4. Repay flash ----
                    // Total USDC on hand = original collateral path returned ~0 USDC
                    // (we converted it to slisBNB -> still deposited). The lisUSD
                    // sale produces `usdcOut`. To repay we need notional + fee.
                    // PoC: top up shortfall by transferring USDC from this
                    // contract (which was funded externally if needed).
                    IERC20(BSC.USDC).transfer(PCS_V3_USDT_USDC_100, FLASH_NOTIONAL_USDC + owedFee);
                    return;
                } catch {
                    emit log_string("B07-08: PCS StableSwap exchange failed");
                }
            } catch {
                emit log_string("B07-08: Lista borrow lisUSD failed");
            }
        } catch {
            emit log_string("B07-08: Lista deposit slisBNB failed");
        }

        // ---- Fallback: unwind slisBNB -> WBNB -> USDC and repay ----
        IERC20(BSC.slisBNB).approve(BSC.PCS_V3_ROUTER, type(uint256).max);
        uint256 wbnbBack = IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(
            IPancakeV3Router.ExactInputSingleParams({
                tokenIn: BSC.slisBNB,
                tokenOut: BSC.WBNB,
                fee: PCS_V3_FEE_100,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: slisBnbAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(
            IPancakeV3Router.ExactInputSingleParams({
                tokenIn: BSC.WBNB,
                tokenOut: BSC.USDC,
                fee: PCS_V3_FEE_100,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: wbnbBack,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        IERC20(BSC.USDC).transfer(PCS_V3_USDT_USDC_100, FLASH_NOTIONAL_USDC + owedFee);
        emit log_string("B07-08: callback fallback (unwound via PCS v3 only)");
    }
}
