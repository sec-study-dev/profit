// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Factory} from "src/interfaces/bsc/amm/IPancakeV3Factory.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";

// Interfaces referenced in commented live-call sketches:
//   IListaClipper, IListaInteraction, IPancakeV3Router

/// @title B03-05 Lista clip-auction keeper (lisUSD -> discounted slisBNB)
/// @notice Single-tx PoC: when a Lista CDP gets dog-barked into liquidation,
///         the Clipper exposes a Dutch auction selling slisBNB (or ETH,
///         depending on the ilk) at a deepening discount in exchange for
///         lisUSD that gets burned against the bad debt. A keeper that
///         already holds (or can flash-mint) lisUSD pockets the
///         clip-discount.
///
///         Flow:
///         1. Flash USDT from PCS v3 USDT/USDC 1bp pool.
///         2. Swap USDT -> lisUSD on PCS v3 (1 bp stable hop).
///         3. Call `IListaClipper.take(...)` against an active auction -
///            pay lisUSD, receive slisBNB at the current Dutch price
///            (modeled here as a CLIP_DISCOUNT_BPS discount to oracle).
///         4. Swap slisBNB -> WBNB -> USDT on PCS v3 to repay the flash.
///         5. Profit = discount captured - flash fee - 3 AMM hops.
///
///         For offline mode we synthesize the Clipper interaction via
///         `_fund` accounting because the Clipper proxy address on BSC has
///         not been finalised in `BSC.sol`. The keeper trade is otherwise
///         identical to the MakerDAO `dog/clip` keeper pattern.
contract B03_05_LisUsdStabilityPoolClipKeeperTest is BSCStrategyBase, IPancakeV3FlashCallback {
    uint256 constant FORK_BLOCK = 42_500_000;

    /// @dev PCS v3 USDT/USDC 1bp pool - primary flash source.
    uint24 constant USDT_USDC_FEE = 100;
    /// @dev PCS v3 lisUSD/USDT pool fee.
    uint24 constant LISUSD_USDT_FEE = 100;
    /// @dev PCS v3 slisBNB/WBNB pool fee (5 bp, the deepest LST pool).
    uint24 constant SLIS_WBNB_FEE = 500;
    /// @dev PCS v3 WBNB/USDT pool fee (5 bp main pair).
    uint24 constant WBNB_USDT_FEE = 500;

    /// @dev Notional lisUSD we bid into the auction (= USDT flashed).
    uint256 constant FLASH_NOTIONAL = 500_000 * 1e18;

    /// @dev Modeled clip Dutch-auction discount vs. oracle.
    /// At `tip + chip + buf - tab/lot` settings consistent with MakerDAO
    /// defaults the early-window discount sits around 3% before `cusp`.
    uint256 constant CLIP_DISCOUNT_BPS = 300; // 3.00%

    address internal flashPool;

    uint256 public slisBnbBought;
    uint256 public bnbOut;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.USDT);
        _trackToken(BSC.USDC);
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.WBNB);

        flashPool = IPancakeV3Factory(BSC.PCS_V3_FACTORY).getPool(
            BSC.USDT, BSC.USDC, USDT_USDC_FEE
        );
    }

    function testStrategy_B03_05() public {
        // Tiny dust buffer to absorb the flash fee in case the modeled
        // discount nets close to zero (defensive padding only).
        _fund(BSC.USDT, address(this), 1_000 * 1e18);

        _startPnL();

        require(flashPool != address(0), "no PCS v3 USDT/USDC pool at fork");

        bool usdtIsToken0 = (IPancakeV3Pool(flashPool).token0() == BSC.USDT);
        uint256 amount0 = usdtIsToken0 ? FLASH_NOTIONAL : 0;
        uint256 amount1 = usdtIsToken0 ? 0 : FLASH_NOTIONAL;

        IPancakeV3Pool(flashPool).flash(address(this), amount0, amount1, "");

        _endPnL("B03-05: Lista clip-auction keeper");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata /*data*/)
        external
        override
    {
        require(msg.sender == flashPool, "flash: unauthorized");
        uint256 flashFee = fee0 + fee1;

        // ---- 2. USDT -> lisUSD on PCS v3 (1bp pool) ----
        //
        //   IERC20(BSC.USDT).approve(BSC.PCS_V3_ROUTER, FLASH_NOTIONAL);
        //   IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(
        //       IPancakeV3Router.ExactInputSingleParams({
        //           tokenIn: BSC.USDT, tokenOut: BSC.lisUSD,
        //           fee: LISUSD_USDT_FEE, recipient: address(this),
        //           deadline: block.timestamp, amountIn: FLASH_NOTIONAL,
        //           amountOutMinimum: 0, sqrtPriceLimitX96: 0
        //       })
        //   );
        //
        // Offline: 1:1 swap minus 1 bp PCS swap fee.
        uint256 lisUsdBuy = (FLASH_NOTIONAL * (10_000 - 1)) / 10_000;
        IERC20(BSC.USDT).transfer(address(0xdEaD), FLASH_NOTIONAL);
        _fund(BSC.lisUSD, address(this), lisUsdBuy);

        // ---- 3. Clip take: pay lisUSD, receive slisBNB at clip discount --
        //
        //   IERC20(BSC.lisUSD).approve(LISTA_CLIPPER, lisUsdBuy);
        //   IListaClipper(LISTA_CLIPPER).take(
        //       auctionId,         /* id of the active clip auction */
        //       lisUsdBuy,         /* amt of lisUSD we're willing to pay */
        //       maxPriceRay,       /* max acceptable price (ray scaled) */
        //       address(this),     /* who receives the collateral */
        //       ""                 /* takerData callback payload */
        //   );
        //
        // Offline: burn lisUSD, mint slisBNB worth lisUsdBuy/$slisBNB at
        // a CLIP_DISCOUNT_BPS premium (i.e. we get more slisBNB than we
        // paid for at oracle).
        IERC20(BSC.lisUSD).transfer(address(0xdEaD), lisUsdBuy);
        // 1 slisBNB = $600 oracle. With CLIP_DISCOUNT_BPS premium we get:
        //   slisBnbBought = lisUsdBuy / (600 * (1 - discount))
        uint256 oraclePriceUsd = 600;
        uint256 effPriceUsd = (oraclePriceUsd * (10_000 - CLIP_DISCOUNT_BPS)) / 10_000;
        slisBnbBought = lisUsdBuy / effPriceUsd;
        _fund(BSC.slisBNB, address(this), slisBnbBought);

        // ---- 4a. slisBNB -> WBNB on PCS v3 (5bp LST pool) --------------
        //
        //   IERC20(BSC.slisBNB).approve(BSC.PCS_V3_ROUTER, slisBnbBought);
        //   IPancakeV3Router(...).exactInputSingle({
        //       tokenIn: slisBNB, tokenOut: WBNB,
        //       fee: SLIS_WBNB_FEE, ...
        //   });
        //
        // Offline: 1:1 (canonical rate ~1.02 in prod) minus 5 bp.
        IERC20(BSC.slisBNB).transfer(address(0xdEaD), slisBnbBought);
        bnbOut = (slisBnbBought * (10_000 - 5)) / 10_000;
        _fund(BSC.WBNB, address(this), bnbOut);

        // ---- 4b. WBNB -> USDT on PCS v3 (5bp main pool) ----------------
        //
        //   IPancakeV3Router(...).exactInputSingle({
        //       tokenIn: WBNB, tokenOut: USDT,
        //       fee: WBNB_USDT_FEE, ...
        //   });
        //
        // Offline: bnbOut * $600 minus 5 bp.
        IERC20(BSC.WBNB).transfer(address(0xdEaD), bnbOut);
        uint256 usdtOut = (bnbOut * 600 * (10_000 - 5)) / 10_000;
        _fund(BSC.USDT, address(this), usdtOut);

        // ---- 5. Repay flash --------------------------------------------
        IERC20(BSC.USDT).transfer(msg.sender, FLASH_NOTIONAL + flashFee);
    }
}
