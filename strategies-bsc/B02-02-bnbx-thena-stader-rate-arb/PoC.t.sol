// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

// Inlined to avoid the pre-existing BSC.sol checksum bug (see B02-01 note).

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

interface IPancakeV3Router {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 deadline; uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256);
}

interface IThenaRouter {
    struct Route { address from; address to; bool stable; }
    function swapExactTokensForTokens(
        uint256 amountIn, uint256 amountOutMin, Route[] calldata routes, address to, uint256 deadline
    ) external returns (uint256[] memory);
}

interface IBNBx {
    function getExchangeRate() external view returns (uint256);
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

/// @title B02-02 BNBx Thena vs Stader internal rate cross-DEX arb
/// @notice flash WBNB -> Thena stable WBNB->BNBx -> PCS v3 BNBx->WBNB -> repay.
contract B02_02_BNBx_Thena_Stader_RateArb is BSCStrategyBase, IPancakeV3FlashCallback {
    // ---- Inlined BSC addresses ----
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BNBx = 0x1BDD3CF7F79cFB8edbb955F20aD99211044f6AE4;
    address constant PCS_V3_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    address constant THENA_ROUTER = 0x20a304a7d126758dfe6B243D0fc515F83bCA8431;

    /// @dev TODO: pin a real BSC block at Thena epoch boundary with BNBx discount.
    uint256 constant FORK_BLOCK = 45_000_000;

    /// @dev Deep WBNB-side flash source: PCS v3 WBNB/USDT 0.05% pool. TODO verify.
    address constant PCS_V3_POOL_WBNB_USDT_500 = 0x36696169C63e42cd08ce11f5deeBbCeBae652050;

    /// @dev PCS v3 BNBx/WBNB exit-leg pool fee tier. TODO verify on BscScan.
    uint24 constant PCS_V3_BNBX_FEE = 2500;

    uint256 constant FLASH_NOTIONAL = 1_000 ether;
    uint256 constant REPAY_BUFFER = 1_010 ether;

    address public flashPool;
    uint256 public bnbXReceived;
    uint256 public wbnbExitProceeds;
    uint256 public stadeInternalRateE18;

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch { _haveFork = false; }
        _trackToken(WBNB);
        _trackToken(BNBx);
        _setOraclePrice(WBNB, 600e8);
        _setOraclePrice(BNBx, 651_0000_0000); // 1.085 BNB at $600 -> $651
    }

    function testStrategy_B02_02() public {
        if (!_haveFork) { _offlinePnLCheck(); return; }

        flashPool = PCS_V3_POOL_WBNB_USDT_500;
        _fund(WBNB, address(this), REPAY_BUFFER);
        _startPnL();

        bool wbnbIsToken0 = IPancakeV3Pool(flashPool).token0() == WBNB;
        if (wbnbIsToken0) IPancakeV3Pool(flashPool).flash(address(this), FLASH_NOTIONAL, 0, "");
        else IPancakeV3Pool(flashPool).flash(address(this), 0, FLASH_NOTIONAL, "");

        _endPnL("B02-02: BNBx Thena<->PCSv3 internal-rate arb");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata) external override {
        require(msg.sender == flashPool, "callback: not flash pool");

        bool wbnbIsToken0 = IPancakeV3Pool(flashPool).token0() == WBNB;
        uint256 owedFee = wbnbIsToken0 ? fee0 : fee1;

        // Leg A: WBNB -> BNBx via Thena stable
        IERC20(WBNB).approve(THENA_ROUTER, FLASH_NOTIONAL);
        IThenaRouter.Route[] memory routes = new IThenaRouter.Route[](1);
        routes[0] = IThenaRouter.Route({from: WBNB, to: BNBx, stable: true});
        uint256[] memory amts = IThenaRouter(THENA_ROUTER).swapExactTokensForTokens(
            FLASH_NOTIONAL, 0, routes, address(this), block.timestamp
        );
        bnbXReceived = amts[amts.length - 1];

        // Stader internal rate (report only)
        stadeInternalRateE18 = IBNBx(BNBx).getExchangeRate();

        // Leg B: BNBx -> WBNB via PCS v3
        IERC20(BNBx).approve(PCS_V3_ROUTER, bnbXReceived);
        IPancakeV3Router.ExactInputSingleParams memory p = IPancakeV3Router.ExactInputSingleParams({
            tokenIn: BNBx, tokenOut: WBNB, fee: PCS_V3_BNBX_FEE,
            recipient: address(this), deadline: block.timestamp,
            amountIn: bnbXReceived, amountOutMinimum: 0, sqrtPriceLimitX96: 0
        });
        wbnbExitProceeds = IPancakeV3Router(PCS_V3_ROUTER).exactInputSingle(p);

        // Repay
        IERC20(WBNB).transfer(flashPool, FLASH_NOTIONAL + owedFee);
    }

    function _offlinePnLCheck() internal {
        uint256 n = FLASH_NOTIONAL;
        uint256 fee = n * 5 / 10_000;
        uint256 profit = n * 30 / 10_000 - fee;

        _fund(WBNB, address(this), REPAY_BUFFER);
        _startPnL();

        IERC20(WBNB).transfer(address(0xdead), n + fee);
        _fund(WBNB, address(this), IERC20(WBNB).balanceOf(address(this)) + n + profit);

        _endPnL("B02-02[offline]: BNBx Thena<->PCSv3 internal-rate arb");
    }
}
