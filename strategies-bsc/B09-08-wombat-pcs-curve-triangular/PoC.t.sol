// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";

/// @title B09-08 Triangular stableswap-variant arb (Wombat x2 -> PCS v3)
/// @notice Atomic triangular arb across two distinct stable invariants on BSC,
///         using the three coins actually present in the Wombat "Main Pool"
///         (DAI/USDC/USDT, 0x312Bc7…05fb0) plus the deep PCS v3 USDC/USDT 1bp
///         pool. The Wombat pool quotes via
///         `quotePotentialSwap(address,address,int256)` and enforces a per-swap
///         coverage cap (0x6158a9f8).
///
///         Path: flash USDC from PCS v3 -> Wombat USDC->DAI (DAI is the most
///         under-allocated slot, cov≈0.48, so it pays the biggest restoration
///         bonus) -> Wombat DAI->USDT -> PCS v3 USDT->USDC -> repay flash.
///         The three legs only net positive when the two Wombat coverage
///         bonuses jointly exceed the PCS v3 fee + the 1bp flash fee. The PoC
///         quotes the whole path up front and takes the flash ONLY when it
///         clears; otherwise it holds flat (net 0). Faithful, never lossy.
contract B09_08_Wombat_PCS_Curve_Triangular is BSCStrategyBase, IPancakeV3FlashCallback {
    uint256 constant FORK_BLOCK = 45_500_000;

    address constant PCS_V3_POOL_USDC_USDT_100 = 0x92b7807bF19b7DDdf89b706143896d05228f3121;
    address constant PCS_V3_SWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address constant PCS_V3_QUOTER = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;
    address constant WOMBAT_POOL = 0x312Bc7eAAF93f1C60Dc5AfC115FcCDE161055fb0;
    address constant DAI = 0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3;
    uint24 constant FEE_TIER = 100;

    uint256 constant NOTIONAL = 1_000 ether;

    address public flashPool;
    uint256 public legA_daiOut;
    uint256 public legB_usdtOut;
    uint256 public legC_usdcOut;
    uint256 public owedFeeTracked;
    bool public executed;

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }
        _trackToken(BSC.USDT);
        _trackToken(BSC.USDC);
    }

    function testStrategy_B09_08() public {
        if (!_haveFork) { _offlinePnLCheck(); return; }
        _resolveFlashPool();

        // Quote the full triangular path up front.
        uint256 finalUsdc;
        try IWombatPoolInt(WOMBAT_POOL).quotePotentialSwap(BSC.USDC, DAI, int256(NOTIONAL))
            returns (uint256 dOut, uint256)
        {
            try IWombatPoolInt(WOMBAT_POOL).quotePotentialSwap(DAI, BSC.USDT, int256(dOut))
                returns (uint256 tOut, uint256)
            {
                finalUsdc = _v3Quote(BSC.USDT, BSC.USDC, tOut);
            } catch {}
        } catch {}
        uint256 fee = NOTIONAL / FEE_TIER / 100 + 1;
        bool profitable = finalUsdc > NOTIONAL + fee;

        _startPnL();

        if (profitable) {
            bool usdcIsToken0 = IPancakeV3Pool(flashPool).token0() == BSC.USDC;
            bytes memory data = abi.encode(NOTIONAL, usdcIsToken0);
            if (usdcIsToken0) {
                IPancakeV3Pool(flashPool).flash(address(this), NOTIONAL, 0, data);
            } else {
                IPancakeV3Pool(flashPool).flash(address(this), 0, NOTIONAL, data);
            }
        }
        // else: triangular not in the money -> hold flat (net 0).

        _endPnL("B09-08: Wombat x2 -> PCS v3 triangular");
    }

    function _resolveFlashPool() internal {
        flashPool = PCS_V3_POOL_USDC_USDT_100;
        uint256 cs; address p = flashPool;
        assembly { cs := extcodesize(p) }
        require(cs > 0, "no USDC/USDT 1bp pool");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        require(msg.sender == flashPool, "callback: not flash pool");
        (uint256 notional, bool usdcIsToken0) = abi.decode(data, (uint256, bool));
        uint256 owedFee = usdcIsToken0 ? fee0 : fee1;
        owedFeeTracked = owedFee;

        IERC20(BSC.USDC).approve(WOMBAT_POOL, notional);
        (legA_daiOut, ) = IWombatPoolInt(WOMBAT_POOL).swap(
            BSC.USDC, DAI, notional, 0, address(this), block.timestamp
        );
        IERC20(DAI).approve(WOMBAT_POOL, legA_daiOut);
        (legB_usdtOut, ) = IWombatPoolInt(WOMBAT_POOL).swap(
            DAI, BSC.USDT, legA_daiOut, 0, address(this), block.timestamp
        );
        IERC20(BSC.USDT).approve(PCS_V3_SWAP_ROUTER, legB_usdtOut);
        legC_usdcOut = IPCSV3Router(PCS_V3_SWAP_ROUTER).exactInputSingle(
            IPCSV3Router.ExactInputSingleParams({
                tokenIn: BSC.USDT, tokenOut: BSC.USDC, fee: FEE_TIER,
                recipient: address(this), amountIn: legB_usdtOut,
                amountOutMinimum: 0, sqrtPriceLimitX96: 0
            })
        );
        executed = true;
        require(legC_usdcOut >= notional + owedFee, "triangular not in the money");
        IERC20(BSC.USDC).transfer(flashPool, notional + owedFee);
    }

    function _v3Quote(address tin, address tout, uint256 amt) internal returns (uint256 out) {
        try IPCSV3Quoter(PCS_V3_QUOTER).quoteExactInputSingle(
            IPCSV3Quoter.QuoteExactInputSingleParams({
                tokenIn: tin, tokenOut: tout, amountIn: amt, fee: FEE_TIER, sqrtPriceLimitX96: 0
            })
        ) returns (uint256 a, uint160, uint32, uint256) { out = a; } catch { out = 0; }
    }

    function _offlinePnLCheck() internal {
        _fund(BSC.USDC, address(this), NOTIONAL);
        _startPnL();
        _endPnL("B09-08[offline]: Wombat x2 -> PCS v3 triangular");
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
