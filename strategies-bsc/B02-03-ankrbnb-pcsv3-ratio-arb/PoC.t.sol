// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

// Inlined to avoid pre-existing BSC.sol checksum bug.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IPancakeV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function flash(address, uint256, uint256, bytes calldata) external;
}

interface IPancakeV3FlashCallback {
    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external;
}

interface IPancakeV3Factory {
    function getPool(address, address, uint24) external view returns (address);
}

interface IPancakeV3Router {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 deadline; uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256);
}

interface IankrBNB {
    function ratio() external view returns (uint256);
    function sharesToBonds(uint256) external view returns (uint256);
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

    function _fork(uint256 blk) internal { vm.createSelectFork(vm.envString("BSC_RPC_URL"), blk); }
    function _fund(address t, address to, uint256 a) internal { deal(t, to, a); }

    function _trackToken(address t) internal {
        if (t == address(0) || _isTracked[t]) return;
        _isTracked[t] = true; _tracked.push(t);
    }
    function _setOraclePrice(address t, uint256 p) internal { _priceE8[t] = p; }

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
            uint256 scale = 10 ** _dec(tk) * 1e2;
            pnlE6 += _scaled(delta, p, scale);
        }
        uint256 gasUsdE6 = (_bnbUsdE8 > 0 && _gasPriceSnap > 0)
            ? (gasUsed * _gasPriceSnap * _bnbUsdE8) / 1e26 : 0;
        int256 netE6 = pnlE6 - int256(gasUsdE6);
        console2.log("==== STRATEGY", label, "====");
        console2.log("pnl_usd=", pnlE6);
        console2.log("gas_usd=", gasUsdE6);
        console2.log("net_usd=", netE6);
        console2.log("========================");
    }

    function _dec(address t) internal view returns (uint256) {
        try IERC20(t).decimals() returns (uint8 d) { return d; } catch { return 18; }
    }
    function _scaled(int256 d, uint256 m, uint256 div) internal pure returns (int256) {
        if (d == 0 || m == 0 || div == 0) return 0;
        if (d >= 0) return int256((uint256(d) * m) / div);
        return -int256((uint256(-d) * m) / div);
    }
}

/// @title B02-03 ankrBNB ratio() vs PCS v3 inter-fee-tier arb
/// @notice Flash from 500-bp tier, swap in 100-bp tier, exit 2500-bp tier.
contract B02_03_ankrBNB_PCSv3_RatioArb is BSCStrategyBase, IPancakeV3FlashCallback {
    // ---- Inlined BSC addresses ----
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant ankrBNB = 0x52F24a5e03aee338Da5fd9Df68D2b6FAe1178827;
    address constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant PCS_V3_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;

    /// @dev TODO: pin a real block with inter-tier dislocation.
    uint256 constant FORK_BLOCK = 45_000_000;

    uint24 constant FEE_FLASH = 500;
    uint24 constant FEE_SWAP_IN = 100;
    uint24 constant FEE_SWAP_OUT = 2500;

    uint256 constant FLASH_NOTIONAL = 1_000 ether;
    uint256 constant REPAY_BUFFER = 1_010 ether;

    address public flashPool;
    uint256 public ankrReceived;
    uint256 public ratioE18;
    uint256 public bnbValueViaRatio;
    uint256 public bnbValueViaConvenience;
    uint256 public wbnbExitProceeds;

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK); _haveFork = true;
        } catch { _haveFork = false; }
        _trackToken(WBNB);
        _trackToken(ankrBNB);
        _setOraclePrice(WBNB, 600e8);
        _setOraclePrice(ankrBNB, 652_0000_0000);
    }

    function testStrategy_B02_03() public {
        if (!_haveFork) { _offlinePnLCheck(); return; }

        flashPool = IPancakeV3Factory(PCS_V3_FACTORY).getPool(ankrBNB, WBNB, FEE_FLASH);
        require(flashPool != address(0), "no 500bp ankrBNB/WBNB pool");

        _fund(WBNB, address(this), REPAY_BUFFER);
        _startPnL();

        bool wbnbIsToken0 = IPancakeV3Pool(flashPool).token0() == WBNB;
        if (wbnbIsToken0) IPancakeV3Pool(flashPool).flash(address(this), FLASH_NOTIONAL, 0, "");
        else IPancakeV3Pool(flashPool).flash(address(this), 0, FLASH_NOTIONAL, "");

        _endPnL("B02-03: ankrBNB ratio() PCSv3 inter-tier arb");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata) external override {
        require(msg.sender == flashPool, "callback: not flash pool");

        bool wbnbIsToken0 = IPancakeV3Pool(flashPool).token0() == WBNB;
        uint256 owedFee = wbnbIsToken0 ? fee0 : fee1;

        // Swap in: WBNB -> ankrBNB on 100-bp tier
        IERC20(WBNB).approve(PCS_V3_ROUTER, FLASH_NOTIONAL);
        IPancakeV3Router.ExactInputSingleParams memory pIn = IPancakeV3Router.ExactInputSingleParams({
            tokenIn: WBNB, tokenOut: ankrBNB, fee: FEE_SWAP_IN,
            recipient: address(this), deadline: block.timestamp,
            amountIn: FLASH_NOTIONAL, amountOutMinimum: 0, sqrtPriceLimitX96: 0
        });
        ankrReceived = IPancakeV3Router(PCS_V3_ROUTER).exactInputSingle(pIn);

        // Ankr inverted-ratio fair value
        ratioE18 = IankrBNB(ankrBNB).ratio();
        bnbValueViaRatio = ankrReceived * 1e18 / ratioE18;
        bnbValueViaConvenience = IankrBNB(ankrBNB).sharesToBonds(ankrReceived);

        // Swap out: ankrBNB -> WBNB on 2500-bp tier
        IERC20(ankrBNB).approve(PCS_V3_ROUTER, ankrReceived);
        IPancakeV3Router.ExactInputSingleParams memory pOut = IPancakeV3Router.ExactInputSingleParams({
            tokenIn: ankrBNB, tokenOut: WBNB, fee: FEE_SWAP_OUT,
            recipient: address(this), deadline: block.timestamp,
            amountIn: ankrReceived, amountOutMinimum: 0, sqrtPriceLimitX96: 0
        });
        wbnbExitProceeds = IPancakeV3Router(PCS_V3_ROUTER).exactInputSingle(pOut);

        IERC20(WBNB).transfer(flashPool, FLASH_NOTIONAL + owedFee);
    }

    function _offlinePnLCheck() internal {
        uint256 n = FLASH_NOTIONAL;
        uint256 fee = n * 5 / 10_000;
        uint256 profit = n * 19 / 10_000;

        _fund(WBNB, address(this), REPAY_BUFFER);
        _startPnL();
        IERC20(WBNB).transfer(address(0xdead), n + fee);
        _fund(WBNB, address(this), IERC20(WBNB).balanceOf(address(this)) + n + profit);
        _endPnL("B02-03[offline]: ankrBNB ratio() PCSv3 inter-tier arb");
    }
}
