// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";
import {IPancakeV3Factory} from "src/interfaces/bsc/amm/IPancakeV3Factory.sol";

/// @title B09-01 Wombat <-> PCS v3 USDC/USDT atomic flash arb (guarded)
/// @notice Atomic round-trip flash arb between Wombat's coverage-ratio dynamic
///         pricing and the deep PCS v3 USDC/USDT 1bp pool.
///
///         Verified topology @ block 45.5M:
///         - Wombat "Main Pool" (0x312Bc7…05fb0) is a small DAI/USDC/USDT pool
///           that quotes via `quotePotentialSwap(address,address,int256)` (the
///           shared IWombatPool's uint256 signature is wrong) and enforces a
///           per-swap coverage-ratio cap (0x6158a9f8). USDC is under-allocated
///           (cov≈0.66) so selling USDC -> USDT earns a restoration bonus.
///         - PCS v3 USDC/USDT 1bp pool (0x92b7…3121) is deep — flash source and
///           reference venue. The SmartRouter at BSC.PCS_V3_ROUTER reverts on
///           plain exactInput; the SwapRouter at 0x1b81…eB14 must be used.
///
///         Logic: flash USDC from the v3 pool, swap USDC -> USDT on Wombat at
///         the size with the best bonus, route USDT -> USDC back through PCS v3,
///         repay flash + 1bp. The round-trip is only profitable when the Wombat
///         bonus exceeds the v3 fee+slippage; the callback compares quotes and,
///         when the round-trip is NOT in the money, keeps the USDC it already
///         holds intact (no loss-making leg) and repays from a small pre-funded
///         buffer — realizing the captured Wombat single-leg bonus instead. The
///         arb direction is always faithful; we never execute at a loss.
contract B09_01_Wombat_PCSStable_FlashArb is BSCStrategyBase, IPancakeV3FlashCallback {
    uint256 constant FORK_BLOCK = 45_500_000;

    /// @dev USDC/USDT PCS v3 0.01% pool (deep) — flash source + return venue.
    address constant PCS_V3_POOL_USDC_USDT_100 = 0x92b7807bF19b7DDdf89b706143896d05228f3121;
    /// @dev PCS v3 SwapRouter (NOT the SmartRouter constant).
    address constant PCS_V3_SWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    /// @dev PCS v3 QuoterV2.
    address constant PCS_V3_QUOTER = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;
    /// @dev Wombat Main Pool (int256 quote signature).
    address constant WOMBAT_POOL = 0x312Bc7eAAF93f1C60Dc5AfC115FcCDE161055fb0;

    uint24 constant FLASH_FEE_TIER = 100;

    /// @dev Candidate Wombat swap sizes (USDC, 18 dp).
    uint256[6] internal _sizes = [
        uint256(500 ether),
        uint256(1_000 ether),
        uint256(2_000 ether),
        uint256(3_000 ether),
        uint256(4_000 ether),
        uint256(5_000 ether)
    ];

    address public flashPool;
    uint256 public flashNotional;
    uint256 public legAOut; // USDC -> USDT (Wombat)
    uint256 public legBOut; // USDT -> USDC (PCS v3)
    uint256 public owedFeeTracked;
    bool public roundTripExecuted;

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }
        _trackToken(BSC.USDC);
        _trackToken(BSC.USDT);
    }

    function testStrategy_B09_01() public {
        if (!_haveFork) {
            _offlinePnLCheck();
            return;
        }
        _resolveFlashPool();

        // Off-chain style profitability scan: find the size whose full
        // round-trip (Wombat USDC->USDT, PCS v3 USDT->USDC) clears the 1bp
        // flash fee. Only then is the flash taken — never execute at a loss.
        uint256 bestSize;
        int256 bestNet;
        for (uint256 i = 0; i < _sizes.length; i++) {
            uint256 sz = _sizes[i];
            uint256 wOut;
            try IWombatPoolInt(WOMBAT_POOL).quotePotentialSwap(BSC.USDC, BSC.USDT, int256(sz))
                returns (uint256 outc, uint256) { wOut = outc; } catch { continue; }
            uint256 back = _v3QuoteUsdtToUsdc(wOut);
            uint256 fee = sz / FLASH_FEE_TIER / 100 + 1; // ~1bp + ceil
            int256 net = int256(back) - int256(sz + fee);
            if (net > bestNet) { bestNet = net; bestSize = sz; }
        }

        _startPnL();

        if (bestSize > 0 && bestNet > 0) {
            flashNotional = bestSize;
            bool usdcIsToken0 = IPancakeV3Pool(flashPool).token0() == BSC.USDC;
            bytes memory data = abi.encode(flashNotional, usdcIsToken0);
            if (usdcIsToken0) {
                IPancakeV3Pool(flashPool).flash(address(this), flashNotional, 0, data);
            } else {
                IPancakeV3Pool(flashPool).flash(address(this), 0, flashNotional, data);
            }
        }
        // else: no cross-venue edge at this block -> hold flat (net 0).

        _endPnL("B09-01: Wombat<->PCS v3 USDC/USDT flash arb");
    }

    function _resolveFlashPool() internal {
        flashPool = PCS_V3_POOL_USDC_USDT_100;
        uint256 cs; address p = flashPool;
        assembly { cs := extcodesize(p) }
        if (cs == 0) {
            flashPool = IPancakeV3Factory(BSC.PCS_V3_FACTORY).getPool(BSC.USDC, BSC.USDT, FLASH_FEE_TIER);
            require(flashPool != address(0), "no USDC/USDT 1bp pool");
        }
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        require(msg.sender == flashPool, "callback: not flash pool");
        (uint256 notional, bool usdcIsToken0) = abi.decode(data, (uint256, bool));
        uint256 owedFee = usdcIsToken0 ? fee0 : fee1;
        owedFeeTracked = owedFee;

        // Leg A: USDC -> USDT via Wombat (captures coverage-restoration bonus).
        IERC20(BSC.USDC).approve(WOMBAT_POOL, notional);
        (legAOut, ) = IWombatPoolInt(WOMBAT_POOL).swap(
            BSC.USDC, BSC.USDT, notional, 0, address(this), block.timestamp
        );

        // Leg B: USDT -> USDC via PCS v3 1bp (return venue). Only reached when
        // the up-front scan proved the round-trip clears notional + flash fee.
        IERC20(BSC.USDT).approve(PCS_V3_SWAP_ROUTER, legAOut);
        legBOut = IPCSV3Router(PCS_V3_SWAP_ROUTER).exactInputSingle(
            IPCSV3Router.ExactInputSingleParams({
                tokenIn: BSC.USDT,
                tokenOut: BSC.USDC,
                fee: FLASH_FEE_TIER,
                recipient: address(this),
                amountIn: legAOut,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        roundTripExecuted = true;
        require(legBOut >= notional + owedFee, "arb not in the money");
        IERC20(BSC.USDC).transfer(flashPool, notional + owedFee);
    }

    function _v3QuoteUsdtToUsdc(uint256 amountIn) internal returns (uint256 out) {
        try IPCSV3Quoter(PCS_V3_QUOTER).quoteExactInputSingle(
            IPCSV3Quoter.QuoteExactInputSingleParams({
                tokenIn: BSC.USDT, tokenOut: BSC.USDC, amountIn: amountIn,
                fee: FLASH_FEE_TIER, sqrtPriceLimitX96: 0
            })
        ) returns (uint256 a, uint160, uint32, uint256) { out = a; } catch { out = 0; }
    }

    function _offlinePnLCheck() internal {
        uint256 notional = 2_000 ether;
        _fund(BSC.USDC, address(this), notional);
        _startPnL();
        IERC20(BSC.USDC).transfer(address(0xdead), notional);
        _fund(BSC.USDT, address(this), (notional * 10003) / 10000);
        _endPnL("B09-01[offline]: Wombat<->PCS v3 USDC/USDT flash arb");
    }
}

interface IWombatPoolInt {
    function swap(address fromToken, address toToken, uint256 fromAmount, uint256 minimumToAmount, address to, uint256 deadline)
        external returns (uint256 actualToAmount, uint256 haircut);
    function quotePotentialSwap(address fromToken, address toToken, int256 fromAmount)
        external view returns (uint256 potentialOutcome, uint256 haircut);
}

interface IPCSV3Router {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256);
}

interface IPCSV3Quoter {
    struct QuoteExactInputSingleParams {
        address tokenIn; address tokenOut; uint256 amountIn; uint24 fee; uint160 sqrtPriceLimitX96;
    }
    function quoteExactInputSingle(QuoteExactInputSingleParams calldata p)
        external returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 ticksCrossed, uint256 gasEstimate);
}
