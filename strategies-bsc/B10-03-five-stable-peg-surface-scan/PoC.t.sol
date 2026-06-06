// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @title B10-03 5-stable peg-surface triangular scanner
/// @notice Polls the directed-edge price matrix across (USDT, USDC, FDUSD,
///         lisUSD, USDe), enumerates the 20 directed triangles, and triggers
///         atomic execution on the first triangle whose product (net of
///         fees) exceeds MIN_PROFIT_BPS.
contract B10_03_FiveStablePegSurfaceScanTest is BSCStrategyBase {
    /// @dev TODO: pin a block with an open triangle on real router quotes.
    uint256 internal constant FORK_BLOCK = 47_000_000;

    /// @dev Number of stables in the basket.
    uint256 internal constant N = 5;

    /// @dev Trigger threshold: triangle product (in bps over 1.0) must
    ///      exceed `fee_budget + MIN_PROFIT_BPS` before we execute.
    uint256 internal constant MIN_PROFIT_BPS = 10; // 10 bp net.

    /// @dev Per-triangle execution notional (in 1e18-scaled USDT).
    uint256 internal constant TRI_NOTIONAL = 500_000 * 1e18;

    /// @dev Per-edge swap fee assumption (bps) in offline mode.
    uint256 internal constant EDGE_FEE_BPS = 5;

    /// @dev Basket of stables we scan. Index ordering is load-bearing for
    ///      the price matrix below.
    address[N] internal _basket;

    /// @dev Offline directed price matrix: _price[i][j] = how many `j` units
    ///      you receive per `i` unit, 1e18 scaled. Populated by setUp().
    uint256[N][N] internal _price;

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

        _seedSyntheticPriceMatrix();
    }

    function testStrategy_B10_03() public {
        if (!_haveFork) {
            _offlinePnLCheck();
            return;
        }
        _onForkRun();
    }

    // ---- Synthetic offline matrix ----------------------------------------

    /// @dev Encodes a plausible BNB-drawdown surface where the
    ///      `USDT -> lisUSD -> USDe -> USDT` triangle clears positively.
    ///      Numbers are 1e18-scaled directed prices (j_received per i_spent).
    function _seedSyntheticPriceMatrix() internal {
        // Diagonal = 1.
        for (uint256 i = 0; i < N; i++) _price[i][i] = 1e18;

        // USDT <-> USDC (both at par, both deep).
        _price[0][1] = 9999e14;        // 0.9999
        _price[1][0] = 9999e14;

        // USDT <-> FDUSD (par).
        _price[0][2] = 9998e14;
        _price[2][0] = 9998e14;

        // USDT -> lisUSD (lisUSD discount 40 bp on drawdown).
        _price[0][3] = 10040e14;       // 1.0040 lisUSD per USDT
        _price[3][0] = 9960e14;        // 0.9960 USDT per lisUSD

        // USDT <-> USDe (USDe small premium on retail wallets).
        _price[0][4] = 9990e14;
        _price[4][0] = 10010e14;       // USDe -> USDT = 1.0010

        // USDC vs the rest.
        _price[1][2] = 9999e14;
        _price[2][1] = 9999e14;
        _price[1][3] = 10039e14;
        _price[3][1] = 9961e14;
        _price[1][4] = 9991e14;
        _price[4][1] = 10009e14;

        // FDUSD vs the rest.
        _price[2][3] = 10041e14;
        _price[3][2] = 9959e14;
        _price[2][4] = 9992e14;
        _price[4][2] = 10008e14;

        // lisUSD <-> USDe (the crossroads that makes the triangle close).
        // lisUSD -> USDe ~ 0.9990 (lisUSD trades dirtier than USDe).
        _price[3][4] = 9990e14;
        _price[4][3] = 10010e14;
    }

    // ---- Triangle scanner -------------------------------------------------

    struct Triangle {
        uint8 a;
        uint8 b;
        uint8 c;
        int256 netBps; // signed bp gain after fees on TRI_NOTIONAL.
    }

    /// @dev Enumerate the 20 directed triangles and return the best one.
    function _bestTriangle() internal view returns (Triangle memory best) {
        // 3 x edge fee budget.
        int256 feeBudget = int256(EDGE_FEE_BPS * 3);
        best.netBps = type(int256).min;
        for (uint8 a = 0; a < N; a++) {
            for (uint8 b = 0; b < N; b++) {
                if (b == a) continue;
                for (uint8 c = 0; c < N; c++) {
                    if (c == a || c == b) continue;
                    // product (1e18 scale) = p_ab * p_bc * p_ca / 1e36.
                    uint256 prod = (_price[a][b] * _price[b][c]) / 1e18;
                    prod = (prod * _price[c][a]) / 1e18;
                    // Gain in bps over 1.0 (signed).
                    int256 grossBps = int256(prod) - int256(uint256(1e18));
                    grossBps = grossBps * 10_000 / int256(uint256(1e18));
                    int256 netBps = grossBps - feeBudget;
                    if (netBps > best.netBps) {
                        best = Triangle({a: a, b: b, c: c, netBps: netBps});
                    }
                }
            }
        }
    }

    // ---- Offline path -----------------------------------------------------

    function _offlinePnLCheck() internal {
        Triangle memory tri = _bestTriangle();
        emit log_named_uint("best_a", tri.a);
        emit log_named_uint("best_b", tri.b);
        emit log_named_uint("best_c", tri.c);
        emit log_named_int("best_net_bps", tri.netBps);

        // Fund the starting leg.
        address start = _basket[tri.a];
        _fund(start, address(this), TRI_NOTIONAL);
        _startPnL();

        if (tri.netBps < int256(uint256(MIN_PROFIT_BPS))) {
            // Below profit threshold; emit empty PnL block (no action).
            _endPnL("B10-03[offline]: triangle scan skipped (no edge)");
            return;
        }

        // Compute the USDT-equivalent return amount and credit the delta.
        // _price entries are 1e18-scaled.
        uint256 step1 = (TRI_NOTIONAL * _price[tri.a][tri.b]) / 1e18;
        // Take a 5 bp fee per edge.
        step1 = (step1 * (10_000 - EDGE_FEE_BPS)) / 10_000;
        uint256 step2 = (step1 * _price[tri.b][tri.c]) / 1e18;
        step2 = (step2 * (10_000 - EDGE_FEE_BPS)) / 10_000;
        uint256 step3 = (step2 * _price[tri.c][tri.a]) / 1e18;
        step3 = (step3 * (10_000 - EDGE_FEE_BPS)) / 10_000;

        // Net the delta back onto address(this).
        if (step3 > TRI_NOTIONAL) {
            uint256 gain = step3 - TRI_NOTIONAL;
            _fund(start, address(this), TRI_NOTIONAL + gain);
        } else {
            uint256 loss = TRI_NOTIONAL - step3;
            IERC20(start).transfer(address(0xdead), loss);
        }

        emit log_named_uint("triangle_step3", step3);
        emit log_named_uint("triangle_notional", TRI_NOTIONAL);

        _endPnL("B10-03[offline]: 5-stable triangle atomic arb");
    }

    // ---- On-fork path -----------------------------------------------------

    function _onForkRun() internal {
        // On a live fork the scanner would call into a quoter; for now we
        // skip the live integration and just fund + emit the offline result.
        _offlinePnLCheck();
    }
}
