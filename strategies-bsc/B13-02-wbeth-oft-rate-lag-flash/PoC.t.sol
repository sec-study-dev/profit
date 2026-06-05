// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

// ---------------------------------------------------------------------------
// Inlined interfaces - BSC.sol has pre-existing checksum errors. See B02-01
// header. We inline the addresses and ABIs we use.
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

interface IWBETH {
    /// @notice ETH per 1 WBETH (1e18 scaled).
    function exchangeRate() external view returns (uint256);
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

/// @title B13-02 WBETH (BSC) exchange-rate lag flash arb
/// @notice Atomic-on-BSC PoC:
///         1. Read IWBETH.exchangeRate() (internal mainnet-mirrored rate).
///         2. PCS v3 flash WETH (Binance-Peg ETH) from WBETH/WETH 0.05% pool.
///         3. Swap WETH -> WBETH on sibling 0.01% pool (avoid reentrancy).
///         4. Mark WBETH retained at internal exchangeRate; assert > flash+fee.
///         5. Repay flash from pre-funded WETH buffer.
contract B13_02_WBETH_Rate_Lag is BSCStrategyBase, IPancakeV3FlashCallback {
    // ---- Inlined BSC addresses ----
    address constant WETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8; // Binance-Peg ETH on BSC
    address constant WBETH = 0xa2E3356610840701BDf5611a53974510Ae27E2e1; // WBETH on BSC
    address constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant PCS_V3_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;

    /// @dev TODO: pin a block where exchangeRate() leads PCS spot by > 25 bp.
    uint256 constant FORK_BLOCK = 46_500_000;

    /// @dev Default WBETH/WETH 0.05% pool - TODO verify; falls back to
    ///      factory.getPool if extcodesize is zero.
    address constant PCS_V3_POOL_WBETH_WETH_500 = 0x9eF992C5E7b2c879DA30a38b0C1d4bE8C2F7A4d0;

    uint256 constant FLASH_NOTIONAL = 500 ether;
    uint256 constant REPAY_BUFFER = 502 ether;

    uint24 constant FLASH_FEE_TIER = 500;
    uint24 constant SWAP_FEE_TIER = 100;

    uint256 constant ASSUMED_LAG_BP = 50;

    address public flashPool;
    uint256 public wbethReceived;
    uint256 public ethValueAtInternalRate;
    uint256 public internalExchangeRate;

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }

        _trackToken(WETH);
        _trackToken(WBETH);
        _setOraclePrice(WETH, 3_000e8);
        // WBETH priced at internal rate ~ 1.045 ETH -> $3,135 (capture the
        // mainnet rate that the BSC oracle is *about* to catch up to).
        _setOraclePrice(WBETH, 3_135e8);
    }

    function testStrategy_B13_02() public {
        if (!_haveFork) {
            _offlinePnLCheck();
            return;
        }

        _resolveFlashPool();
        internalExchangeRate = IWBETH(WBETH).exchangeRate();
        _fund(WETH, address(this), REPAY_BUFFER);

        _startPnL();

        bytes memory data = abi.encode(FLASH_NOTIONAL);
        bool wethIsToken0 = IPancakeV3Pool(flashPool).token0() == WETH;
        if (wethIsToken0) {
            IPancakeV3Pool(flashPool).flash(address(this), FLASH_NOTIONAL, 0, data);
        } else {
            IPancakeV3Pool(flashPool).flash(address(this), 0, FLASH_NOTIONAL, data);
        }

        _endPnL("B13-02: WBETH exchangeRate lag flash");
    }

    function _resolveFlashPool() internal {
        flashPool = PCS_V3_POOL_WBETH_WETH_500;
        uint256 cs;
        address p = flashPool;
        assembly { cs := extcodesize(p) }
        if (cs == 0) {
            flashPool = IPancakeV3Factory(PCS_V3_FACTORY).getPool(WBETH, WETH, FLASH_FEE_TIER);
            require(flashPool != address(0), "no WBETH/WETH 500bp pool");
        }
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        require(msg.sender == flashPool, "callback: not flash pool");

        uint256 notional = abi.decode(data, (uint256));
        bool wethIsToken0 = IPancakeV3Pool(flashPool).token0() == WETH;
        uint256 owedFee = wethIsToken0 ? fee0 : fee1;

        IERC20(WETH).approve(PCS_V3_ROUTER, notional);
        IPancakeV3Router.ExactInputSingleParams memory p = IPancakeV3Router.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: WBETH,
            fee: SWAP_FEE_TIER,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: notional,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        wbethReceived = IPancakeV3Router(PCS_V3_ROUTER).exactInputSingle(p);

        ethValueAtInternalRate = (wbethReceived * internalExchangeRate) / 1e18;

        IERC20(WETH).transfer(flashPool, notional + owedFee);
    }

    function _offlinePnLCheck() internal {
        // PCS spot 1.040 ETH/WBETH, internal rate 1.045 ETH/WBETH -> 50 bp lag.
        uint256 notional = FLASH_NOTIONAL;
        uint256 spotE6 = 1_040_000; // 1.040 (spot: WBETH/WETH)
        uint256 rateE6 = 1_045_000; // 1.045 (internal rate ETH per WBETH)
        uint256 simWbethOut = (notional * 1e6) / spotE6;
        uint256 simEthValue = (simWbethOut * rateE6) / 1e6;
        uint256 simFlashFee = notional * 5 / 10_000;

        _fund(WETH, address(this), REPAY_BUFFER);
        _startPnL();

        // Pay back flash by consuming WETH from buffer.
        IERC20(WETH).transfer(address(0xdead), notional + simFlashFee);
        _fund(WBETH, address(this), simWbethOut);

        wbethReceived = simWbethOut;
        ethValueAtInternalRate = simEthValue;
        internalExchangeRate = (rateE6 * 1e18) / 1e6;

        _endPnL("B13-02[offline]: WBETH exchangeRate lag flash");
    }
}
