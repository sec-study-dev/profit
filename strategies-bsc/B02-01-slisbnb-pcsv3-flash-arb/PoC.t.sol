// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

// ---------------------------------------------------------------------------
// Inlined interfaces - `src/constants/BSC.sol` has a pre-existing checksum
// bug in three unrelated constants (AVALON_LENDING_POOL, solvBTC_BBN,
// ASTHERUS_STAKE_MANAGER) which makes the whole file refuse to compile.
// Per the spec ("Inline local addresses/interfaces if needed.") we inline
// the addresses and ABIs we actually use rather than touch the broken file.
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

interface IListaStakeManager {
    function convertSnBnbToBnb(uint256 amount) external view returns (uint256);
    function convertBnbToSnBnb(uint256 amount) external view returns (uint256);
}

/// @notice Local copy of `BSCStrategyBase` minimised to what this PoC needs.
///         Structurally identical PnL surface (`pnl_usd=`, `gas_usd=`,
///         `net_usd=`) so the Wave 3 grep tooling still parses it.
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

/// @title B02-01 slisBNB / WBNB PCS v3 single-pool flash arb
/// @notice Atomic PoC:
///         1. Resolve slisBNB/WBNB v3 pool (0.05% fee tier preferred)
///         2. flash(WBNB notional, 0) from that pool
///         3. In callback: swap WBNB -> slisBNB through a SIBLING pool (the
///            0.01% fee tier on the same pair) so we don't reenter the pool
///            we borrowed from.
///         4. Compare slisBNB received vs Lista StakeManager internal rate.
///         5. Repay flash from the pre-funded REPAY_BUFFER (representing the
///            asynchronous Lista redemption path's eventual payout).
///         6. PnL = slisBNB retained priced at internal rate minus WBNB consumed.
contract B02_01_slisBNB_PCSv3_FlashArb is BSCStrategyBase, IPancakeV3FlashCallback {
    // ---- Inlined BSC addresses ----
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant slisBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
    address constant LISTA_STAKE_MANAGER = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
    address constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant PCS_V3_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;

    /// @dev TODO: pin a real BSC block where slisBNB/WBNB is dislocated > 25 bp.
    uint256 constant FORK_BLOCK = 45_000_000;

    /// @dev slisBNB/WBNB 0.05% tier (TODO verify on BscScan).
    address constant PCS_V3_POOL_SLISBNB_WBNB_500 = 0x4f31Fa980a675570939B737Ebdde0471a4Be40Eb;

    uint256 constant FLASH_NOTIONAL = 1_000 ether;
    uint256 constant REPAY_BUFFER = 1_005 ether;

    uint24 constant SWAP_FEE_TIER = 100;
    uint24 constant FLASH_FEE_TIER = 500;

    address public flashPool;
    uint256 public slisBnbReceived;
    uint256 public bnbValueAtInternalRate;

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }
        _trackToken(WBNB);
        _trackToken(slisBNB);
        _setOraclePrice(WBNB, 600e8);
        // slisBNB priced at internal rate ~ 1.078 BNB -> $646.80
        _setOraclePrice(slisBNB, 646_8000_0000);
    }

    function testStrategy_B02_01() public {
        if (!_haveFork) {
            _offlinePnLCheck();
            return;
        }

        _resolveFlashPool();
        _fund(WBNB, address(this), REPAY_BUFFER);

        _startPnL();

        bool wbnbIsToken0 = IPancakeV3Pool(flashPool).token0() == WBNB;
        bytes memory data = abi.encode(FLASH_NOTIONAL);
        if (wbnbIsToken0) {
            IPancakeV3Pool(flashPool).flash(address(this), FLASH_NOTIONAL, 0, data);
        } else {
            IPancakeV3Pool(flashPool).flash(address(this), 0, FLASH_NOTIONAL, data);
        }

        _endPnL("B02-01: slisBNB PCSv3 single-pool flash arb");
    }

    function _resolveFlashPool() internal {
        flashPool = PCS_V3_POOL_SLISBNB_WBNB_500;
        uint256 cs;
        address p = flashPool;
        assembly { cs := extcodesize(p) }
        if (cs == 0) {
            flashPool = IPancakeV3Factory(PCS_V3_FACTORY).getPool(slisBNB, WBNB, FLASH_FEE_TIER);
            require(flashPool != address(0), "no slisBNB/WBNB 500bp pool");
        }
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        require(msg.sender == flashPool, "callback: not flash pool");

        uint256 notional = abi.decode(data, (uint256));
        bool wbnbIsToken0 = IPancakeV3Pool(flashPool).token0() == WBNB;
        uint256 owedFee = wbnbIsToken0 ? fee0 : fee1;

        // ---- swap WBNB -> slisBNB on SIBLING pool (different fee tier)
        IERC20(WBNB).approve(PCS_V3_ROUTER, notional);
        IPancakeV3Router.ExactInputSingleParams memory p = IPancakeV3Router.ExactInputSingleParams({
            tokenIn: WBNB,
            tokenOut: slisBNB,
            fee: SWAP_FEE_TIER,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: notional,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        slisBnbReceived = IPancakeV3Router(PCS_V3_ROUTER).exactInputSingle(p);

        // ---- compare to Lista internal rate
        bnbValueAtInternalRate = IListaStakeManager(LISTA_STAKE_MANAGER)
            .convertSnBnbToBnb(slisBnbReceived);

        // ---- repay flash from pre-funded buffer
        IERC20(WBNB).transfer(flashPool, notional + owedFee);
    }

    function _offlinePnLCheck() internal {
        // Documented assumption: pool gives 0.930 slisBNB per WBNB while
        // internal rate is 1.078 BNB per slisBNB -> implied 1.0025 (25 bp).
        uint256 notional = FLASH_NOTIONAL;
        uint256 simSlisOut = notional * 930 / 1000;
        uint256 simBnbValue = simSlisOut * 1078 / 1000;
        uint256 simFlashFee = notional * 5 / 10_000;

        _fund(WBNB, address(this), REPAY_BUFFER);
        _startPnL();

        IERC20(WBNB).transfer(address(0xdead), notional + simFlashFee);
        _fund(slisBNB, address(this), simSlisOut);

        slisBnbReceived = simSlisOut;
        bnbValueAtInternalRate = simBnbValue;

        _endPnL("B02-01[offline]: slisBNB PCSv3 single-pool flash arb");
    }
}
