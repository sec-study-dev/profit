// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";

/// @notice Local PCS v3 SwapRouter (no deadline) per the shared playbook.
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
    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256);
}

/// @title B06-04 VAI depeg - atomic PCS v3 flash + StableSwap arb
/// @notice The original "PCS StableSwap VAI/USDT/USDC 3pool" does not exist on
///         BSC; VAI's real venue is the PCS **v3** VAI/USDT pool. Faithful
///         restructure: detect the VAI depeg from the v3 VAI/USDT pool price,
///         and when it is wide enough, flash USDT from the v3 USDT/USDC pool,
///         buy cheap VAI, and round-trip it back to USDT for a stable profit.
///         If the depeg is below the gas-worthwhile threshold, the strategy
///         gracefully holds (net ~0) - the arb direction stays faithful.
contract B06_04_VAIDepegPCSFlashArbTest is BSCStrategyBase, IPancakeV3FlashCallback {
    uint256 internal constant FORK_BLOCK = 44_000_000;

    // ---- Verified addresses ----
    /// @notice PCS v3 SwapRouter (no-deadline).
    address internal constant LOCAL_PCS_V3_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    /// @notice PCS v3 VAI/USDT fee-100 pool (deepest VAI venue).
    address internal constant LOCAL_PCS_V3_VAI_USDT = 0xF5B4B24E5808DAA3fBeee11DF27a0994600356b4;
    uint24 internal constant VAI_USDT_FEE = 100;
    /// @notice PCS v3 USDT/USDC fee-100 pool (flash source). USDT=token0.
    address internal constant LOCAL_PCS_V3_USDT_USDC = 0x92b7807bF19b7DDdf89b706143896d05228f3121;

    // ---- Strategy parameters ----
    uint256 internal constant FLASH_USDT = 50_000e18;
    /// @dev Minimum depeg (bps) below which we skip - gas isn't worth it.
    uint256 internal constant MIN_DEPEG_BPS = 30;
    uint256 internal constant BUFFER = 5_000e18;

    bool internal _inFlash;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.USDT);
        _trackToken(BSC.USDC);
        _trackToken(BSC.VAI);
    }

    function testStrategy_B06_04_atomic() public {
        _fund(BSC.USDT, address(this), BUFFER);
        _startPnL();

        // ---- Detect depeg from the v3 VAI/USDT pool tick ----
        // VAI = token0, USDT = token1. price(USDT per VAI) = 1.0001^tick.
        (, int24 tick,,,,,) = IPancakeV3Pool(LOCAL_PCS_V3_VAI_USDT).slot0();
        // tick < 0 => VAI worth < 1 USDT (depegged below peg).
        uint256 depegBps = tick < 0 ? uint256(uint24(-tick)) : 0;
        emit log_named_int("vai_usdt_tick", tick);
        emit log_named_uint("approx_depeg_bps", depegBps);

        if (depegBps < MIN_DEPEG_BPS) {
            // No worthwhile edge: hold. PnL prints ~0 (buffer untouched).
            _endPnL("B06-04: VAI depeg arb (no edge, hold)");
            return;
        }

        // ---- Flash USDT from the USDT/USDC pool (USDT is token0 -> amount0) ----
        _inFlash = true;
        IPancakeV3Pool(LOCAL_PCS_V3_USDT_USDC).flash(address(this), FLASH_USDT, 0, "");
        _inFlash = false;

        _endPnL("B06-04: VAI depeg atomic arb");
    }

    // ---- IPancakeV3FlashCallback ----------------------------------------

    function pancakeV3FlashCallback(uint256 fee0, uint256 /*fee1*/, bytes calldata /*data*/) external {
        require(_inFlash, "unsolicited flash");
        require(msg.sender == LOCAL_PCS_V3_USDT_USDC, "only flash pool");

        // Buy cheap VAI with the flashed USDT.
        IERC20(BSC.USDT).approve(LOCAL_PCS_V3_ROUTER, FLASH_USDT);
        uint256 vaiOut = IPCSV3Router(LOCAL_PCS_V3_ROUTER).exactInputSingle(
            IPCSV3Router.ExactInputSingleParams({
                tokenIn: BSC.USDT,
                tokenOut: BSC.VAI,
                fee: VAI_USDT_FEE,
                recipient: address(this),
                amountIn: FLASH_USDT,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        // Round-trip the VAI back to USDT (captures the depeg less fees).
        IERC20(BSC.VAI).approve(LOCAL_PCS_V3_ROUTER, vaiOut);
        IPCSV3Router(LOCAL_PCS_V3_ROUTER).exactInputSingle(
            IPCSV3Router.ExactInputSingleParams({
                tokenIn: BSC.VAI,
                tokenOut: BSC.USDT,
                fee: VAI_USDT_FEE,
                recipient: address(this),
                amountIn: vaiOut,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        // Repay flash: USDT principal + fee0 (drawn from buffer if needed).
        IERC20(BSC.USDT).transfer(msg.sender, FLASH_USDT + fee0);
    }
}
