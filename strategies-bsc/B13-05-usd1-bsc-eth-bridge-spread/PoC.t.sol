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

interface IPancakeV3Pool {
    function liquidity() external view returns (uint128);
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

/// @title B13-05 USD1 BSC <-> ETH bridge spread
/// @notice Thesis: World Liberty Financial's USD1 launches with a thin BSC
///         market and an official OFT bridge; in early distribution windows
///         USD1 trades at a discount on BSC that the ETH-side redeem closes.
/// @dev    REALITY ON-FORK: USD1 (0x8d0D...0B0d) has code from ~block 47.5M, but
///         NO PancakeSwap v3 pool exists against USDT/USDC/WBNB at any fork
///         block in range, and the WLF OFT adapter address is unpublished /
///         not on BSC. So there is neither an on-BSC swap leg nor a settleable
///         cross-chain leg. Per the playbook this is a faithful GRACEFUL HOLD:
///         verify code, probe for a pool, surface the absence, hold flat (~0).
contract B13_05_USD1_BSC_ETH_Bridge_Spread is BSCStrategyBase {
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d; // WLF USD1 on BSC
    address constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;

    /// @notice WLF USD1 OFT adapter on BSC - not deployed at this fork window.
    address constant USD1_OFT_ADAPTER = address(0);

    /// @dev USD1 has code from ~47.5M.
    uint256 constant FORK_BLOCK = 47_500_000;
    uint24[2] FEE_TIERS = [uint24(100), uint24(500)];

    bool internal _haveFork;
    address public pool;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }
        _trackToken(USDT);
        _trackToken(USD1);
        _setOraclePrice(USDT, 1e8);
        _setOraclePrice(USD1, 1e8);
    }

    function testStrategy_B13_05() public {
        _startPnL();

        if (!_haveFork) {
            console2.log("B13-05: no fork -> graceful hold");
            _endPnL("B13-05: USD1 bridge spread [no-fork hold]");
            return;
        }

        if (!_hasCode(USD1)) {
            console2.log("B13-05: USD1 not yet deployed at fork block -> HOLD FLAT");
            _endPnL("B13-05: USD1 bridge spread [pre-launch hold]");
            return;
        }
        console2.log("B13-05: USD1 deployed on BSC:", USD1);

        // Probe for any USD1 swap venue on PCS v3.
        uint128 bestLiq = 0;
        address[2] memory quotes = [USDT, USDC];
        for (uint256 q = 0; q < quotes.length; q++) {
            for (uint256 i = 0; i < FEE_TIERS.length; i++) {
                address p = IPancakeV3Factory(PCS_V3_FACTORY).getPool(USD1, quotes[q], FEE_TIERS[i]);
                if (p == address(0) || !_hasCode(p)) continue;
                uint128 liq = IPancakeV3Pool(p).liquidity();
                if (liq > bestLiq) { bestLiq = liq; pool = p; }
            }
        }

        if (pool == address(0) || bestLiq == 0) {
            console2.log("B13-05: no liquid USD1 PCS v3 pool -> on-BSC leg unexecutable; HOLD FLAT");
        }
        if (USD1_OFT_ADAPTER == address(0) || !_hasCode(USD1_OFT_ADAPTER)) {
            console2.log("B13-05: no USD1 OFT adapter on BSC -> cross-chain leg unexecutable; HOLD FLAT");
        }
        _endPnL("B13-05: USD1 BSC<->ETH bridge spread [cross-chain graceful hold]");
    }
}
