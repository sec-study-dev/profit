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

/// @title B13-03 BTCB vs WBTC (bridged) cross-chain spread arb
/// @notice Thesis: BTCB (Binance-Peg BTC) and the LayerZero WBTC bridged onto
///         BSC are both BTC claims that can dislocate; capture the spread on a
///         BSC DEX and re-balance via the bridge.
/// @dev    REALITY ON-FORK: the only WBTC on BSC with code is
///         0x0555E30da8f98308EdB960aa94C0Db47230d2B9c (8 dec). Its PancakeSwap
///         v3 pools against BTCB exist but carry ~ZERO liquidity, so there is no
///         executable on-BSC DEX leg, and the cross-chain rebalance cannot
///         settle on one fork. Per the playbook this is a faithful GRACEFUL
///         HOLD: we verify token code, probe pool liquidity, surface the lack of
///         a tradeable spread, and hold flat (net ~0). If a future block ever
///         shows a liquid BTCB/WBTC pool the guarded-arb block below executes.
contract B13_03_BTCB_WBTC_Spread is BSCStrategyBase {
    // ---- Inlined BSC addresses ----
    address constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c; // 18 dec
    address constant WBTC = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c; // real BSC WBTC, 8 dec
    address constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant PCS_V3_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address constant QUOTER_V2 = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;

    uint256 constant FORK_BLOCK = 48_000_000;

    /// @dev Notional in WBTC base units (8 dec). 0.5 WBTC.
    uint256 constant NOTIONAL_WBTC = 5e7;
    uint24[3] FEE_TIERS = [uint24(100), uint24(500), uint24(2500)];

    bool internal _haveFork;
    address public pool;
    uint24 public liveFee;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }
        _trackToken(BTCB);
        _trackToken(WBTC);
        _setOraclePrice(BTCB, 65_000e8);
        _setOraclePrice(WBTC, 65_000e8);
    }

    function testStrategy_B13_03() public {
        if (!_haveFork) {
            _startPnL();
            console2.log("B13-03: no fork -> graceful hold");
            _endPnL("B13-03: BTCB/WBTC spread [no-fork hold]");
            return;
        }

        require(_hasCode(BTCB) && _hasCode(WBTC), "BTC tokens missing");

        // Find the deepest BTCB/WBTC pool with non-zero liquidity.
        uint128 bestLiq = 0;
        for (uint256 i = 0; i < FEE_TIERS.length; i++) {
            address p = IPancakeV3Factory(PCS_V3_FACTORY).getPool(BTCB, WBTC, FEE_TIERS[i]);
            if (p == address(0) || !_hasCode(p)) continue;
            uint128 liq = IPancakeV3Pool(p).liquidity();
            console2.log("B13-03: BTCB/WBTC pool fee tier liquidity:", uint256(FEE_TIERS[i]), uint256(liq));
            if (liq > bestLiq) { bestLiq = liq; pool = p; liveFee = FEE_TIERS[i]; }
        }

        _fund(WBTC, address(this), NOTIONAL_WBTC);
        _startPnL();

        if (pool == address(0) || bestLiq == 0) {
            console2.log("B13-03: no liquid BTCB/WBTC pool -> no tradeable spread; HOLD FLAT");
            _endPnL("B13-03: BTCB/WBTC spread [no-liquidity graceful hold]");
            return;
        }

        // Guarded-arb: only swap if quoter shows BTCB out (18 dec) exceeds the
        // WBTC notional grossed to 18 dec (i.e. WBTC trades at a discount).
        (uint256 btcbOut,,,) = IQuoterV2(QUOTER_V2).quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: WBTC,
                tokenOut: BTCB,
                amountIn: NOTIONAL_WBTC,
                fee: liveFee,
                sqrtPriceLimitX96: 0
            })
        );
        uint256 parBtcb18 = NOTIONAL_WBTC * 1e10; // WBTC 8dec -> 18dec par
        console2.log("B13-03: WBTC->BTCB out (18 dec):", btcbOut);
        console2.log("B13-03: par BTCB (18 dec):", parBtcb18);

        if (btcbOut <= parBtcb18) {
            console2.log("B13-03: no positive BTCB/WBTC edge -> HOLD FLAT");
            _endPnL("B13-03: BTCB/WBTC spread [no-edge hold]");
            return;
        }

        IERC20(WBTC).approve(PCS_V3_ROUTER, NOTIONAL_WBTC);
        IPCSV3Router(PCS_V3_ROUTER).exactInputSingle(
            IPCSV3Router.ExactInputSingleParams({
                tokenIn: WBTC,
                tokenOut: BTCB,
                fee: liveFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: NOTIONAL_WBTC,
                amountOutMinimum: (btcbOut * 999) / 1000,
                sqrtPriceLimitX96: 0
            })
        );
        console2.log("B13-03: executed BTCB/WBTC discount arb");
        _endPnL("B13-03: BTCB/WBTC bridge spread arb");
    }
}
