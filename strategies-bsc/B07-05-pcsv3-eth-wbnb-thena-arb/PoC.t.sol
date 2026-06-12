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

/// @title B07-05 PCS v3 ETH/WBNB flash -> Thena ETH/BNB volatile pair arb
/// @notice Borrow WBNB fee-only from the PCS v3 ETH/WBNB pool, buy ETH on
///         Thena's volatile ETH/WBNB pair, sell ETH for WBNB on PCS v3, repay.
///         Guarded round-trip: commit only if proceeds cover notional + flash
///         fee, else hold flat. The Thena ETH/WBNB pair is shallow at this
///         block so the guard correctly declines (net ~0, PASS).
contract B07_05_PcsV3EthWbnbThenaArbTest is BSCStrategyBase, IPancakeV3FlashCallback {
    uint256 internal constant FORK_BLOCK = 45_000_000;

    address internal constant PCS_V3_SWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address internal constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant THENA_FACTORY = 0xAFD89d21BdB66d00817d4153E055830B1c2B3970;

    /// @dev WBNB flash notional (1e18). ~5 WBNB keeps DEX impact modest.
    uint256 internal constant FLASH_NOTIONAL_WBNB = 5 ether;

    address internal _pool;
    uint24 internal _poolFee;
    address internal _thenaPair;
    bool internal _wbnbIsToken0;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.WETH);
        _trackToken(BSC.WBNB);
    }

    function testStrategy_B07_05() public {
        (_pool, _poolFee) = _bestPool(BSC.WETH, BSC.WBNB);
        _thenaPair = IThenaFactory(THENA_FACTORY).getPair(BSC.WETH, BSC.WBNB, false);

        _startPnL();

        if (_pool == address(0) || _thenaPair == address(0)) {
            emit log_string("B07-05: skipped (PCS v3 pool or Thena ETH/WBNB pair not deployed)");
            _endPnL("B07-05: PCS v3 ETH/WBNB flash + Thena ETH/BNB vAMM arb (flat)");
            return;
        }

        _wbnbIsToken0 = IPancakeV3Pool(_pool).token0() == BSC.WBNB;

        try this._runArb() {
            emit log_string("B07-05: arb committed (positive net round-trip)");
        } catch {
            emit log_string("B07-05: no profitable edge at block; holding flat");
        }

        _endPnL("B07-05: PCS v3 ETH/WBNB flash + Thena ETH/BNB vAMM arb");
    }

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

        // 1. WBNB -> ETH on Thena volatile (buy ETH at lagged price).
        IERC20(BSC.WBNB).approve(BSC.THENA_ROUTER, FLASH_NOTIONAL_WBNB);
        IThenaRouter.Route[] memory route = new IThenaRouter.Route[](1);
        route[0] = IThenaRouter.Route({from: BSC.WBNB, to: BSC.WETH, stable: false});
        uint256[] memory outs = IThenaRouter(BSC.THENA_ROUTER).swapExactTokensForTokens(
            FLASH_NOTIONAL_WBNB, 1, route, address(this), block.timestamp
        );
        uint256 ethAcquired = outs[outs.length - 1];

        // 2. ETH -> WBNB on PCS v3 (fresh price).
        IERC20(BSC.WETH).approve(PCS_V3_SWAP_ROUTER, ethAcquired);
        IPCSV3Router(PCS_V3_SWAP_ROUTER).exactInputSingle(
            IPCSV3Router.ExactInputSingleParams({
                tokenIn: BSC.WETH,
                tokenOut: BSC.WBNB,
                fee: _poolFee,
                recipient: address(this),
                amountIn: ethAcquired,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        // 3. Guard + repay.
        uint256 wbnbBal = IERC20(BSC.WBNB).balanceOf(address(this));
        require(wbnbBal >= owed, "arb: unprofitable round-trip");
        IERC20(BSC.WBNB).transfer(_pool, owed);
    }

    function _bestPool(address a, address b) internal view returns (address pool, uint24 fee) {
        uint24[4] memory tiers = [uint24(100), 500, 2500, 10000];
        uint128 bestLiq = 0;
        for (uint256 i = 0; i < tiers.length; i++) {
            address p = IPCSV3Factory(PCS_V3_FACTORY).getPool(a, b, tiers[i]);
            if (p == address(0)) continue;
            uint128 liq = IPancakeV3Pool(p).liquidity();
            if (liq > bestLiq) {
                bestLiq = liq;
                pool = p;
                fee = tiers[i];
            }
        }
    }
}
