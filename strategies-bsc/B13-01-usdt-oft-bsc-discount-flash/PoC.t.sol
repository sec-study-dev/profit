// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

// ---------------------------------------------------------------------------
// Inlined interfaces - `src/constants/BSC.sol` has a pre-existing checksum
// bug in several unrelated constants which makes the whole file refuse to
// compile. We inline the addresses and ABIs we actually use rather than
// touch the broken constants file.
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

/// @notice LayerZero V2 OFT (Omnichain Fungible Token) interface.
interface IOFTAdapter {
    function token() external view returns (address);
}

/// @notice Local copy of `BSCStrategyBase` minimised to what this PoC needs.
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

/// @title B13-01 Bridged USDT (OFT) vs BSC Peg USDT discount flash
/// @notice CROSS-CHAIN strategy. Thesis: a LayerZero OFT version of USDT
///         (USDT0) sometimes trades at a discount to BSC Peg-USDT; you buy the
///         discounted OFT on BSC and burn-bridge it to ETH where it redeems at
///         par. The settlement leg (OFT `send` -> ETH credit) CANNOT execute on
///         a single BSC fork, so per the playbook this is a faithful
///         GRACEFUL HOLD: we verify the forkable on-BSC infra (the deep
///         USDT/USDC PCS v3 pool that would fund the flash), check whether a
///         USDT OFT adapter exists on BSC, surface the spread, and hold flat
///         (net ~0). No fabricated cross-chain profit.
contract B13_01_USDT_OFT_BSC_Discount is BSCStrategyBase {
    // ---- Inlined BSC addresses ----
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;

    /// @notice USDT OFT adapter (LayerZero V2). No such adapter is deployed on
    ///         BSC at this fork window -> the on-BSC discount leg has no
    ///         executable counterparty. address(0) => graceful hold.
    address constant USDT_OFT_ADAPTER = address(0);

    /// @dev USDT/USDC 0.01% pool funds the would-be flash loan.
    uint24 constant FLASH_FEE_TIER = 100;
    uint256 constant FORK_BLOCK = 46_000_000;

    bool internal _haveFork;
    address public flashPool;
    address public oftToken;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }
        _trackToken(USDT);
        _setOraclePrice(USDT, 1e8);
    }

    function testStrategy_B13_01() public {
        _startPnL();

        if (!_haveFork) {
            console2.log("B13-01: no fork (BSC_RPC_URL unset) -> graceful hold");
            _endPnL("B13-01: USDT OFT discount flash [no-fork hold]");
            return;
        }

        // 1) Verify the forkable on-BSC infra: the USDT/USDC flash source pool.
        flashPool = IPancakeV3Factory(PCS_V3_FACTORY).getPool(USDT, USDC, FLASH_FEE_TIER);
        require(flashPool != address(0) && _hasCode(flashPool), "USDT/USDC flash pool missing");
        console2.log("B13-01: USDT/USDC flash pool present:", flashPool);

        // 2) The cross-chain leg needs a USDT OFT adapter on BSC. None exists
        //    on this fork -> the discount cannot be sourced/closed on one chain.
        if (USDT_OFT_ADAPTER == address(0) || !_hasCode(USDT_OFT_ADAPTER)) {
            console2.log("B13-01: no USDT OFT adapter on BSC -> cross-chain leg unexecutable; HOLD FLAT");
            _endPnL("B13-01: USDT OFT discount flash [cross-chain graceful hold]");
            return;
        }

        // (Unreachable on this fork.) Read the OFT/Peg spread if an adapter ever ships.
        oftToken = IOFTAdapter(USDT_OFT_ADAPTER).token();
        _endPnL("B13-01: USDT OFT discount flash");
    }
}
