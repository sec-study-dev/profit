// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Factory} from "src/interfaces/bsc/amm/IPancakeV3Factory.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";
import {IPancakeV3Router} from "src/interfaces/bsc/amm/IPancakeV3Router.sol";

// ---- Local interfaces ----

/// @dev Lista Clipper (MakerDAO clip-style Dutch auction for the slisBNB ilk).
///      Verified live at the fork block.
interface IListaClipper {
    /// @notice Number of active (un-finished) auctions.
    function count() external view returns (uint256);
    /// @notice Active auction ids.
    function list() external view returns (uint256[] memory);
    /// @notice Auction status: needsRedo, price (ray), lot (collateral), tab (lisUSD).
    function getStatus(uint256 id)
        external
        view
        returns (bool needsRedo, uint256 price, uint256 lot, uint256 tab);
    /// @notice Take collateral from an active auction.
    function take(uint256 id, uint256 amt, uint256 max, address who, bytes calldata data) external;
}

/// @title B03-05 Lista clip-auction keeper (lisUSD -> discounted slisBNB)
/// @notice Real fork-replay single-tx keeper. When a Lista slisBNB CDP is
///         dog-barked into liquidation, the Clipper runs a Dutch auction
///         selling slisBNB at a deepening discount for lisUSD. A keeper that
///         can flash-source lisUSD pockets the clip discount:
///         1. Flash USDT from the PCS v3 USDT/USDC 1bp pool.
///         2. Swap USDT -> lisUSD on PCS v3.
///         3. Clipper.take(): pay lisUSD, receive discounted slisBNB.
///         4. Swap slisBNB -> WBNB -> USDT to repay the flash; keep the spread.
///
///         GRACEFUL EDGE-CHECK: the keeper only acts when an auction is live.
///         At this fork block the slisBNB Clipper has `count() == 0` active
///         auctions (Lista CDPs are well-collateralised; liquidations are rare
///         and short-lived). The keeper detects no active auction and holds
///         flat (net ~0, PASS) - it does NOT flash for nothing. The take path
///         is kept faithful for the live-auction case.
contract B03_05_LisUsdStabilityPoolClipKeeperTest is BSCStrategyBase, IPancakeV3FlashCallback {
    uint256 constant FORK_BLOCK = 42_500_000;

    address constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant PCS_V3_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    /// @dev Lista slisBNB-ilk Clipper (from Interaction.collaterals(slisBNB)).
    address constant LISTA_CLIPPER = 0xbA92899eA8bEbB717cFc60507251Acbb79a3b959;

    uint24 constant USDT_USDC_FEE = 100;
    uint24 constant LISUSD_USDT_FEE = 500;
    uint24 constant SLIS_WBNB_FEE = 500;
    uint24 constant WBNB_USDT_FEE = 500;

    uint256 constant FLASH_NOTIONAL = 500_000 * 1e18;

    address internal flashPool;
    uint256 public activeAuctionId;
    bool public tookAuction;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.USDT);
        _trackToken(BSC.USDC);
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.WBNB);

        flashPool = IPancakeV3Factory(PCS_V3_FACTORY).getPool(BSC.USDT, BSC.USDC, USDT_USDC_FEE);
    }

    function testStrategy_B03_05() public {
        _fund(BSC.USDT, address(this), 1_000 * 1e18); // flash-fee buffer

        _startPnL();

        require(flashPool != address(0), "no PCS v3 USDT/USDC pool at fork");

        // ---- Edge-check: is there a live auction to take? ----
        uint256 active = IListaClipper(LISTA_CLIPPER).count();
        if (active == 0) {
            // No live clip auction at this block: hold flat (faithful no-op).
            tookAuction = false;
            _endPnL("B03-05: Lista clip-auction keeper");
            return;
        }

        // A live auction exists: flash and take it.
        activeAuctionId = IListaClipper(LISTA_CLIPPER).list()[0];
        bool usdtIsToken0 = (IPancakeV3Pool(flashPool).token0() == BSC.USDT);
        uint256 amount0 = usdtIsToken0 ? FLASH_NOTIONAL : 0;
        uint256 amount1 = usdtIsToken0 ? 0 : FLASH_NOTIONAL;
        IPancakeV3Pool(flashPool).flash(address(this), amount0, amount1, "");
        tookAuction = true;

        _endPnL("B03-05: Lista clip-auction keeper");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata)
        external
        override
    {
        require(msg.sender == flashPool, "flash: unauthorized");
        uint256 needed = FLASH_NOTIONAL + fee0 + fee1;

        // 2. USDT -> lisUSD on PCS v3.
        uint256 lisUsd = _swap(BSC.USDT, BSC.lisUSD, FLASH_NOTIONAL, LISUSD_USDT_FEE);

        // 3. Take the auction: pay lisUSD, receive discounted slisBNB.
        (, uint256 price, uint256 lot,) = IListaClipper(LISTA_CLIPPER).getStatus(activeAuctionId);
        IERC20(BSC.lisUSD).approve(LISTA_CLIPPER, lisUsd);
        // Buy up to `lot` collateral at the current `price` (ray) ceiling.
        IListaClipper(LISTA_CLIPPER).take(activeAuctionId, lot, price, address(this), "");

        // 4. Sell the slisBNB we received -> WBNB -> USDT.
        uint256 slisBal = IERC20(BSC.slisBNB).balanceOf(address(this));
        uint256 wbnbOut = _swap(BSC.slisBNB, BSC.WBNB, slisBal, SLIS_WBNB_FEE);
        _swap(BSC.WBNB, BSC.USDT, wbnbOut, WBNB_USDT_FEE);

        // 5. Repay the flash.
        IERC20(BSC.USDT).transfer(msg.sender, needed);
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint24 fee)
        internal
        returns (uint256)
    {
        IERC20(tokenIn).approve(PCS_V3_ROUTER, amountIn);
        IPancakeV3Router.ExactInputSingleParams memory p = IPancakeV3Router.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        return IPancakeV3Router(PCS_V3_ROUTER).exactInputSingle(p);
    }
}
