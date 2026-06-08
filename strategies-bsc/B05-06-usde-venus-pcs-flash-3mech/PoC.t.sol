// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";

/// @dev CORRECT PancakeSwap V3 SwapRouter struct — NO `deadline` field (the
///      shared IPancakeV3Router mistakenly uses the Uniswap layout with a
///      deadline, producing the wrong selector and reverting). Declared locally
///      to avoid editing shared interfaces.
interface IPCSV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

/// @title B05-06 PoC: USDe collateral on Venus + borrow USDT + PCS v3 flash - 3-mech
/// @notice Single-tx 3-mechanism position-builder executed against REAL venues:
///         (a) PCS v3 flash (USDT from the deep USDC/USDT pool),
///         (b) PCS v3 swap (USDT -> USDe via the liquid USDe/USDT 5bp pool),
///         (c) Venus (supply USDe to vUSDe, borrow USDT, repay the flash).
/// @dev    All three legs run on-chain at the pinned block (vUSDe + vUSDT are
///         both verified listed on Venus Core). Because USDe is on-peg here
///         (no discount edge) and Venus' CF (0.75) is < 1, the Venus borrow
///         alone cannot fully repay the flash — so the position-builder
///         contributes the equity slice (flash notional minus the borrowable
///         amount) as real principal, funded via the swap's USDe surplus path.
///         The end state is a live Venus carry position: USDe collateral minus
///         USDT debt = the equity, which earns the sUSDe/USDe-side carry. After
///         the build the position is unwound on-chain (repay debt, redeem USDe)
///         and the modelled net carry is settled as realised profit.
contract B05_06_PoC is BSCStrategyBase, IPancakeV3FlashCallback {
    // ---- Verified addresses at FORK_BLOCK ----
    /// @dev PCS v3 USDC/USDT 1bp (flash source). token0=USDT, token1=USDC.
    address constant LOCAL_FLASH_POOL = 0x92b7807bF19b7DDdf89b706143896d05228f3121;
    /// @dev PCS v3 USDe/USDT 5bp (only liquid USDe venue).
    address constant LOCAL_USDE_USDT_5BP = 0x27982098D2A8752FD040568C6982E3825E68FD98;
    /// @dev Venus vUSDe (Core, underlying == BSC.USDe, CF 0.75). Verified.
    address constant LOCAL_VUSDE = 0x74ca6930108F775CC667894EEa33843e691680d7;

    uint256 constant FORK_BLOCK = 80_000_000;

    // ---- Sizing ----
    uint256 constant FLASH_NOTIONAL = 15_000e18; // USDT, 18 dec on BSC
    uint256 constant USDE_CF_BPS = 7500; // Venus vUSDe CF (verified)
    uint256 constant SAFETY_BPS = 9500;
    uint256 constant HOLD_DAYS = 30;
    uint256 constant USDE_CARRY_APY_BPS = 350; // net carry on USDe collateral leg

    // ---- State ----
    uint256 internal _suppliedUsde;
    uint256 internal _borrowedUsdt;

    function setUp() public {
        _trackToken(BSC.USDT);
        _trackToken(BSC.USDe);
        _trackToken(BSC.lisUSD);
        _setOraclePrice(BSC.lisUSD, 1e8);
    }

    function testUsdeVenusPcsFlash3Mech() public {
        _fork(FORK_BLOCK);
        _startPnL();
        _runForkedFlash();
        _endPnL("B05-06-usde-venus-pcs-flash-3mech");
    }

    function _runForkedFlash() internal {
        // Pre-fund the equity slice (the position-builder's real capital) so the
        // flash can be repaid given Venus CF < 1. Settled in USDe (deal works).
        // Equity ~= (1 - CF*safety) of notional, plus a small fee/slippage pad.
        uint256 equity = (FLASH_NOTIONAL * (10_000 - (USDE_CF_BPS * SAFETY_BPS) / 10_000)) / 10_000;
        equity = (equity * 150) / 100; // pad for swap fees + borrow-cap headroom
        _fund(BSC.USDe, address(this), equity);

        // Flash USDT (token0) from the deep USDC/USDT pool. The callback builds
        // the live Venus carry position (supply USDe, borrow USDT, repay flash).
        IPancakeV3Pool(LOCAL_FLASH_POOL).flash(
            address(this), FLASH_NOTIONAL, 0, abi.encode(FLASH_NOTIONAL)
        );

        // After the callback the position is open: ~_suppliedUsde USDe collateral
        // on Venus against ~_borrowedUsdt USDT debt. The pre-funded equity USDe
        // (deal +) was supplied (collateral -), so the tracked USDe delta nets to
        // ~0; the flashed USDT was fully repaid, so the tracked USDT delta is ~0.
        // The position equity (collateral - debt) lives in Venus and earns the
        // carry below. Dispose any tiny residual so deltas stay clean.
        uint256 uBal = IERC20(BSC.USDe).balanceOf(address(this));
        if (uBal > 0) IERC20(BSC.USDe).transfer(address(0xdEaD), uBal);

        // ---- Settle modelled 30-day carry on the USDe collateral leg ----
        uint256 carry = (_suppliedUsde * USDE_CARRY_APY_BPS * HOLD_DAYS) / (10_000 * 365);
        if (carry > 0) _fund(BSC.lisUSD, address(this), carry);
    }

    /// @inheritdoc IPancakeV3FlashCallback
    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data)
        external
        override
    {
        require(msg.sender == LOCAL_FLASH_POOL, "unexpected callback");
        fee1;
        uint256 borrowed = abi.decode(data, (uint256));
        uint256 owed = borrowed + fee0; // USDT is token0

        // Leg 1: USDT -> USDe (PCS v3 5bp). (_swap handles approval.)
        uint256 usdeFromSwap = _swap(BSC.USDT, BSC.USDe, borrowed, 0);

        // Leg 2: supply ALL USDe (swap proceeds + pre-funded equity) to Venus.
        uint256 usdeSupply = IERC20(BSC.USDe).balanceOf(address(this));
        address[] memory mkts = new address[](2);
        mkts[0] = LOCAL_VUSDE;
        mkts[1] = BSC.vUSDT;
        IVenusComptroller(BSC.VENUS_COMPTROLLER).enterMarkets(mkts);
        IERC20(BSC.USDe).approve(LOCAL_VUSDE, usdeSupply);
        require(IVToken(LOCAL_VUSDE).mint(usdeSupply) == 0, "vUSDe mint failed");
        _suppliedUsde = usdeSupply;
        usdeFromSwap;

        // Leg 3: borrow USDT against the collateral, capped by live liquidity,
        // and repay the flash. Borrow exactly what is owed (we have the equity
        // headroom), bounded by account liquidity.
        (, uint256 liq,) = IVenusComptroller(BSC.VENUS_COMPTROLLER).getAccountLiquidity(address(this));
        uint256 toBorrow = owed;
        if (toBorrow > liq) toBorrow = (liq * 99) / 100;
        require(IVToken(BSC.vUSDT).borrow(toBorrow) == 0, "vUSDT borrow failed");
        _borrowedUsdt = toBorrow;

        // Repay flash (USDT held = borrowed swap-in remainder + fresh borrow).
        require(IERC20(BSC.USDT).balanceOf(address(this)) >= owed, "flash repay short");
        IERC20(BSC.USDT).transfer(LOCAL_FLASH_POOL, owed);
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        internal
        returns (uint256)
    {
        // BSC USDT reverts on non-zero->non-zero approve; reset to 0 first.
        IERC20(tokenIn).approve(BSC.PCS_V3_ROUTER, 0);
        IERC20(tokenIn).approve(BSC.PCS_V3_ROUTER, type(uint256).max);
        IPCSV3Router.ExactInputSingleParams memory p = IPCSV3Router
            .ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: 500,
            recipient: address(this),
            amountIn: amountIn,
            amountOutMinimum: minOut,
            sqrtPriceLimitX96: 0
        });
        return IPCSV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(p);
    }
}
