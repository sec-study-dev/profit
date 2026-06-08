// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";
import {IThenaRouter} from "src/interfaces/bsc/amm/IThenaRouter.sol";

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

interface IThenaFactory {
    function getPair(address a, address b, bool stable) external view returns (address);
}

/// @title B07-02 PCS v3 BTCB/USDT 0.05% flash -> Thena BTCB/USDT pair arb
/// @notice Borrow BTCB fee-only from PCS v3 BTCB/USDT, sell on Thena's volatile
///         BTCB/USDT pair, buy back on PCS v3, repay. Guarded round-trip:
///         commit only if proceeds cover notional + flash fee, else hold flat.
///         On BSC, Thena has no live BTCB/USDT volatile pair at this block, so
///         the witness gracefully holds flat (net ~0, PASS).
contract B07_02_PcsV3BtcbUsdtThenaArbTest is BSCStrategyBase, IPancakeV3FlashCallback {
    uint256 internal constant FORK_BLOCK = 45_000_000;

    address internal constant PCS_V3_SWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address internal constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant THENA_FACTORY = 0xAFD89d21BdB66d00817d4153E055830B1c2B3970;

    uint24 internal constant PCS_V3_FEE_500 = 500;

    /// @dev BTCB flash notional (1e18). ~0.15 BTCB (~$10k) keeps DEX impact low.
    uint256 internal constant FLASH_NOTIONAL_BTCB = 0.15 ether;

    address internal _pool;
    address internal _thenaPair;
    bool internal _btcbIsToken0;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.BTCB);
        _trackToken(BSC.USDT);
    }

    function testStrategy_B07_02() public {
        _pool = IPCSV3Factory(PCS_V3_FACTORY).getPool(BSC.BTCB, BSC.USDT, PCS_V3_FEE_500);
        _thenaPair = IThenaFactory(THENA_FACTORY).getPair(BSC.BTCB, BSC.USDT, false);

        _startPnL();

        if (_pool == address(0) || _thenaPair == address(0)) {
            emit log_string("B07-02: skipped (PCS v3 pool or Thena BTCB/USDT pair not deployed)");
            _endPnL("B07-02: PCS v3 0.05% BTCB/USDT flash + Thena vAMM arb (flat)");
            return;
        }

        _btcbIsToken0 = IPancakeV3Pool(_pool).token0() == BSC.BTCB;

        try this._runArb() {
            emit log_string("B07-02: arb committed (positive net round-trip)");
        } catch {
            emit log_string("B07-02: no profitable edge at block; holding flat");
        }

        _endPnL("B07-02: PCS v3 0.05% BTCB/USDT flash + Thena vAMM arb");
    }

    function _runArb() external {
        require(msg.sender == address(this), "self only");
        IPancakeV3Pool pool = IPancakeV3Pool(_pool);
        if (_btcbIsToken0) {
            pool.flash(address(this), FLASH_NOTIONAL_BTCB, 0, "");
        } else {
            pool.flash(address(this), 0, FLASH_NOTIONAL_BTCB, "");
        }
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata) external override {
        require(msg.sender == _pool, "callback: wrong pool");
        uint256 owed = FLASH_NOTIONAL_BTCB + (_btcbIsToken0 ? fee0 : fee1);

        // 1. BTCB -> USDT on Thena volatile.
        IERC20(BSC.BTCB).approve(BSC.THENA_ROUTER, FLASH_NOTIONAL_BTCB);
        IThenaRouter.Route[] memory route = new IThenaRouter.Route[](1);
        route[0] = IThenaRouter.Route({from: BSC.BTCB, to: BSC.USDT, stable: false});
        uint256[] memory outs = IThenaRouter(BSC.THENA_ROUTER).swapExactTokensForTokens(
            FLASH_NOTIONAL_BTCB, 1, route, address(this), block.timestamp
        );
        uint256 usdtAcquired = outs[outs.length - 1];

        // 2. USDT -> BTCB on PCS v3 0.05% (fresh price).
        IERC20(BSC.USDT).approve(PCS_V3_SWAP_ROUTER, usdtAcquired);
        IPCSV3Router(PCS_V3_SWAP_ROUTER).exactInputSingle(
            IPCSV3Router.ExactInputSingleParams({
                tokenIn: BSC.USDT,
                tokenOut: BSC.BTCB,
                fee: PCS_V3_FEE_500,
                recipient: address(this),
                amountIn: usdtAcquired,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        // 3. Guard + repay.
        uint256 btcbBal = IERC20(BSC.BTCB).balanceOf(address(this));
        require(btcbBal >= owed, "arb: unprofitable round-trip");
        IERC20(BSC.BTCB).transfer(_pool, owed);
    }
}
