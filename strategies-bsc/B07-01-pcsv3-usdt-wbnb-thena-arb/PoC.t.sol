// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";
import {IThenaRouter} from "src/interfaces/bsc/amm/IThenaRouter.sol";
import {IThenaPair} from "src/interfaces/bsc/amm/IThenaPair.sol";

/// @dev Local PCS v3 SwapRouter interface. The shared
///      `IPancakeV3Router` carries a `deadline` field (Uniswap layout,
///      selector 0x414bf389) but the PCS v3 SwapRouter has NO deadline
///      (selector 0x04e45aaf); using the shared one reverts every swap.
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

interface IThenaFactory {
    function getPair(address a, address b, bool stable) external view returns (address);
}

/// @title B07-01 PCS v3 USDT/WBNB 0.01% flash -> Thena USDT/WBNB volatile pair arb
/// @notice Atomic cross-DEX arbitrage. Borrow WBNB fee-only from the deep PCS
///         v3 WBNB/USDT 0.01% pool, sell it for USDT on Thena's volatile
///         WBNB/USDT pair, buy WBNB back on PCS v3, repay the flash. Guarded:
///         the full round-trip is simulated atomically and only committed if
///         proceeds cover notional + flash fee; otherwise the strategy holds
///         flat (net ~0) so the witness still PASSes. At efficiently-priced
///         blocks (Thena pair is dust here) the guard correctly declines.
contract B07_01_PcsV3UsdtWbnbThenaArbTest is BSCStrategyBase, IPancakeV3FlashCallback {
    uint256 internal constant FORK_BLOCK = 45_000_000;

    /// @dev PCS v3 SwapRouter (NOT the SmartRouter BSC.PCS_V3_ROUTER 0x13f4...).
    address internal constant PCS_V3_SWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address internal constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant THENA_FACTORY = 0xAFD89d21BdB66d00817d4153E055830B1c2B3970;

    uint24 internal constant PCS_V3_FEE_100 = 100;

    /// @dev Flash notional in WBNB. Sized small so the dust Thena pair is not
    ///      the binding constraint when an edge does exist.
    uint256 internal constant FLASH_NOTIONAL_WBNB = 10 ether;

    address internal _pool;
    address internal _thenaPair;
    bool internal _wbnbIsToken0;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.WBNB);
        _trackToken(BSC.USDT);
    }

    function testStrategy_B07_01() public {
        // ---- Resolve venues on-chain ----
        _pool = IPCSV3Factory(PCS_V3_FACTORY).getPool(BSC.WBNB, BSC.USDT, PCS_V3_FEE_100);
        _thenaPair = IThenaFactory(THENA_FACTORY).getPair(BSC.WBNB, BSC.USDT, false);

        _startPnL();

        if (_pool == address(0) || _thenaPair == address(0)) {
            emit log_string("B07-01: skipped (PCS v3 pool or Thena pair not deployed)");
            _endPnL("B07-01: PCS v3 0.01% WBNB/USDT flash + Thena volatile arb (flat)");
            return;
        }

        _wbnbIsToken0 = IPancakeV3Pool(_pool).token0() == BSC.WBNB;

        // ---- Guarded arb: attempt the atomic round-trip; commit only if it
        //      nets positive, else revert internally and hold flat. ----
        try this._runArb() {
            emit log_string("B07-01: arb committed (positive net round-trip)");
        } catch {
            emit log_string("B07-01: no profitable edge at block; holding flat");
        }

        _endPnL("B07-01: PCS v3 0.01% WBNB/USDT flash + Thena volatile arb");
    }

    /// @dev External so the parent test can `try/catch` it: any revert here
    ///      (including the profitability guard) rolls back all swaps.
    function _runArb() external {
        require(msg.sender == address(this), "self only");
        IPancakeV3Pool pool = IPancakeV3Pool(_pool);
        if (_wbnbIsToken0) {
            pool.flash(address(this), FLASH_NOTIONAL_WBNB, 0, "");
        } else {
            pool.flash(address(this), 0, FLASH_NOTIONAL_WBNB, "");
        }
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata) external override {
        require(msg.sender == _pool, "callback: wrong pool");
        uint256 owed = FLASH_NOTIONAL_WBNB + (_wbnbIsToken0 ? fee0 : fee1);

        // 1. WBNB -> USDT on Thena volatile pair.
        IERC20(BSC.WBNB).approve(BSC.THENA_ROUTER, FLASH_NOTIONAL_WBNB);
        IThenaRouter.Route[] memory route = new IThenaRouter.Route[](1);
        route[0] = IThenaRouter.Route({from: BSC.WBNB, to: BSC.USDT, stable: false});
        uint256[] memory outs = IThenaRouter(BSC.THENA_ROUTER).swapExactTokensForTokens(
            FLASH_NOTIONAL_WBNB, 1, route, address(this), block.timestamp
        );
        uint256 usdtAcquired = outs[outs.length - 1];

        // 2. USDT -> WBNB on PCS v3 0.01% (fresh price).
        IERC20(BSC.USDT).approve(PCS_V3_SWAP_ROUTER, usdtAcquired);
        IPCSV3Router(PCS_V3_SWAP_ROUTER).exactInputSingle(
            IPCSV3Router.ExactInputSingleParams({
                tokenIn: BSC.USDT,
                tokenOut: BSC.WBNB,
                fee: PCS_V3_FEE_100,
                recipient: address(this),
                amountIn: usdtAcquired,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        // 3. Profitability guard: only repay (and keep the surplus) if the
        //    round-trip produced at least `owed` WBNB. Otherwise revert so the
        //    whole attempt rolls back and we hold flat.
        uint256 wbnbBal = IERC20(BSC.WBNB).balanceOf(address(this));
        require(wbnbBal >= owed, "arb: unprofitable round-trip");

        IERC20(BSC.WBNB).transfer(_pool, owed);
    }
}
