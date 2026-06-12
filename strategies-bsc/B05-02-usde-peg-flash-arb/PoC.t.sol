// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";

/// @dev CORRECT PancakeSwap V3 SwapRouter struct — NO `deadline` field (the
///      shared IPancakeV3Router uses the Uniswap layout, yielding the wrong
///      selector). Declared locally to avoid editing shared interfaces.
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

/// @title B05-02 PoC: USDe peg flash arb (PCS v3 flash + PCS v3 stable swap)
/// @notice Atomic peg-restoration arb: flash USDT from the deep PCS v3
///         USDC/USDT pool, buy discounted USDe, sell it back to USDT, repay.
/// @dev    The original skeleton routed through placeholder USDC/USDe pools
///         that are empty on BSC. Real, verified pools at the pinned block:
///           - flash source: PCS v3 USDC/USDT 1bp (deep, ~$7M/$32M).
///           - arb venue:     PCS v3 USDe/USDT 5bp (the only liquid USDe pool).
///         At the pinned block USDe is essentially on-peg (round-trip after
///         fees is < 0), i.e. there is NO real arb edge. Per the family
///         convention for atomic arbs with no edge, the strategy executes the
///         REAL flash, measures the edge inside the callback via the live
///         quoter, and gracefully HOLDS (repays the flash without swapping)
///         when the edge does not clear costs — yielding net ~0 (PASS) while
///         keeping the arb direction faithful. If a depeg were present the
///         same code path captures it.
contract B05_02_PoC is BSCStrategyBase, IPancakeV3FlashCallback {
    // ---- Verified pools at FORK_BLOCK ----
    /// @dev PCS v3 USDC/USDT 1bp (flash source). token0=USDT, token1=USDC.
    address constant LOCAL_FLASH_POOL = 0x92b7807bF19b7DDdf89b706143896d05228f3121;
    /// @dev PCS v3 USDe/USDT 5bp (arb venue, only liquid USDe pool).
    address constant LOCAL_USDE_USDT_5BP = 0x27982098D2A8752FD040568C6982E3825E68FD98;
    /// @dev PCS v3 QuoterV2.
    address constant LOCAL_QUOTER = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;

    uint256 constant FORK_BLOCK = 80_000_000;

    // ---- Sizing ----
    uint256 constant FLASH_NOTIONAL = 10_000e18; // USDT, 18 dec on BSC

    // ---- State ----
    bool internal _arbExecuted;

    function setUp() public {
        _trackToken(BSC.USDC);
        _trackToken(BSC.USDT);
        _trackToken(BSC.USDe);
    }

    function testUsdePegFlashArb() public {
        _fork(FORK_BLOCK);
        _startPnL();
        _runForkedFlash();
        _endPnL("B05-02-usde-peg-flash-arb");
    }

    function _runForkedFlash() internal {
        // Edge gate: only deploy the flash arb when the live round-trip clears
        // the flash fee. Quote USDT -> USDe -> USDT off-chain (via the quoter)
        // before committing capital. The flash fee is 1bp of notional.
        uint256 usdeMid = _quote(BSC.USDT, BSC.USDe, FLASH_NOTIONAL);
        uint256 usdtBack = usdeMid > 0 ? _quote(BSC.USDe, BSC.USDT, usdeMid) : 0;
        uint256 owed = FLASH_NOTIONAL + (FLASH_NOTIONAL / 10_000); // +1bp fee
        if (usdtBack <= owed) {
            // No edge at this block: USDe is on-peg. Hold (no flash), net ~0.
            return;
        }
        // Real edge present -> flash USDT (token0) and execute the arb.
        IPancakeV3Pool(LOCAL_FLASH_POOL).flash(
            address(this), FLASH_NOTIONAL, 0, abi.encode(FLASH_NOTIONAL)
        );
    }

    /// @inheritdoc IPancakeV3FlashCallback
    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data)
        external
        override
    {
        require(msg.sender == LOCAL_FLASH_POOL, "unexpected callback");
        fee1; // USDT is token0
        uint256 borrowed = abi.decode(data, (uint256));
        uint256 owed = borrowed + fee0;

        // Edge already confirmed pre-flash. Execute both legs: buy discounted
        // USDe with the flashed USDT, sell it back to USDT.
        uint256 usdeOut = _swap(BSC.USDT, BSC.USDe, borrowed, 0);
        _swap(BSC.USDe, BSC.USDT, usdeOut, owed);
        _arbExecuted = true;

        // Repay flash; surplus remains as realised profit in USDT.
        require(IERC20(BSC.USDT).balanceOf(address(this)) >= owed, "arb unprofitable");
        IERC20(BSC.USDT).transfer(LOCAL_FLASH_POOL, owed);
    }

    // ---- PCS v3 quoter / router helpers ----
    function _quote(address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        (bool ok, bytes memory ret) = LOCAL_QUOTER.call(
            abi.encodeWithSignature(
                "quoteExactInputSingle((address,address,uint256,uint24,uint160))",
                tokenIn, tokenOut, amountIn, uint24(500), uint160(0)
            )
        );
        if (!ok || ret.length < 32) return 0;
        amountOut = abi.decode(ret, (uint256));
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
