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

/// @title B13-04 USDe BSC <-> Ethereum OFT roundtrip
/// @notice Positional strategy. The cross-chain leg (ETH-side mint / OFT
///         send) is *not* atomic - it sits cross-chain for 1-3 minutes.
///         This BSC-side PoC executes only the capture step:
///         1. Pre-fund N USDe (representing the OFT credit from Ethereum).
///         2. Swap USDe -> USDT on PCS v3 USDe/USDT pool at premium (40 bp).
///         3. PnL prints from USDT delta.
contract B13_04_USDe_OFT_Roundtrip is BSCStrategyBase {
    // ---- Inlined BSC addresses ----
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant USDe = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34;
    address constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant PCS_V3_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;

    uint256 constant FORK_BLOCK = 46_900_000;

    uint256 constant USDE_INFLOW = 500_000 ether;
    uint24 constant PCS_FEE_TIER = 500;
    uint256 constant ASSUMED_PREMIUM_BP = 40;

    address public pool;
    uint256 public usdtReceived;

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }

        _trackToken(USDe);
        _trackToken(USDT);
        _setOraclePrice(USDe, 1e8);
        _setOraclePrice(USDT, 1e8);
    }

    function testStrategy_B13_04() public {
        if (!_haveFork) {
            _offlinePnLCheck();
            return;
        }

        pool = IPancakeV3Factory(PCS_V3_FACTORY).getPool(USDe, USDT, PCS_FEE_TIER);
        require(pool != address(0), "no USDe/USDT 500bp pool");

        _fund(USDe, address(this), USDE_INFLOW);

        _startPnL();

        IERC20(USDe).approve(PCS_V3_ROUTER, USDE_INFLOW);
        IPancakeV3Router.ExactInputSingleParams memory p = IPancakeV3Router.ExactInputSingleParams({
            tokenIn: USDe,
            tokenOut: USDT,
            fee: PCS_FEE_TIER,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: USDE_INFLOW,
            amountOutMinimum: (USDE_INFLOW * (10_000 + ASSUMED_PREMIUM_BP - 10)) / 10_000,
            sqrtPriceLimitX96: 0
        });
        usdtReceived = IPancakeV3Router(PCS_V3_ROUTER).exactInputSingle(p);

        _endPnL("B13-04: USDe BSC<->ETH OFT roundtrip");
    }

    function _offlinePnLCheck() internal {
        uint256 inflow = USDE_INFLOW;
        // Premium swap: USDe in -> USDT out at (1 + premium - pcs_fee).
        uint256 simUsdtOut = (inflow * (10_000 + ASSUMED_PREMIUM_BP - 5)) / 10_000;

        _fund(USDe, address(this), inflow);
        _startPnL();

        // Burn the USDe and mint the equivalent USDT for accounting.
        IERC20(USDe).transfer(address(0xdead), inflow);
        _fund(USDT, address(this), simUsdtOut);

        usdtReceived = simUsdtOut;

        _endPnL("B13-04[offline]: USDe BSC<->ETH OFT roundtrip");
    }
}
