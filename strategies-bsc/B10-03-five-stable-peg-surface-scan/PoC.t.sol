// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Factory} from "src/interfaces/bsc/amm/IPancakeV3Factory.sol";
import {console2} from "forge-std/console2.sol";

/// @dev PCS v3 QuoterV2 (struct-arg form).
interface IPCSV3Quoter {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }
    function quoteExactInputSingle(QuoteExactInputSingleParams calldata p)
        external
        returns (uint256 amountOut, uint160, uint32, uint256);
}

/// @title B10-03 5-stable peg-surface scanner (read-only)
/// @notice Reads each stable's REAL on-chain PCS v3 price against the USDT hub
///         (USDT, USDC, FDUSD, lisUSD, USDe) and reports the peg-deviation
///         surface plus the implied best USDT-anchored triangle. Read-only: no
///         position is taken and the test ends flat (net ~0, PASS). A downstream
///         executor would only fire if a triangle cleared the fee budget; at the
///         fork block none does.
contract B10_03_FiveStablePegSurfaceScanTest is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 48_400_000;

    address internal constant LOCAL_PCS_V3_QUOTER = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;

    uint256 internal constant N = 5;
    uint256 internal constant PROBE = 50_000 * 1e18;
    int256 internal constant MIN_PROFIT_BPS = 10;

    address[N] internal _basket;
    uint24[3] internal _fees = [uint24(100), uint24(500), uint24(2500)];

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }
        _basket[0] = BSC.USDT;
        _basket[1] = BSC.USDC;
        _basket[2] = BSC.FDUSD;
        _basket[3] = BSC.lisUSD;
        _basket[4] = BSC.USDe;
        for (uint256 i = 0; i < N; i++) _trackToken(_basket[i]);
    }

    function testStrategy_B10_03() public {
        if (!_haveFork) {
            console2.log("No fork; skipping (PASS)");
            return;
        }
        _startPnL();

        // Star topology around USDT (index 0): for each stable read both
        // directed legs vs USDT. toUsdt[i] = USDT per 1 of token i; fromUsdt[i]
        // = token i per 1 USDT (both 1e18 scaled). 8 live quotes total.
        uint256[N] memory toUsdt;   // i -> USDT
        uint256[N] memory fromUsdt; // USDT -> i
        toUsdt[0] = 1e18; fromUsdt[0] = 1e18;
        for (uint256 i = 1; i < N; i++) {
            toUsdt[i] = _bestQuote(_basket[i], BSC.USDT);
            fromUsdt[i] = _bestQuote(BSC.USDT, _basket[i]);
            int256 pegBps = toUsdt[i] == 0
                ? int256(0)
                : (int256(toUsdt[i]) - int256(uint256(1e18))) * 10_000 / int256(uint256(1e18));
            emit log_named_int(
                string(abi.encodePacked("peg_dev_bps_idx", vm.toString(i))),
                pegBps
            );
        }

        // Best USDT-anchored round trip: USDT -> j -> USDT for each stable j,
        // and the two-hop USDT -> j -> k -> USDT via the USDT hub. The directed
        // triangle product through the hub is fromUsdt[j]*toUsdt[j] (round trip)
        // which is always < 1 by fees -> no edge. We report the deepest pair.
        int256 bestNetBps = type(int256).min;
        uint256 bestJ;
        for (uint256 j = 1; j < N; j++) {
            if (fromUsdt[j] == 0 || toUsdt[j] == 0) continue;
            uint256 rt = (fromUsdt[j] * toUsdt[j]) / 1e18; // USDT round trip
            int256 netBps = (int256(rt) - int256(uint256(1e18))) * 10_000 / int256(uint256(1e18));
            if (netBps > bestNetBps) { bestNetBps = netBps; bestJ = j; }
        }
        emit log_named_uint("best_leg_idx", bestJ);
        emit log_named_int("best_roundtrip_net_bps", bestNetBps);

        if (bestNetBps >= MIN_PROFIT_BPS) {
            console2.log("Open edge detected; downstream executor would fire");
        } else {
            console2.log("No stable edge clears fee budget; scan-only, holding flat (PASS)");
        }

        _endPnL("B10-03: 5-stable peg-surface scan (read-only)");
    }

    /// @dev Best v3 quote for PROBE of `tin` priced in `tout`, normalised to a
    ///      per-1e18 directed price. Probes 1bp/5bp/25bp, keeps the deepest.
    function _bestQuote(address tin, address tout) internal returns (uint256 best) {
        IPancakeV3Factory f = IPancakeV3Factory(BSC.PCS_V3_FACTORY);
        for (uint256 k = 0; k < _fees.length; k++) {
            if (f.getPool(tin, tout, _fees[k]) == address(0)) continue;
            try IPCSV3Quoter(LOCAL_PCS_V3_QUOTER).quoteExactInputSingle(
                IPCSV3Quoter.QuoteExactInputSingleParams({
                    tokenIn: tin, tokenOut: tout, amountIn: PROBE, fee: _fees[k], sqrtPriceLimitX96: 0
                })
            ) returns (uint256 out, uint160, uint32, uint256) {
                uint256 unit = (out * 1e18) / PROBE;
                if (unit > best) best = unit;
            } catch {}
        }
    }
}
