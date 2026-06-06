// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "src/interfaces/common/IERC20.sol";
import {PriceOracle} from "test/utils/PriceOracle.sol";

/// @title StrategyBase
/// @notice Shared base class for every strategy PoC. Provides:
///         - fork helper (`_fork`)
///         - token funding helpers (`_fund`)
///         - tracked-token list (`_trackToken`)
///         - PnL snapshot/diff with USD valuation (`_startPnL`/`_endPnL`)
///         - ETH/USD override for environments where the Chainlink feed is unusable
abstract contract StrategyBase is Test {
    // ---- Tracked-token list & PnL snapshot state ----

    address[] internal _tracked;
    mapping(address => bool) internal _isTracked;

    /// @dev Snapshot of native ETH balance of `address(this)` at _startPnL.
    uint256 internal _ethStart;
    /// @dev Snapshot of each tracked token's balance of `address(this)` at _startPnL.
    mapping(address => uint256) internal _balStart;
    /// @dev gasleft() snapshot at _startPnL.
    uint256 internal _gasStart;
    /// @dev tx.gasprice captured at _startPnL (forge-test default is 0 unless overridden).
    uint256 internal _gasPriceSnap;
    /// @dev If non-zero, used in place of Chainlink ETH/USD. 8 decimals.
    uint256 internal _ethUsdFallback;
    /// @dev Extra PnL (6-decimal USD) from on-chain positions whose value is
    ///      parked inside a lending/vault protocol and therefore invisible to the
    ///      address-balance accounting. Strategies credit it via
    ///      `_creditPositionEquityE8` before calling `_endPnL`.
    int256 internal _positionPnlE6;
    /// @dev block.number captured at _startPnL; used to report the strategy's
    ///      block span (cross-block hold horizon) at _endPnL.
    uint256 internal _blockStart;

    // ---- Fork helpers ----

    /// @notice Create + select a mainnet fork at `blockNumber` using $RPC_URL.
    function _fork(uint256 blockNumber) internal {
        string memory rpc = vm.envString("RPC_URL");
        vm.createSelectFork(rpc, blockNumber);
    }

    /// @notice Fund `to` with `amount` of `token`.
    /// @dev    Uses `deal()` which writes balance directly via storage. This works
    ///         for most ERC20s but BREAKS for rebasing tokens (stETH, OETH, USDM)
    ///         and for tokens that gate transfers via allow-lists. For those:
    ///         use a `vm.prank(whale)` + `IERC20.transfer(to, amount)` instead.
    ///         See `test/utils/Whales.sol`.
    function _fund(address token, address to, uint256 amount) internal {
        deal(token, to, amount);
    }

    // ---- Token tracking ----

    /// @notice Add `token` to the list whose `address(this)` balance is tracked
    ///         across `_startPnL`/`_endPnL`. Idempotent.
    function _trackToken(address token) internal {
        if (token == address(0)) return;
        if (_isTracked[token]) return;
        _isTracked[token] = true;
        _tracked.push(token);
    }

    /// @notice Credit (or debit) the USD value of an open on-chain position so the
    ///         reported PnL captures value parked inside a lending/vault protocol
    ///         that the address-balance accounting cannot see. `equityE8` is the
    ///         position's net equity (collateral - debt) in 1e8-scaled USD — the
    ///         same convention Aave/Spark `getUserAccountData` returns. Because the
    ///         tokens spent to build the position were already captured as negative
    ///         balance deltas, adding the end equity yields the true round-trip PnL
    ///         WITHOUT a separate unwind. Call once, after the position is final and
    ///         before `_endPnL`. Only valid for positions funded from tracked
    ///         balances (real swaps/mints) — do NOT use with free-`deal()` collateral.
    function _creditPositionEquityE8(int256 equityE8) internal {
        _positionPnlE6 += equityE8 / 100; // 1e8 USD -> 1e6 USD
    }

    /// @notice Same as above but with a value already in 6-decimal USD.
    function _creditPositionEquityE6(int256 equityE6) internal {
        _positionPnlE6 += equityE6;
    }

    /// @notice Manual override of ETH/USD price (8 decimals). Useful when the
    ///         fork's Chainlink aggregator is stale or when running against
    ///         non-mainnet test fixtures.
    function _setEthUsdFallback(uint256 priceE8) internal {
        _ethUsdFallback = priceE8;
    }

    // ---- PnL snapshot / report ----

    /// @notice Snapshot ETH + tracked-token balances and gasleft().
    function _startPnL() internal {
        _positionPnlE6 = 0;
        _blockStart = block.number;
        _ethStart = address(this).balance;
        for (uint256 i = 0; i < _tracked.length; i++) {
            _balStart[_tracked[i]] = IERC20(_tracked[i]).balanceOf(address(this));
        }
        _gasPriceSnap = tx.gasprice;
        _gasStart = gasleft();
    }

    /// @notice Print PnL block for grepping by Wave 3.
    /// @dev Output format (1 line each, leading `==== STRATEGY <label> ====`):
    ///         pnl_usd = sum_i ((balance_end_i - balance_start_i) * priceUSD_i / 10**dec_i)
    ///                   + (ETHbalance_end - ETHbalance_start) * ETHUSD / 1e18
    ///         gas_usd  = gasUsed * gasPriceSnap * ETHUSD / 1e26
    ///                   (gasUsed: dimensionless, gasPriceSnap: wei, ETHUSD: 1e8
    ///                    -> wei*1e8 = 1e18*1e8 = 1e26 to reach 1e6 USD denomination)
    ///         net_usd  = pnl_usd - gas_usd
    ///       All values in 6-decimal USD (USDC convention).
    function _endPnL(string memory label) internal {
        uint256 gasUsed = _gasStart > gasleft() ? _gasStart - gasleft() : 0;
        uint256 ethUsd = _resolveEthUsd();

        // ---- ETH leg ----
        int256 ethDelta = int256(address(this).balance) - int256(_ethStart);
        // ethDelta (wei) * ethUsd (1e8) -> need to scale to 1e6 USD
        // wei * 1e8  /  1e18 = 1e8 USD-scaled per wei delta... no:
        //   ethDelta [wei] = ethDelta / 1e18 [ETH]
        //   USD     = ETH * ethUsd / 1e8
        //   USDe6   = USD * 1e6 = ethDelta * ethUsd * 1e6 / (1e18 * 1e8) = ethDelta * ethUsd / 1e20
        int256 pnlE6 = _scaleSigned(ethDelta, ethUsd, 1e20);

        // ---- Token legs ----
        for (uint256 i = 0; i < _tracked.length; i++) {
            address tk = _tracked[i];
            uint256 priceE8 = PriceOracle.priceUSD(tk);
            if (priceE8 == 0) continue;
            uint256 dec = _decimalsOf(tk);
            int256 bal = int256(IERC20(tk).balanceOf(address(this)));
            int256 prev = int256(_balStart[tk]);
            int256 delta = bal - prev;
            // Token amount * priceE8 / 10**dec gives 1e8 USD. Want 1e6 USD.
            // USDe6 = delta * priceE8 / 10**dec / 1e2
            uint256 scale = 10 ** dec * 1e2;
            pnlE6 += _scaleSigned(delta, priceE8, scale);
        }

        // ---- Gas leg ----
        // gas_usd_e6 = gasUsed * gasPrice (wei) * ethUsd (1e8) / 1e26
        uint256 gasUsdE6 = 0;
        if (ethUsd > 0 && _gasPriceSnap > 0) {
            gasUsdE6 = (gasUsed * _gasPriceSnap * ethUsd) / 1e26;
        }

        // ---- On-chain position leg (parked collateral - debt) ----
        pnlE6 += _positionPnlE6;

        int256 netE6 = pnlE6 - int256(gasUsdE6);

        console2.log("==== STRATEGY", label, "====");
        console2.log("pnl_usd=", pnlE6);
        console2.log("gas_usd=", gasUsdE6);
        console2.log("net_usd=", netE6);
        // ---- Additive cost telemetry (does not affect the lines above) ----
        // Real execution-cost inputs for the reports/ETH_cost report: gas used by
        // the strategy body (_startPnL..._endPnL), the fork block's base fee as a
        // realistic gas price, and the ETH/USD used. fee_eth, gas-inclusive
        // net_usd and net_eth are derived from these off-chain.
        console2.log("gas_used=", gasUsed);
        console2.log("gas_price_basefee_wei=", block.basefee);
        console2.log("eth_usd_e8=", ethUsd);
        // Block span from first to last strategy operation (= total vm.roll
        // advance between _startPnL and _endPnL). 0 => single-block / atomic.
        console2.log("block_span=", block.number - _blockStart);
        console2.log("========================");
    }

    // ---- Internal helpers ----

    function _resolveEthUsd() internal view returns (uint256) {
        if (_ethUsdFallback != 0) return _ethUsdFallback;
        uint256 onChain = PriceOracle.ethUsdE8();
        if (onChain != 0) return onChain;
        // Try environment variable as last resort. ETH_USD_PRICE is decimal USD.
        try vm.envUint("ETH_USD_PRICE") returns (uint256 raw) {
            if (raw != 0) return raw * 1e8;
        } catch {}
        return 0;
    }

    function _decimalsOf(address token) internal view returns (uint256) {
        try IERC20(token).decimals() returns (uint8 d) {
            return uint256(d);
        } catch {
            return 18;
        }
    }

    /// @dev Computes (delta * mul / div) preserving sign and avoiding intermediate overflow
    ///      for typical-range inputs. delta is a token-amount delta; mul/div fit in 1e30.
    function _scaleSigned(int256 delta, uint256 mul, uint256 div) internal pure returns (int256) {
        if (delta == 0 || mul == 0 || div == 0) return 0;
        if (delta >= 0) {
            return int256((uint256(delta) * mul) / div);
        } else {
            return -int256((uint256(-delta) * mul) / div);
        }
    }

    // Allow the test contract to receive ETH (e.g. from WETH.withdraw).
    receive() external payable {}
}
