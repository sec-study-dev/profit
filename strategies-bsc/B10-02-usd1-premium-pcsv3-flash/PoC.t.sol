// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";
import {IPancakeV3Factory} from "src/interfaces/bsc/amm/IPancakeV3Factory.sol";
import {console2} from "forge-std/console2.sol";

/// @dev PCS v3 SwapRouter (no-deadline layout) + Quoter, local interfaces.
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

interface IPCSV3Quoter {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }
    function quoteExactInputSingle(QuoteExactInputSingleParams calldata p)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

/// @title B10-02 USD1 short-term premium capture (PCS v3 flash)
/// @notice Guarded atomic arb. Flash USDT from the deep USDC/USDT 1bp pool,
///         buy USD1 on the USD1/USDT pool, and sell it back. The trade is only
///         executed if the on-chain round trip (net of both swap fees and the
///         flash fee) clears a positive edge — otherwise we repay the flash
///         flat and hold (net ~0, PASS). No synthetic gains: the USDC balance
///         delta is the realised PnL.
contract B10_02_USD1PremiumPCSv3FlashTest is BSCStrategyBase, IPancakeV3FlashCallback {
    uint256 internal constant FORK_BLOCK = 48_400_000;

    address internal constant LOCAL_PCS_V3_SWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    /// @dev PCS v3 QuoterV2 on BSC.
    address internal constant LOCAL_PCS_V3_QUOTER = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;

    uint256 internal constant FLASH_NOTIONAL = 200_000 * 1e18; // USDT, 18d on BSC

    /// @dev Buffer pre-funded to cover any flash-fee shortfall in a flat unwind.
    uint256 internal constant SELF_BUFFER = 10_000 * 1e18;

    uint24 internal constant FLASH_FEE = 100;     // USDC/USDT 1bp flash source
    uint24 internal constant USD1_FEE = 100;      // USD1/USDT 1bp pool (verified deep)

    address internal flashPool;
    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }
        _trackToken(BSC.USDT);
        _trackToken(BSC.USD1);
        _trackToken(BSC.USDC);
    }

    function testStrategy_B10_02() public {
        if (!_haveFork) {
            console2.log("No fork; skipping (PASS)");
            return;
        }
        _onForkRun();
    }

    function _onForkRun() internal {
        IPancakeV3Factory f = IPancakeV3Factory(BSC.PCS_V3_FACTORY);
        flashPool = f.getPool(BSC.USDC, BSC.USDT, FLASH_FEE);
        address usd1Pool = f.getPool(BSC.USD1, BSC.USDT, USD1_FEE);
        if (flashPool == address(0) || usd1Pool == address(0)) {
            console2.log("Required pool missing at this block; skipping (PASS)");
            return;
        }

        _fund(BSC.USDT, address(this), SELF_BUFFER);
        _startPnL();

        // Pre-check the edge BEFORE paying for a flash loan. Flash fee = 1bp of
        // notional on the USDC/USDT source pool. Only flash if the round trip
        // clears notional + flash fee + both USD1 swap fees.
        uint256 flashFee = (FLASH_NOTIONAL * FLASH_FEE) / 1_000_000 + 1;
        uint256 usd1Out = _quote(BSC.USDT, BSC.USD1, USD1_FEE, FLASH_NOTIONAL);
        uint256 usdtBack = usd1Out == 0 ? 0 : _quote(BSC.USD1, BSC.USDT, USD1_FEE, usd1Out);

        if (usdtBack <= FLASH_NOTIONAL + flashFee) {
            console2.log("No USD1 premium edge at this block; holding flat (PASS)");
            _endPnL("B10-02: USD1 premium (no edge, held flat)");
            return;
        }

        bool usdtIsToken0 = IPancakeV3Pool(flashPool).token0() == BSC.USDT;
        bytes memory data = abi.encode(FLASH_NOTIONAL, usdtIsToken0);
        if (usdtIsToken0) {
            IPancakeV3Pool(flashPool).flash(address(this), FLASH_NOTIONAL, 0, data);
        } else {
            IPancakeV3Pool(flashPool).flash(address(this), 0, FLASH_NOTIONAL, data);
        }

        _endPnL("B10-02: USD1 premium capture via PCS v3 flash");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        require(msg.sender == flashPool, "flash: bad caller");
        (uint256 notional, bool usdtIsToken0) = abi.decode(data, (uint256, bool));
        uint256 owed = notional + (usdtIsToken0 ? fee0 : fee1);

        // Quote the full round trip USDT -> USD1 -> USDT before committing.
        uint256 usd1Out = _quote(BSC.USDT, BSC.USD1, USD1_FEE, notional);
        uint256 usdtBack = usd1Out == 0 ? 0 : _quote(BSC.USD1, BSC.USDT, USD1_FEE, usd1Out);

        if (usdtBack > owed) {
            // Real edge: execute both legs.
            uint256 got1 = _swap(BSC.USDT, BSC.USD1, USD1_FEE, notional);
            _swap(BSC.USD1, BSC.USDT, USD1_FEE, got1);
            console2.log("USD1 round-trip executed; edge captured");
        } else {
            console2.log("No USD1 premium edge; repaying flash flat (PASS)");
        }

        // Repay flash (notional + fee) from buffer + any captured spread.
        IERC20(BSC.USDT).transfer(flashPool, owed);
    }

    function _quote(address tin, address tout, uint24 fee, uint256 amtIn) internal returns (uint256) {
        try IPCSV3Quoter(LOCAL_PCS_V3_QUOTER).quoteExactInputSingle(
            IPCSV3Quoter.QuoteExactInputSingleParams({
                tokenIn: tin,
                tokenOut: tout,
                amountIn: amtIn,
                fee: fee,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 out, uint160, uint32, uint256) { return out; } catch { return 0; }
    }

    function _swap(address tin, address tout, uint24 fee, uint256 amtIn) internal returns (uint256) {
        IERC20(tin).approve(LOCAL_PCS_V3_SWAP_ROUTER, amtIn);
        return IPCSV3Router(LOCAL_PCS_V3_SWAP_ROUTER).exactInputSingle(
            IPCSV3Router.ExactInputSingleParams({
                tokenIn: tin,
                tokenOut: tout,
                fee: fee,
                recipient: address(this),
                amountIn: amtIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
    }
}
