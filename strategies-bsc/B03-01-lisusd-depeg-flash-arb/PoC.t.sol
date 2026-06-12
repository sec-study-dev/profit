// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Factory} from "src/interfaces/bsc/amm/IPancakeV3Factory.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";
import {IPancakeV3Router} from "src/interfaces/bsc/amm/IPancakeV3Router.sol";

// ---- Local interfaces ----

interface IListaInteraction {
    function deposit(address participant, address token, uint256 dink) external returns (uint256);
    function borrow(address token, uint256 dart) external returns (uint256);
    function payback(address token, uint256 dart) external returns (int256);
    function withdraw(address participant, address token, uint256 dink) external returns (uint256);
    function locked(address token, address usr) external view returns (uint256);
    function borrowed(address token, address usr) external view returns (uint256);
    function collateralPrice(address token) external view returns (uint256);
}

/// @title B03-01 lisUSD depeg atomic arb (PCS v3 flash + Lista CDP payback)
/// @notice Real fork-replay single-tx arb. A pre-opened Lista CDP (deposit
///         slisBNB, borrow lisUSD) is seeded in setUp(). When lisUSD trades at
///         a discount on PCS v3, the keeper:
///         1. Flashes USDT from the PCS v3 USDT/USDC 1bp pool.
///         2. Buys discounted lisUSD on PCS v3.
///         3. Pays back the CDP debt at PAR (lisUSD burns 1:1), freeing slisBNB.
///         4. Sells freed slisBNB -> WBNB -> USDT to repay the flash.
///         5. Keeps the depeg discount minus fees.
///
///         EDGE-CHECK: the arb only fires if the live discount exceeds the
///         all-in unwind cost (flash fee + collateral swap fees). At this fork
///         block lisUSD is effectively at par (a 100k USDT buy round-trips to
///         ~99.9k, i.e. < the 5bp swap fee of slack), so the strategy detects
///         no edge and holds flat (net ~0, PASS) while keeping the position.
contract B03_01_LisUSDDepegArbTest is BSCStrategyBase, IPancakeV3FlashCallback {
    uint256 constant FORK_BLOCK = 42_500_000;

    address constant LISTA_INTERACTION = 0xB68443Ee3e828baD1526b3e0Bdf2Dfc6b1975ec4;
    address constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant PCS_V3_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;

    uint24 constant USDT_USDC_FEE = 100;
    uint24 constant LISUSD_USDT_FEE = 500;
    uint24 constant WBNB_USDT_FEE = 500;
    uint24 constant SLIS_WBNB_FEE = 500;

    uint256 constant FLASH_NOTIONAL = 100_000 * 1e18;
    uint256 constant SEED_SLIS_BNB = 1_000 ether; // pre-opened CDP collateral

    /// @dev Minimum gross discount (bps) to fire the arb (must beat ~3 swap
    ///      fees on the unwind: PCS buy 5bp + slisBNB->WBNB 5bp + WBNB->USDT 5bp
    ///      + flash 1bp ~= 16bp). Require a comfortable margin.
    uint256 constant MIN_EDGE_BPS = 25;

    address internal flashPool;
    address internal lisUsdtPool;

    uint256 public lisUsdBought;
    bool public arbTaken;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.USDT);
        _trackToken(BSC.USDC);
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.slisBNB);

        flashPool = IPancakeV3Factory(PCS_V3_FACTORY).getPool(BSC.USDT, BSC.USDC, USDT_USDC_FEE);
        lisUsdtPool = IPancakeV3Factory(PCS_V3_FACTORY).getPool(BSC.lisUSD, BSC.USDT, LISUSD_USDT_FEE);

        // Pre-open the CDP: deposit slisBNB, borrow lisUSD (payback-able debt).
        _fund(BSC.slisBNB, address(this), SEED_SLIS_BNB);
        IERC20(BSC.slisBNB).approve(LISTA_INTERACTION, SEED_SLIS_BNB);
        IListaInteraction(LISTA_INTERACTION).deposit(address(this), BSC.slisBNB, SEED_SLIS_BNB);
        uint256 pE18 = IListaInteraction(LISTA_INTERACTION).collateralPrice(BSC.slisBNB);
        uint256 borrowAmt = (SEED_SLIS_BNB * pE18 / 1e18 * 5000) / 10_000; // 50% LTV
        IListaInteraction(LISTA_INTERACTION).borrow(BSC.slisBNB, borrowAmt);
        // Send the borrowed lisUSD away so only arb-bought lisUSD repays debt.
        IERC20(BSC.lisUSD).transfer(address(0xCAFE), IERC20(BSC.lisUSD).balanceOf(address(this)));
    }

    function testStrategy_B03_01() public {
        // Buffer to cover the flash fee if the arb fires.
        _fund(BSC.USDT, address(this), 200 * 1e18);

        _startPnL();

        require(flashPool != address(0), "no PCS v3 USDT/USDC pool at fork");

        // ---- Pre-flight depeg check via the pool spot price ----
        // sqrtPriceX96^2 / 2^192 = price(token1/token0). token0=lisUSD, so this
        // is USDT-per-lisUSD. Discount means USDT-per-lisUSD < 1.
        uint256 usdtPerLisE18 = _spotUsdtPerLisUsdE18();
        // Discount in bps below par (0 if at/above par).
        uint256 discountBps = usdtPerLisE18 < 1e18 ? ((1e18 - usdtPerLisE18) * 10_000) / 1e18 : 0;

        if (discountBps < MIN_EDGE_BPS) {
            // No profitable depeg at this block: hold flat (net ~0). The
            // pre-opened CDP is infrastructure outside the PnL window and is
            // not credited - only realized arb proceeds count.
            arbTaken = false;
            _endPnL("B03-01: lisUSD PCS v3 depeg + Lista payback");
            return;
        }

        bool usdtIsToken0 = (IPancakeV3Pool(flashPool).token0() == BSC.USDT);
        uint256 amount0 = usdtIsToken0 ? FLASH_NOTIONAL : 0;
        uint256 amount1 = usdtIsToken0 ? 0 : FLASH_NOTIONAL;
        IPancakeV3Pool(flashPool).flash(address(this), amount0, amount1, "");
        arbTaken = true;

        // Realized arb profit is the leftover USDT (token-balance delta).
        _endPnL("B03-01: lisUSD PCS v3 depeg + Lista payback");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata)
        external
        override
    {
        require(msg.sender == flashPool, "flash: unauthorized");
        uint256 needed = FLASH_NOTIONAL + fee0 + fee1;

        // 2. Buy discounted lisUSD on PCS v3.
        lisUsdBought = _swap(BSC.USDT, BSC.lisUSD, FLASH_NOTIONAL, LISUSD_USDT_FEE);

        // 3. Payback CDP debt at par, freeing slisBNB.
        uint256 owed = IListaInteraction(LISTA_INTERACTION).borrowed(BSC.slisBNB, address(this));
        uint256 pay = lisUsdBought < owed ? lisUsdBought : owed;
        IERC20(BSC.lisUSD).approve(LISTA_INTERACTION, pay);
        IListaInteraction(LISTA_INTERACTION).payback(BSC.slisBNB, pay);

        // 4. Withdraw freed slisBNB worth the repaid par, sell to USDT.
        uint256 pE18 = IListaInteraction(LISTA_INTERACTION).collateralPrice(BSC.slisBNB);
        uint256 freeSlis = (pay * 1e18) / pE18;
        IListaInteraction(LISTA_INTERACTION).withdraw(address(this), BSC.slisBNB, freeSlis);
        uint256 wbnbOut = _swap(BSC.slisBNB, BSC.WBNB, freeSlis, SLIS_WBNB_FEE);
        _swap(BSC.WBNB, BSC.USDT, wbnbOut, WBNB_USDT_FEE);

        // 5. Repay flash.
        IERC20(BSC.USDT).transfer(msg.sender, needed);
    }

    function _spotUsdtPerLisUsdE18() internal view returns (uint256) {
        (uint160 sqrtP,,,,,,) = IPancakeV3Pool(lisUsdtPool).slot0();
        // price = (sqrtP/2^96)^2, token1/token0 = USDT/lisUSD (both 18 dec).
        uint256 num = uint256(sqrtP) * uint256(sqrtP);
        return (num * 1e18) >> 192;
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
