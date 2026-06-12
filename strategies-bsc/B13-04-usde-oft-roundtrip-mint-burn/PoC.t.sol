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

/// @title B13-04 USDe OFT BSC<->ETH round-trip mint/burn
/// @notice Thesis: USDe is a LayerZero OFT. When the BSC USDe trades at a
///         premium to its ETH-side mint/redeem par, you swap into USDe on BSC,
///         OFT-send it to ETH, redeem at par, and re-bridge. The OFT settlement
///         (ETH-side redeem) CANNOT execute on a single BSC fork, so per the
///         playbook the cross-chain leg is a code-guarded GRACEFUL no-op.
/// @dev    The FORKABLE on-BSC leg is the USDe<->USDT swap on the real PCS v3
///         fee-100 pool (deployed ~block 48M). We read the live spread with the
///         QuoterV2 and run a GUARDED arb: only swap if USDe sells above par
///         (i.e. USDe->USDT out > notional); otherwise hold flat (net ~0). No
///         fabricated cross-chain profit.
contract B13_04_USDe_OFT_Roundtrip is BSCStrategyBase {
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant USDe = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34;
    address constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant PCS_V3_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address constant QUOTER_V2 = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;

    /// @dev USDe/USDT 0.01% pool is deployed & deep from ~block 48M.
    uint256 constant FORK_BLOCK = 48_000_000;
    uint24 constant PCS_FEE_TIER = 100;

    uint256 constant USDE_INFLOW = 100_000 ether;

    bool internal _haveFork;
    address public pool;
    uint256 public usdtReceived;

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
            _startPnL();
            console2.log("B13-04: no fork -> graceful hold");
            _endPnL("B13-04: USDe OFT roundtrip [no-fork hold]");
            return;
        }

        require(_hasCode(USDe), "USDe missing");
        pool = IPancakeV3Factory(PCS_V3_FACTORY).getPool(USDe, USDT, PCS_FEE_TIER);
        require(pool != address(0) && _hasCode(pool), "USDe/USDT pool missing");

        // Read live spread: how many USDT does USDE_INFLOW USDe fetch?
        (uint256 quotedOut,,,) = IQuoterV2(QUOTER_V2).quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: USDe,
                tokenOut: USDT,
                amountIn: USDE_INFLOW,
                fee: PCS_FEE_TIER,
                sqrtPriceLimitX96: 0
            })
        );
        console2.log("B13-04: USDe in:", USDE_INFLOW);
        console2.log("B13-04: USDT out (spot):", quotedOut);

        _fund(USDe, address(this), USDE_INFLOW);
        _startPnL();

        // Cross-chain leg (OFT send + ETH redeem) is unexecutable on one fork.
        console2.log("B13-04: OFT cross-chain redeem leg is off-fork -> code-guarded no-op");

        if (quotedOut <= USDE_INFLOW) {
            // USDe at/below par on BSC -> no premium to harvest; hold flat.
            console2.log("B13-04: USDe not at a premium vs USDT -> HOLD FLAT");
            _endPnL("B13-04: USDe OFT roundtrip [no-edge graceful hold]");
            return;
        }

        // Real premium: sell USDe for USDT on-BSC (the leg that IS forkable).
        IERC20(USDe).approve(PCS_V3_ROUTER, USDE_INFLOW);
        usdtReceived = IPCSV3Router(PCS_V3_ROUTER).exactInputSingle(
            IPCSV3Router.ExactInputSingleParams({
                tokenIn: USDe,
                tokenOut: USDT,
                fee: PCS_FEE_TIER,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: USDE_INFLOW,
                amountOutMinimum: (quotedOut * 9999) / 10000,
                sqrtPriceLimitX96: 0
            })
        );
        console2.log("B13-04: executed USDe premium sell, USDT received:", usdtReceived);
        _endPnL("B13-04: USDe BSC<->ETH OFT roundtrip");
    }
}
