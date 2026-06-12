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

interface IPendleMarket {
    function expiry() external view returns (uint256);
    function readTokens() external view returns (address sy, address pt, address yt);
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

/// @title B13-08 Pendle PT-sUSDe cross-chain spread (BSC <-> ETH)
/// @notice Thesis: PT-sUSDe trades at a different implied yield on a BSC Pendle
///         market than on Ethereum; you buy the cheaper PT on BSC, bridge the
///         underlying (ENA/sUSDe OFT) to ETH, and unwind into the richer PT.
///         The cross-chain settlement (OFT send + ETH-side Pendle leg) CANNOT
///         execute on a single BSC fork.
/// @dev    REALITY ON-FORK: there is NO Pendle PT-sUSDe market deployed on BSC
///         at any block in the usable archive range (the market / PT token are
///         absent), and the ENA OFT adapter address is unpublished/no-code. So
///         neither the on-BSC PT leg nor the cross-chain leg is executable. Per
///         the playbook this is a faithful GRACEFUL HOLD: we verify the forkable
///         underlying infra (USDe/USDT PCS v3 pool), probe for the PT market,
///         surface its absence, and hold flat (net ~0). No fabricated profit.
contract B13_08_Pendle_PT_sUSDe_XChain is BSCStrategyBase {
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant USDe = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34;
    address constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;

    /// @notice Pendle PT-sUSDe market on BSC - absent across the fork range.
    address constant PT_SUSDE_MARKET_BSC = address(0);
    /// @notice ENA / sUSDe OFT adapter on BSC - unpublished / no code.
    address constant ENA_OFT_ADAPTER = address(0);

    /// @dev USDe/USDT pool is live from ~48M (underlying forkable infra).
    uint256 constant FORK_BLOCK = 48_000_000;
    uint24 constant SWAP_FEE_TIER_USDe_USDT = 100;

    bool internal _haveFork;
    address public underlyingPool;

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

    function testStrategy_B13_08() public {
        _startPnL();

        if (!_haveFork) {
            console2.log("B13-08: no fork -> graceful hold");
            _endPnL("B13-08: PT-sUSDe cross-chain [no-fork hold]");
            return;
        }

        // Verify forkable underlying infra: the USDe/USDT PCS v3 pool.
        underlyingPool = IPancakeV3Factory(PCS_V3_FACTORY).getPool(USDe, USDT, SWAP_FEE_TIER_USDe_USDT);
        if (underlyingPool != address(0) && _hasCode(underlyingPool)) {
            console2.log("B13-08: USDe/USDT underlying pool present:", underlyingPool);
        }

        // Probe for a Pendle PT-sUSDe market on BSC.
        if (PT_SUSDE_MARKET_BSC == address(0) || !_hasCode(PT_SUSDE_MARKET_BSC)) {
            console2.log("B13-08: no Pendle PT-sUSDe market on BSC -> on-BSC PT leg unexecutable; HOLD FLAT");
        }
        if (ENA_OFT_ADAPTER == address(0) || !_hasCode(ENA_OFT_ADAPTER)) {
            console2.log("B13-08: no ENA/sUSDe OFT adapter on BSC -> cross-chain leg unexecutable; HOLD FLAT");
        }
        _endPnL("B13-08: Pendle PT-sUSDe cross-chain spread [cross-chain graceful hold]");
    }
}
