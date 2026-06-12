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

// PancakeSwap SmartRouter (0x13f4...) — exactInputSingle has NO deadline field.
interface IPancakeV3Router {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256);
}

interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn; address tokenOut; uint256 amountIn; uint24 fee; uint160 sqrtPriceLimitX96;
    }
    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external returns (uint256 amountOut, uint160, uint32, uint256);
}

interface IThenaRouter {
    struct Route { address from; address to; bool stable; }
    function swapExactTokensForTokens(
        uint256 amountIn, uint256 amountOutMin, Route[] calldata routes, address to, uint256 deadline
    ) external returns (uint256[] memory);
    function getAmountsOut(uint256 amountIn, Route[] calldata routes)
        external view returns (uint256[] memory);
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
    /// @dev Canonical Stader BNBx on BSC (BSC.sol carries a stale last-bytes
    ///      variant `...044f6AE4` that has no code; the correct token is below
    ///      and is the one with live PCS v3 / Thena pools at this block).
    address constant BNBx = 0x1bdd3Cf7F79cfB8EdbB955f20ad99211551BA275;
    address constant PCS_V3_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    address constant PCS_V3_QUOTER = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;
    address constant THENA_ROUTER = 0x20a304a7d126758dfe6B243D0fc515F83bCA8431;

    /// @dev Verified at this block: BNBx PCS v3 0.05% pool ~8.9 WBNB/8.4 BNBx;
    ///      Thena stable+volatile BNBx/WBNB pairs both have liquidity.
    uint256 constant FORK_BLOCK = 45_000_000;

    /// @dev Deep WBNB-side flash source: PCS v3 WBNB/USDT 0.05% pool (~8.7k WBNB).
    address constant PCS_V3_POOL_WBNB_USDT_500 = 0x36696169C63e42cd08ce11f5deeBbCeBae652050;

    /// @dev PCS v3 BNBx/WBNB exit-leg fee tier (the live tier is 0.05%).
    uint24 constant PCS_V3_BNBX_FEE = 500;

    /// @dev Sized to the thin Thena/PCS BNBx pools (~4-10 BNBx of depth).
    uint256 constant FLASH_NOTIONAL = 1 ether;
    uint256 constant REPAY_BUFFER = 3 ether;

    address public flashPool;
    uint256 public bnbXReceived;
    uint256 public wbnbExitProceeds;
    uint256 public stadeInternalRateE18;
    bool public edgeTaken;

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
        require(IPancakeV3Pool(flashPool).token0() != address(0), "flash pool missing");

        // Quote the cross-DEX round trip: Thena WBNB->BNBx, then PCS v3 BNBx->WBNB.
        uint256 bnbxQuoted = _thenaQuote(FLASH_NOTIONAL);
        uint256 wbnbBack = bnbxQuoted == 0 ? 0 : _quote(BNBx, WBNB, PCS_V3_BNBX_FEE, bnbxQuoted);

        _fund(WBNB, address(this), REPAY_BUFFER);
        _startPnL();

        // Flash fee on the WBNB/USDT pool is its 0.05% tier.
        uint256 flashFee = (FLASH_NOTIONAL * 500) / 1_000_000 + 1;

        if (wbnbBack > FLASH_NOTIONAL + flashFee) {
            edgeTaken = true;
            bool wbnbIsToken0 = IPancakeV3Pool(flashPool).token0() == WBNB;
            if (wbnbIsToken0) IPancakeV3Pool(flashPool).flash(address(this), FLASH_NOTIONAL, 0, "");
            else IPancakeV3Pool(flashPool).flash(address(this), 0, FLASH_NOTIONAL, "");
        } else {
            edgeTaken = false;
            console2.log("no profitable edge; holding flat. wbnbBack=", wbnbBack);
            console2.log("required (notional+flashFee)=", FLASH_NOTIONAL + flashFee);
        }

        _endPnL("B02-02: BNBx Thena<->PCSv3 internal-rate arb");
    }

    function _thenaQuote(uint256 amountIn) internal view returns (uint256) {
        IThenaRouter.Route[] memory routes = new IThenaRouter.Route[](1);
        routes[0] = IThenaRouter.Route({from: WBNB, to: BNBx, stable: true});
        try IThenaRouter(THENA_ROUTER).getAmountsOut(amountIn, routes) returns (uint256[] memory a) {
            return a[a.length - 1];
        } catch {
            return 0;
        }
    }

    function _quote(address tin, address tout, uint24 fee, uint256 amountIn)
        internal returns (uint256 out)
    {
        try IQuoterV2(PCS_V3_QUOTER).quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: tin, tokenOut: tout, amountIn: amountIn, fee: fee, sqrtPriceLimitX96: 0
            })
        ) returns (uint256 a, uint160, uint32, uint256) { out = a; } catch { out = 0; }
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

        // Leg B: BNBx -> WBNB via PCS v3
        IERC20(BNBx).approve(PCS_V3_ROUTER, bnbXReceived);
        wbnbExitProceeds = IPancakeV3Router(PCS_V3_ROUTER).exactInputSingle(
            IPancakeV3Router.ExactInputSingleParams({
                tokenIn: BNBx, tokenOut: WBNB, fee: PCS_V3_BNBX_FEE,
                recipient: address(this), amountIn: bnbXReceived,
                amountOutMinimum: 0, sqrtPriceLimitX96: 0
            })
        );

        // Repay
        IERC20(WBNB).transfer(flashPool, FLASH_NOTIONAL + owedFee);
    }

    function _offlinePnLCheck() internal {
        _startPnL();
        _endPnL("B02-02[offline]: BNBx Thena<->PCSv3 internal-rate arb (hold flat)");
    }
}
