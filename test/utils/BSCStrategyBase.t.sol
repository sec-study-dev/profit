// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "src/interfaces/common/IERC20.sol";
import {BSC} from "src/constants/BSC.sol";

/// @title BSCStrategyBase
/// @notice BSC analogue of `test/utils/StrategyBase.t.sol`. Provides the same
///         PnL / tracking surface (`pnl_usd=`, `gas_usd=`, `net_usd=`) so
///         Wave 3 grep tooling works across both chains.
/// @dev    Differences from the mainnet base:
///         - `_fork` reads `BSC_RPC_URL` (not `RPC_URL`).
///         - No on-chain Chainlink reads by default; prices come from a
///           per-token override map preloaded with stable defaults
///           (BNB $600, BTC $65k, ETH $3k, stables $1).
///         - `_fund` still uses `deal()`; for rebasing / allow-listed tokens
///           on BSC use `test/utils/BSCWhales.sol`.
abstract contract BSCStrategyBase is Test {
    // ---- Tracked-token list & PnL snapshot state ----

    address[] internal _tracked;
    mapping(address => bool) internal _isTracked;

    /// @dev Snapshot of native BNB balance of `address(this)` at _startPnL.
    uint256 internal _bnbStart;
    /// @dev Snapshot of each tracked token's balance.
    mapping(address => uint256) internal _balStart;
    /// @dev gasleft() snapshot at _startPnL.
    uint256 internal _gasStart;
    /// @dev tx.gasprice captured at _startPnL.
    uint256 internal _gasPriceSnap;

    /// @dev Per-token USD price override (1e8 scaled). Preloaded by ctor.
    mapping(address => uint256) internal _priceE8;
    /// @dev BNB/USD fallback used for gas valuation (1e8 scaled).
    uint256 internal _bnbUsdE8;

    constructor() {
        _initDefaultPrices();
    }

    // ---- Fork helpers ----

    /// @notice Create + select a BSC fork at `blockNumber` using $BSC_RPC_URL.
    function _fork(uint256 blockNumber) internal {
        string memory rpc = vm.envString("BSC_RPC_URL");
        vm.createSelectFork(rpc, blockNumber);
    }

    /// @notice Fund `to` with `amount` of `token`.
    /// @dev    Uses `deal()` (Foundry cheatcode). For native BNB use
    ///         `vm.deal(to, amount)` directly. For rebasing tokens or
    ///         allow-listed tokens, see `test/utils/BSCWhales.sol` and use
    ///         `vm.prank(whale)` + `IERC20.transfer`.
    function _fund(address token, address to, uint256 amount) internal {
        deal(token, to, amount);
    }

    // ---- Token tracking ----

    function _trackToken(address token) internal {
        if (token == address(0)) return;
        if (_isTracked[token]) return;
        _isTracked[token] = true;
        _tracked.push(token);
    }

    // ---- Oracle override ----

    /// @notice Set the USD price of `token` (1e8 scaled). Overrides defaults.
    function _setOraclePrice(address token, uint256 priceE8) internal {
        _priceE8[token] = priceE8;
    }

    /// @notice Set the BNB/USD price used for gas valuation (1e8 scaled).
    function _setBnbUsdFallback(uint256 priceE8) internal {
        _bnbUsdE8 = priceE8;
        _priceE8[BSC.WBNB] = priceE8;
        _priceE8[BSC.BNB] = priceE8;
    }

    /// @dev Preload sane defaults so Wave 2 PoCs can run offline-first.
    function _initDefaultPrices() internal {
        // BNB ~ $600
        _bnbUsdE8 = 600e8;
        _priceE8[BSC.WBNB] = 600e8;
        _priceE8[BSC.BNB] = 600e8;
        // BTC ~ $65,000
        _priceE8[BSC.BTCB] = 65_000e8;
        // ETH ~ $3,000
        _priceE8[BSC.WETH] = 3_000e8;
        // BNB LSTs - peg to BNB at $600 (refine via exchangeRate where needed)
        _priceE8[BSC.slisBNB] = 600e8;
        _priceE8[BSC.BNBx] = 600e8;
        _priceE8[BSC.ankrBNB] = 600e8;
        _priceE8[BSC.aBNBc] = 600e8;
        _priceE8[BSC.stkBNB] = 600e8;
        _priceE8[BSC.asBNB] = 600e8;
        // WBETH ~ ETH
        _priceE8[BSC.WBETH] = 3_000e8;
        // Stables ~ $1
        _priceE8[BSC.USDT] = 1e8;
        _priceE8[BSC.USDC] = 1e8;
        _priceE8[BSC.BUSD] = 1e8;
        _priceE8[BSC.FDUSD] = 1e8;
        _priceE8[BSC.USD1] = 1e8;
        _priceE8[BSC.lisUSD] = 1e8;
        _priceE8[BSC.USDe] = 1e8;
        _priceE8[BSC.sUSDe] = 1e8;
        _priceE8[BSC.VAI] = 1e8;
        // BTC-LSDs ~ BTC
        _priceE8[BSC.solvBTC] = 65_000e8;
        _priceE8[BSC.solvBTC_BBN] = 65_000e8;
    }

    // ---- PnL snapshot / report ----

    function _startPnL() internal {
        _bnbStart = address(this).balance;
        for (uint256 i = 0; i < _tracked.length; i++) {
            _balStart[_tracked[i]] = IERC20(_tracked[i]).balanceOf(address(this));
        }
        _gasPriceSnap = tx.gasprice;
        _gasStart = gasleft();
    }

    /// @notice Print PnL block, structurally identical to mainnet base.
    /// @dev    Output:
    ///           ==== STRATEGY <label> ====
    ///           pnl_usd= <int256, 1e6 USD>
    ///           gas_usd= <uint256, 1e6 USD>
    ///           net_usd= <int256, 1e6 USD>
    ///           ========================
    function _endPnL(string memory label) internal {
        uint256 gasUsed = _gasStart > gasleft() ? _gasStart - gasleft() : 0;
        uint256 bnbUsd = _bnbUsdE8;

        // ---- BNB leg ----
        int256 bnbDelta = int256(address(this).balance) - int256(_bnbStart);
        // bnbDelta [wei] * bnbUsd [1e8] -> 1e6 USD requires /1e20.
        int256 pnlE6 = _scaleSigned(bnbDelta, bnbUsd, 1e20);

        // ---- Token legs ----
        for (uint256 i = 0; i < _tracked.length; i++) {
            address tk = _tracked[i];
            uint256 priceE8 = _priceE8[tk];
            if (priceE8 == 0) continue;
            uint256 dec = _decimalsOf(tk);
            int256 bal = int256(IERC20(tk).balanceOf(address(this)));
            int256 prev = int256(_balStart[tk]);
            int256 delta = bal - prev;
            // delta * priceE8 / 10**dec gives 1e8 USD. /1e2 -> 1e6 USD.
            uint256 scale = 10 ** dec * 1e2;
            pnlE6 += _scaleSigned(delta, priceE8, scale);
        }

        // ---- Gas leg ----
        uint256 gasUsdE6 = 0;
        if (bnbUsd > 0 && _gasPriceSnap > 0) {
            gasUsdE6 = (gasUsed * _gasPriceSnap * bnbUsd) / 1e26;
        }

        int256 netE6 = pnlE6 - int256(gasUsdE6);

        console2.log("==== STRATEGY", label, "====");
        console2.log("pnl_usd=", pnlE6);
        console2.log("gas_usd=", gasUsdE6);
        console2.log("net_usd=", netE6);
        console2.log("========================");
    }

    // ---- Internal helpers ----

    function _decimalsOf(address token) internal view returns (uint256) {
        try IERC20(token).decimals() returns (uint8 d) {
            return uint256(d);
        } catch {
            return 18;
        }
    }

    function _scaleSigned(int256 delta, uint256 mul, uint256 div) internal pure returns (int256) {
        if (delta == 0 || mul == 0 || div == 0) return 0;
        if (delta >= 0) {
            return int256((uint256(delta) * mul) / div);
        } else {
            return -int256((uint256(-delta) * mul) / div);
        }
    }

    // Allow the test contract to receive BNB (e.g. from WBNB.withdraw).
    receive() external payable {}
}
