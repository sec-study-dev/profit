// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

// ---------------------------------------------------------------------------
// Inlined interfaces - BSC.sol has pre-existing checksum errors. We inline
// addresses + ABIs.
// ---------------------------------------------------------------------------

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IPancakeV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IPancakeV3Pool {
    function liquidity() external view returns (uint128);
}

/// @dev PCS v3 SwapRouter 0x1b81D678 uses the WITH-deadline struct on this fork
///      (verified: deadline-less selector reverts with empty data).
interface IPCSV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256);
}

interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }
    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160, uint32, uint256);
}

abstract contract BSCStrategyBase is Test {
    address[] internal _tracked;
    mapping(address => bool) internal _isTracked;
    mapping(address => uint256) internal _balStart;
    mapping(address => uint256) internal _priceE8;
    uint256 internal _bnbStart;
    uint256 internal _gasStart;
    uint256 internal _gasPriceSnap;
    uint256 internal _bnbUsdE8 = 600e8;

    function _fork(uint256 blk) internal {
        vm.createSelectFork(vm.envString("BSC_RPC_URL"), blk);
    }

    function _fund(address token, address to, uint256 amount) internal {
        deal(token, to, amount);
    }

    function _trackToken(address t) internal {
        if (t == address(0) || _isTracked[t]) return;
        _isTracked[t] = true;
        _tracked.push(t);
    }

    function _setOraclePrice(address t, uint256 priceE8) internal {
        _priceE8[t] = priceE8;
    }

    function _startPnL() internal {
        _bnbStart = address(this).balance;
        for (uint256 i = 0; i < _tracked.length; i++) {
            _balStart[_tracked[i]] = IERC20(_tracked[i]).balanceOf(address(this));
        }
        _gasPriceSnap = tx.gasprice;
        _gasStart = gasleft();
    }

    function _endPnL(string memory label) internal {
        uint256 gasUsed = _gasStart > gasleft() ? _gasStart - gasleft() : 0;
        int256 bnbDelta = int256(address(this).balance) - int256(_bnbStart);
        int256 pnlE6 = _scaled(bnbDelta, _bnbUsdE8, 1e20);
        for (uint256 i = 0; i < _tracked.length; i++) {
            address tk = _tracked[i];
            uint256 p = _priceE8[tk];
            if (p == 0) continue;
            int256 bal = int256(IERC20(tk).balanceOf(address(this)));
            int256 prev = int256(_balStart[tk]);
            int256 delta = bal - prev;
            uint256 scale = 10 ** _decimals(tk) * 1e2;
            pnlE6 += _scaled(delta, p, scale);
        }
        uint256 gasUsdE6 = (_bnbUsdE8 > 0 && _gasPriceSnap > 0)
            ? (gasUsed * _gasPriceSnap * _bnbUsdE8) / 1e26
            : 0;
        int256 netE6 = pnlE6 - int256(gasUsdE6);
        console2.log("==== STRATEGY", label, "====");
        console2.log("pnl_usd=", pnlE6);
        console2.log("gas_usd=", gasUsdE6);
        console2.log("net_usd=", netE6);
        console2.log("========================");
    }

    function _decimals(address t) internal view returns (uint256) {
        try IERC20(t).decimals() returns (uint8 d) { return d; } catch { return 18; }
    }

    function _scaled(int256 d, uint256 m, uint256 div) internal pure returns (int256) {
        if (d == 0 || m == 0 || div == 0) return 0;
        if (d >= 0) return int256((uint256(d) * m) / div);
        return -int256((uint256(-d) * m) / div);
    }

    function _hasCode(address a) internal view returns (bool) {
        uint256 cs;
        assembly { cs := extcodesize(a) }
        return cs > 0;
    }
}

/// @title B13-07 deBridge solvBTC BSC <-> Solana spread arb
/// @notice Thesis: solvBTC's price can dislocate between BSC and Solana; you buy
///         cheap solvBTC on BSC, deBridge (DLN) it to Solana, sell into the
///         premium, and re-bridge. The deBridge settlement (DLN order filled by
///         an off-chain solver on Solana) CANNOT execute on a single BSC fork.
/// @dev    The FORKABLE on-BSC leg is the BTCB<->solvBTC swap on the real PCS v3
///         pool (deep on the 0.05% tier). We read the live BTCB<->solvBTC spread
///         with the QuoterV2 and run a GUARDED local round-trip arb: only swap
///         if BTCB->solvBTC->BTCB nets positive (a real on-BSC mispricing);
///         otherwise hold flat (net ~0). The deBridge/Solana leg is a
///         code-guarded no-op. No fabricated cross-chain profit.
contract B13_07_deBridge_solvBTC_BSC_SOL is BSCStrategyBase {
    address constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    address constant solvBTC = 0x4aae823a6a0b376De6A78e74eCC5b079d38cBCf7;
    address constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant PCS_V3_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address constant QUOTER_V2 = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;

    /// @notice deBridge DLN source on BSC - not wired in this PoC (off-fork).
    address constant DLN_SOURCE = address(0);

    uint256 constant FORK_BLOCK = 46_000_000;
    uint24 constant SWAP_FEE_TIER = 500; // deep BTCB/solvBTC tier
    uint256 constant NOTIONAL = 1 ether; // 1 BTCB (18 dec)

    bool internal _haveFork;
    address public pool;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }
        _trackToken(BTCB);
        _trackToken(solvBTC);
        _setOraclePrice(BTCB, 65_000e8);
        _setOraclePrice(solvBTC, 65_000e8);
    }

    function testStrategy_B13_07() public {
        if (!_haveFork) {
            _startPnL();
            console2.log("B13-07: no fork -> graceful hold");
            _endPnL("B13-07: deBridge solvBTC [no-fork hold]");
            return;
        }

        require(_hasCode(BTCB) && _hasCode(solvBTC), "BTC tokens missing");
        pool = IPancakeV3Factory(PCS_V3_FACTORY).getPool(BTCB, solvBTC, SWAP_FEE_TIER);
        require(pool != address(0) && _hasCode(pool), "BTCB/solvBTC pool missing");

        // Read the local round-trip: BTCB -> solvBTC -> BTCB.
        (uint256 solvOut,,,) = IQuoterV2(QUOTER_V2).quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: BTCB, tokenOut: solvBTC, amountIn: NOTIONAL, fee: SWAP_FEE_TIER, sqrtPriceLimitX96: 0
            })
        );
        (uint256 btcbBack,,,) = IQuoterV2(QUOTER_V2).quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: solvBTC, tokenOut: BTCB, amountIn: solvOut, fee: SWAP_FEE_TIER, sqrtPriceLimitX96: 0
            })
        );
        console2.log("B13-07: BTCB in:", NOTIONAL);
        console2.log("B13-07: solvBTC out:", solvOut);
        console2.log("B13-07: BTCB round-trip back:", btcbBack);

        _fund(BTCB, address(this), NOTIONAL);
        _startPnL();

        console2.log("B13-07: deBridge/Solana settlement leg is off-fork -> code-guarded no-op");

        if (btcbBack <= NOTIONAL) {
            // No local mispricing (round-trip loses the swap fees) -> hold flat.
            console2.log("B13-07: no on-BSC BTCB/solvBTC arb edge -> HOLD FLAT");
            _endPnL("B13-07: deBridge solvBTC BSC<->SOL [no-edge graceful hold]");
            return;
        }

        // Real local mispricing: execute the round-trip on the forkable leg.
        IERC20(BTCB).approve(PCS_V3_ROUTER, NOTIONAL);
        uint256 got = IPCSV3Router(PCS_V3_ROUTER).exactInputSingle(
            IPCSV3Router.ExactInputSingleParams({
                tokenIn: BTCB, tokenOut: solvBTC, fee: SWAP_FEE_TIER, recipient: address(this),
                deadline: block.timestamp, amountIn: NOTIONAL, amountOutMinimum: (solvOut * 999) / 1000, sqrtPriceLimitX96: 0
            })
        );
        IERC20(solvBTC).approve(PCS_V3_ROUTER, got);
        IPCSV3Router(PCS_V3_ROUTER).exactInputSingle(
            IPCSV3Router.ExactInputSingleParams({
                tokenIn: solvBTC, tokenOut: BTCB, fee: SWAP_FEE_TIER, recipient: address(this),
                deadline: block.timestamp, amountIn: got, amountOutMinimum: (btcbBack * 999) / 1000, sqrtPriceLimitX96: 0
            })
        );
        console2.log("B13-07: executed on-BSC BTCB/solvBTC arb round-trip");
        _endPnL("B13-07: deBridge solvBTC BSC<->SOL");
    }
}
