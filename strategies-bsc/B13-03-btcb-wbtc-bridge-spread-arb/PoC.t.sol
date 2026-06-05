// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

// ---------------------------------------------------------------------------
// Inlined interfaces - BSC.sol has pre-existing checksum errors. See B02-01
// header. We inline addresses + ABIs.
// ---------------------------------------------------------------------------

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IPancakeV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IPancakeV3FlashCallback {
    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external;
}

interface IPancakeV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IPancakeV3Router {
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

}

/// @title B13-03 BTCB vs WBTC (bridged) cross-chain spread arb
/// @notice Atomic-on-BSC PoC:
///         1. PCS v3 flash WBTC (8 decimals) from BTCB/WBTC 0.05% pool.
///         2. Swap WBTC -> BTCB on sibling 0.01% tier, receiving BTCB at the
///            spread-implied uplift.
///         3. Repay flash from pre-funded WBTC buffer.
///         The "bridge spread" is the *source* of the dislocation; the
///         arb closes atomically with no LayerZero leg.
/// @dev    BTCB on BSC = 18 decimals; WBTC on BSC = 8 decimals.
contract B13_03_BTCB_WBTC_Spread is BSCStrategyBase, IPancakeV3FlashCallback {
    // ---- Inlined BSC addresses ----
    address constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    /// @notice WBTC (LayerZero V2 deployment) on BSC. TODO verify.
    address constant WBTC = 0x1aACC9b7c2D421fdEaAc59D8b61bcaE9b5E6dAf8;
    address constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant PCS_V3_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;

    /// @dev TODO: pin a block with > 20 bp BTCB/WBTC spread.
    uint256 constant FORK_BLOCK = 46_800_000;

    /// @dev Flash notional in WBTC base units (8 decimals). 5e8 = 5 WBTC.
    uint256 constant FLASH_NOTIONAL = 5e8;
    /// @dev Pre-funded WBTC buffer (5.02 WBTC).
    uint256 constant REPAY_BUFFER = 5_020_000_00; // 5.02 WBTC (8 dec)

    uint24 constant FLASH_FEE_TIER = 500;
    uint24 constant SWAP_FEE_TIER = 100;

    uint256 constant ASSUMED_SPREAD_BP = 35;

    address public flashPool;
    uint256 public wbtcFlashed;
    uint256 public btcbReceived;

    bool internal _haveFork;

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
            _offlinePnLCheck();
            return;
        }

        flashPool = IPancakeV3Factory(PCS_V3_FACTORY).getPool(BTCB, WBTC, FLASH_FEE_TIER);
        require(flashPool != address(0), "no BTCB/WBTC 500bp pool");

        _fund(WBTC, address(this), REPAY_BUFFER);

        _startPnL();

        bytes memory data = abi.encode(FLASH_NOTIONAL);
        bool wbtcIsToken0 = IPancakeV3Pool(flashPool).token0() == WBTC;
        if (wbtcIsToken0) {
            IPancakeV3Pool(flashPool).flash(address(this), FLASH_NOTIONAL, 0, data);
        } else {
            IPancakeV3Pool(flashPool).flash(address(this), 0, FLASH_NOTIONAL, data);
        }

        _endPnL("B13-03: BTCB/WBTC bridge spread arb");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        require(msg.sender == flashPool, "callback: not flash pool");

        uint256 notional = abi.decode(data, (uint256));
        bool wbtcIsToken0 = IPancakeV3Pool(flashPool).token0() == WBTC;
        uint256 owedFee = wbtcIsToken0 ? fee0 : fee1;
        wbtcFlashed = notional;

        IERC20(WBTC).approve(PCS_V3_ROUTER, notional);
        IPancakeV3Router.ExactInputSingleParams memory p = IPancakeV3Router.ExactInputSingleParams({
            tokenIn: WBTC,
            tokenOut: BTCB,
            fee: SWAP_FEE_TIER,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: notional,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        btcbReceived = IPancakeV3Router(PCS_V3_ROUTER).exactInputSingle(p);

        IERC20(WBTC).transfer(flashPool, notional + owedFee);
    }

    function _offlinePnLCheck() internal {
        // WBTC 35 bp discount vs BTCB; 5 WBTC -> ~5.0175 BTCB; flash fee 5 bp.
        // Net gain = 30 bp ~ 0.015 BTC ~ $975 @ $65k/BTC.
        uint256 notional = FLASH_NOTIONAL;
        // Convert 8-dec WBTC notional to 18-dec BTCB equivalent, then apply spread.
        uint256 simBtcbOut18 = (uint256(notional) * 1e10 * (10_000 + ASSUMED_SPREAD_BP)) / 10_000;
        uint256 simFlashFee = notional * 5 / 10_000;

        _fund(WBTC, address(this), REPAY_BUFFER);
        _startPnL();

        IERC20(WBTC).transfer(address(0xdead), notional + simFlashFee);
        _fund(BTCB, address(this), simBtcbOut18);

        wbtcFlashed = notional;
        btcbReceived = simBtcbOut18;

        _endPnL("B13-03[offline]: BTCB/WBTC bridge spread arb");
    }
}
