// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";

/// @dev Local PCS v3 SwapRouter interface (no deadline; selector 0x04e45aaf).
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

interface IPCSV3Factory {
    function getPool(address a, address b, uint24 fee) external view returns (address);
}

/// @title B07-06 Cross-fee-tier PCS v3 arb (USDT/WBNB 0.01% vs 0.05% vs 0.25%)
/// @notice The same USDT/WBNB pair has several live PCS v3 fee tiers, each with
///         its own sqrtPriceX96. When the tiers diverge a single-direction
///         round-trip across two of them can net a few bps after the SUM of
///         their fees + the flash fee. This is a same-protocol cross-tier arb
///         (no governance lag, only LP-positioning lag). Guarded: flash WBNB
///         from the high-mid tier, sell into it via the SwapRouter, buy back on
///         the low-mid tier; commit only if the round-trip nets positive, else
///         hold flat (net ~0, PASS).
contract B07_06_PcsV3CrossFeeTierArbTest is BSCStrategyBase, IPancakeV3FlashCallback {
    uint256 internal constant FORK_BLOCK = 45_000_000;

    address internal constant PCS_V3_SWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address internal constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;

    /// @dev WBNB flash notional. Small so micro-spreads dominate over impact.
    uint256 internal constant FLASH_NOTIONAL_WBNB = 5 ether;

    address internal _flashPool;
    uint24 internal _flashFee;
    address internal _swapPool; // resolved but routing is by fee tier
    uint24 internal _swapFee;
    bool internal _wbnbIsToken0OnFlash;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.WBNB);
        _trackToken(BSC.USDT);
    }

    function testStrategy_B07_06() public {
        uint24[3] memory tiers = [uint24(100), 500, 2500];
        address[3] memory pools;
        uint256[3] memory mids; // USDT per WBNB, 1e18

        for (uint256 i = 0; i < 3; i++) {
            pools[i] = IPCSV3Factory(PCS_V3_FACTORY).getPool(BSC.WBNB, BSC.USDT, tiers[i]);
            mids[i] = pools[i] == address(0) ? 0 : _midOf(pools[i]);
            emit log_named_uint("B07-06: mid_1e18", mids[i]);
        }

        // Pick the (high-mid, low-mid) ordered pair with the largest gap.
        uint256 bestBps = 0;
        uint256 hi;
        uint256 lo;
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = 0; j < 3; j++) {
                if (i == j || mids[i] == 0 || mids[j] == 0) continue;
                if (mids[i] <= mids[j]) continue;
                uint256 bps = ((mids[i] - mids[j]) * 10_000) / mids[j];
                if (bps > bestBps) {
                    bestBps = bps;
                    hi = i;
                    lo = j;
                }
            }
        }
        emit log_named_uint("B07-06: best_spread_bps", bestBps);

        _startPnL();

        if (bestBps == 0) {
            emit log_string("B07-06: skipped (no resolvable tier divergence)");
            _endPnL("B07-06: PCS v3 cross-fee-tier USDT/WBNB micro-spread arb (flat)");
            return;
        }

        _flashPool = pools[hi];
        _flashFee = tiers[hi];
        _swapPool = pools[lo];
        _swapFee = tiers[lo];
        _wbnbIsToken0OnFlash = IPancakeV3Pool(_flashPool).token0() == BSC.WBNB;

        try this._runArb() {
            emit log_string("B07-06: arb committed (positive net round-trip)");
        } catch {
            emit log_string("B07-06: no profitable edge after fees; holding flat");
        }

        _endPnL("B07-06: PCS v3 cross-fee-tier USDT/WBNB micro-spread arb");
    }

    function _runArb() external {
        require(msg.sender == address(this), "self only");
        IPancakeV3Pool pool = IPancakeV3Pool(_flashPool);
        if (_wbnbIsToken0OnFlash) {
            pool.flash(address(this), FLASH_NOTIONAL_WBNB, 0, "");
        } else {
            pool.flash(address(this), 0, FLASH_NOTIONAL_WBNB, "");
        }
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata) external override {
        require(msg.sender == _flashPool, "callback: wrong pool");
        uint256 owed = FLASH_NOTIONAL_WBNB + (_wbnbIsToken0OnFlash ? fee0 : fee1);

        // 1. Sell WBNB -> USDT on the HIGH-mid tier (the flash pool's tier).
        IERC20(BSC.WBNB).approve(PCS_V3_SWAP_ROUTER, FLASH_NOTIONAL_WBNB);
        uint256 usdtOut = IPCSV3Router(PCS_V3_SWAP_ROUTER).exactInputSingle(
            IPCSV3Router.ExactInputSingleParams({
                tokenIn: BSC.WBNB,
                tokenOut: BSC.USDT,
                fee: _flashFee,
                recipient: address(this),
                amountIn: FLASH_NOTIONAL_WBNB,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        // 2. Buy WBNB back on the LOW-mid tier.
        IERC20(BSC.USDT).approve(PCS_V3_SWAP_ROUTER, usdtOut);
        IPCSV3Router(PCS_V3_SWAP_ROUTER).exactInputSingle(
            IPCSV3Router.ExactInputSingleParams({
                tokenIn: BSC.USDT,
                tokenOut: BSC.WBNB,
                fee: _swapFee,
                recipient: address(this),
                amountIn: usdtOut,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        // 3. Guard + repay.
        uint256 wbnbBal = IERC20(BSC.WBNB).balanceOf(address(this));
        require(wbnbBal >= owed, "arb: unprofitable round-trip");
        IERC20(BSC.WBNB).transfer(_flashPool, owed);
    }

    function _midOf(address pool) internal view returns (uint256) {
        IPancakeV3Pool p = IPancakeV3Pool(pool);
        (uint160 sqrtP,,,,,,) = p.slot0();
        uint256 num = uint256(sqrtP) * uint256(sqrtP);
        uint256 raw = (num * 1e18) >> 192; // token1 per token0 (both 18-dec)
        return p.token0() == BSC.WBNB ? raw : (1e36 / raw);
    }
}
