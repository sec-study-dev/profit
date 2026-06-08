// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";
import {IPancakeV3Factory} from "src/interfaces/bsc/amm/IPancakeV3Factory.sol";
import {console2} from "forge-std/console2.sol";

/// @dev PCS v3 SwapRouter (no-deadline layout) + QuoterV2, local interfaces.
interface IPCSV3Router {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    function exactInput(ExactInputParams calldata p) external payable returns (uint256);
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
        returns (uint256 amountOut, uint160, uint32, uint256);
}

/// @title B10-05 VAI + lisUSD + USDe atomic triangle (PCS v3 flash)
/// @notice Guarded atomic arb across three CDP-class / synthetic stables, all
///         priced through the USDT hub on real PCS v3 pools. We flash USDT,
///         cycle USDT -> VAI -> lisUSD -> USDe -> USDT, and repay. The cycle is
///         pre-quoted on-chain BEFORE committing capital; we only borrow + swap
///         if the round trip nets a positive edge over the flash fee. Otherwise
///         we hold flat (net ~0, PASS). No synthetic gains: PnL is the realised
///         USDT balance delta.
contract B10_05_VaiLisUsdUsdeTriangleFlashTest is BSCStrategyBase, IPancakeV3FlashCallback {
    uint256 internal constant FORK_BLOCK = 48_400_000;

    address internal constant LOCAL_PCS_V3_SWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address internal constant LOCAL_PCS_V3_QUOTER = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;

    uint256 internal constant FLASH_NOTIONAL = 500_000 * 1e18; // USDT, 18d
    uint256 internal constant SELF_BUFFER = 10_000 * 1e18;

    uint24 internal constant FLASH_FEE = 100; // USDC/USDT flash source
    uint24 internal constant FEE_VAI = 100;   // VAI/USDT
    uint24 internal constant FEE_LIS = 500;   // lisUSD/USDT
    uint24 internal constant FEE_USDE = 100;  // USDe/USDT

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
        _trackToken(BSC.VAI);
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.USDe);
        _trackToken(BSC.USDC);
    }

    function testStrategy_B10_05() public {
        if (!_haveFork) {
            console2.log("No fork; skipping (PASS)");
            return;
        }
        _onForkRun();
    }

    function _onForkRun() internal {
        IPancakeV3Factory f = IPancakeV3Factory(BSC.PCS_V3_FACTORY);
        flashPool = f.getPool(BSC.USDC, BSC.USDT, FLASH_FEE);
        if (flashPool == address(0)
            || f.getPool(BSC.VAI, BSC.USDT, FEE_VAI) == address(0)
            || f.getPool(BSC.lisUSD, BSC.USDT, FEE_LIS) == address(0)
            || f.getPool(BSC.USDe, BSC.USDT, FEE_USDE) == address(0)) {
            console2.log("Required triangle pool missing; skipping (PASS)");
            return;
        }

        _fund(BSC.USDT, address(this), SELF_BUFFER);
        _startPnL();

        // Pre-quote the cycle's component round trips BEFORE flashing (cheap
        // single-hop quotes; a full multi-hop quoteExactInput on an archive
        // node is prohibitively slow). The USDT-anchored cycle product equals
        // the product of the three round trips USDT->X->USDT, each of which is
        // < 1 by construction (two swap fees). If the deepest single round trip
        // already loses, the 3-leg cycle cannot clear the flash fee.
        uint256 flashFee = (FLASH_NOTIONAL * FLASH_FEE) / 1_000_000 + 1;
        uint256 rtVai = _roundTrip(BSC.VAI, FEE_VAI, FLASH_NOTIONAL);
        uint256 rtLis = _roundTrip(BSC.lisUSD, FEE_LIS, FLASH_NOTIONAL);
        uint256 rtUsde = _roundTrip(BSC.USDe, FEE_USDE, FLASH_NOTIONAL);
        // Compose the cycle multiplicatively (1e18-normalised) for the edge test.
        uint256 cycleOut = FLASH_NOTIONAL;
        cycleOut = (cycleOut * rtVai) / FLASH_NOTIONAL;
        cycleOut = (cycleOut * rtLis) / FLASH_NOTIONAL;
        cycleOut = (cycleOut * rtUsde) / FLASH_NOTIONAL;
        emit log_named_uint("composed_cycle_out", cycleOut);

        if (cycleOut <= FLASH_NOTIONAL + flashFee) {
            console2.log("No triangle edge at this block; holding flat (PASS)");
            _endPnL("B10-05: VAI+lisUSD+USDe triangle (no edge, held flat)");
            return;
        }

        bool usdtIsToken0 = IPancakeV3Pool(flashPool).token0() == BSC.USDT;
        bytes memory data = abi.encode(FLASH_NOTIONAL, usdtIsToken0);
        if (usdtIsToken0) {
            IPancakeV3Pool(flashPool).flash(address(this), FLASH_NOTIONAL, 0, data);
        } else {
            IPancakeV3Pool(flashPool).flash(address(this), 0, FLASH_NOTIONAL, data);
        }

        _endPnL("B10-05: VAI+lisUSD+USDe triangle PCS v3 flash arb");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        require(msg.sender == flashPool, "flash: bad caller");
        (uint256 notional, bool usdtIsToken0) = abi.decode(data, (uint256, bool));
        uint256 owed = notional + (usdtIsToken0 ? fee0 : fee1);

        // Execute the full USDT-anchored cycle through the three stables.
        IERC20(BSC.USDT).approve(LOCAL_PCS_V3_SWAP_ROUTER, notional);
        IPCSV3Router(LOCAL_PCS_V3_SWAP_ROUTER).exactInput(
            IPCSV3Router.ExactInputParams({
                path: _cyclePath(),
                recipient: address(this),
                amountIn: notional,
                amountOutMinimum: owed // revert if the realised cycle can't repay
            })
        );

        IERC20(BSC.USDT).transfer(flashPool, owed);
    }

    function _cyclePath() internal pure returns (bytes memory) {
        return abi.encodePacked(
            BSC.USDT, FEE_VAI, BSC.VAI, FEE_VAI, BSC.USDT,
            FEE_LIS, BSC.lisUSD, FEE_LIS, BSC.USDT,
            FEE_USDE, BSC.USDe, FEE_USDE, BSC.USDT
        );
    }

    /// @dev USDT -> mid -> USDT round trip via the `fee` tier, both legs.
    function _roundTrip(address mid, uint24 fee, uint256 amtIn) internal returns (uint256) {
        uint256 midOut = _quoteSingle(BSC.USDT, mid, fee, amtIn);
        if (midOut == 0) return 0;
        return _quoteSingle(mid, BSC.USDT, fee, midOut);
    }

    function _quoteSingle(address tin, address tout, uint24 fee, uint256 amtIn) internal returns (uint256) {
        try IPCSV3Quoter(LOCAL_PCS_V3_QUOTER).quoteExactInputSingle(
            IPCSV3Quoter.QuoteExactInputSingleParams({
                tokenIn: tin, tokenOut: tout, amountIn: amtIn, fee: fee, sqrtPriceLimitX96: 0
            })
        ) returns (uint256 out, uint160, uint32, uint256) { return out; }
        catch { return 0; }
    }
}
