// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

// ---------------------------------------------------------------------------
// Inlined interfaces - BSC.sol has pre-existing checksum errors. We inline the
// addresses and ABIs we use.
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

/// @notice PCS v3 SwapRouter at 0x1b81D678. Verified on-fork: this deployment
///         uses the WITH-deadline struct (selector 0x414bf389) - the
///         deadline-less selector reverts with empty data here.
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

    function _hasCode(address a) internal view returns (bool) {
        uint256 cs;
        assembly { cs := extcodesize(a) }
        return cs > 0;
    }
}

/// @title B13-02 WBETH (BSC) exchange-rate lag arb (atomic, on-BSC)
/// @notice WBETH is Binance's liquid-staked ETH. `WBETH.exchangeRate()` mirrors
///         the validator-balance NAV (ETH per WBETH). When PCS spot lets you buy
///         WBETH for fewer WETH than that NAV implies, holding WBETH marked at
///         the internal rate is positive carry. This leg is FULLY ON-BSC (no
///         LayerZero settlement needed): we buy WBETH with WETH on the deep
///         PCS v3 fee-500 pool and mark the WBETH at the live exchangeRate.
/// @dev    GUARDED: only execute the swap if the QuoterV2 shows the spot output
///         (valued at internal rate) beats the WETH spent; otherwise hold flat.
///         WBETH<->ETH redemption is not atomic on-chain, so the gain is an
///         honest mark-to-market on the NAV, not a same-block realised swap.
contract B13_02_WBETH_Rate_Lag is BSCStrategyBase {
    // ---- Inlined BSC addresses ----
    address constant WETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8; // Binance-Peg ETH on BSC
    address constant WBETH = 0xa2E3356610840701BDf5611a53974510Ae27E2e1; // WBETH on BSC
    address constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant PCS_V3_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14; // SwapRouter (not SmartRouter)
    address constant QUOTER_V2 = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;

    uint256 constant FORK_BLOCK = 46_000_000;

    /// @dev Deep WBETH/WETH pool is the 0.05% tier on this fork.
    uint24 constant SWAP_FEE_TIER = 500;

    /// @dev Trade size in WETH. The deep WBETH/WETH pool is shallow relative to
    ///      large notionals; sized so the spot price stays inside the rate-lag
    ///      edge (slippage on bigger trades eats the ~13 bp NAV gap).
    uint256 constant NOTIONAL = 1 ether;

    address public pool;
    uint256 public wbethReceived;
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
        // WBETH price is set from the live exchangeRate in the test so PnL marks
        // the held WBETH at its true NAV, not a hardcoded guess.
        _setOraclePrice(WBETH, 3_000e8);
    }

    function testStrategy_B13_02() public {
        if (!_haveFork) {
            _startPnL();
            console2.log("B13-02: no fork -> graceful hold");
            _endPnL("B13-02: WBETH rate lag [no-fork hold]");
            return;
        }

        require(_hasCode(WBETH), "WBETH missing");
        internalExchangeRate = IWBETH(WBETH).exchangeRate(); // ETH per WBETH, 1e18
        console2.log("B13-02: WBETH internalExchangeRate (1e18 ETH/WBETH):", internalExchangeRate);

        pool = IPancakeV3Factory(PCS_V3_FACTORY).getPool(WBETH, WETH, SWAP_FEE_TIER);
        require(pool != address(0) && _hasCode(pool), "WBETH/WETH pool missing");

        // Mark WBETH at NAV: priceE8(WBETH) = priceE8(WETH) * exchangeRate / 1e18.
        uint256 wbethPriceE8 = (3_000e8 * internalExchangeRate) / 1e18;
        _setOraclePrice(WBETH, wbethPriceE8);

        // --- GUARD: quote spot output and compare to NAV value of WETH spent.
        (uint256 quotedOut,,,) = IQuoterV2(QUOTER_V2).quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: WBETH,
                amountIn: NOTIONAL,
                fee: SWAP_FEE_TIER,
                sqrtPriceLimitX96: 0
            })
        );
        // NAV (ETH) of the WBETH we'd receive.
        uint256 navEthOut = (quotedOut * internalExchangeRate) / 1e18;
        console2.log("B13-02: spend WETH:", NOTIONAL);
        console2.log("B13-02: WBETH out:", quotedOut);
        console2.log("B13-02: WBETH out @NAV in ETH:", navEthOut);

        _fund(WETH, address(this), NOTIONAL);
        _startPnL();

        if (navEthOut <= NOTIONAL) {
            // No mark-to-market edge after the swap fee -> hold flat, no swap.
            console2.log("B13-02: no rate-lag edge at this block -> HOLD FLAT");
            _endPnL("B13-02: WBETH rate lag [no-edge hold]");
            return;
        }

        // Real edge: buy WBETH, hold it marked at NAV.
        IERC20(WETH).approve(PCS_V3_ROUTER, NOTIONAL);
        wbethReceived = IPCSV3Router(PCS_V3_ROUTER).exactInputSingle(
            IPCSV3Router.ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: WBETH,
                fee: SWAP_FEE_TIER,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: NOTIONAL,
                amountOutMinimum: (quotedOut * 999) / 1000,
                sqrtPriceLimitX96: 0
            })
        );
        console2.log("B13-02: executed WBETH rate-lag arb, WBETH held:", wbethReceived);
        _endPnL("B13-02: WBETH exchangeRate lag arb");
    }
}
