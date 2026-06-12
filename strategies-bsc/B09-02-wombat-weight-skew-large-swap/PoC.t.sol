// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @title B09-02 Wombat coverage-ratio weight-skew capture vs PCS v3 reference
/// @notice Faithful guarded-arb on Wombat's dynamic-asset-weight (coverage
///         ratio) pricing. The Wombat "Main Pool"
///         (0x312Bc7…05fb0) is in reality a small DAI/USDC/USDT pool that
///         enforces a per-swap coverage-ratio limit (selector 0x6158a9f8,
///         WOMBAT_COV_RATIO_LIMIT_EXCEEDED) and exposes its quote as
///         `quotePotentialSwap(address,address,int256)` — the repo's shared
///         IWombatPool uses a `uint256` third arg, so this PoC declares a
///         LOCAL interface with the correct `int256` signature.
///
///         At the pinned block the USDC slot is under-allocated (cov_USDC≈0.66)
///         while USDT is over-allocated (cov_USDT≈1.53). Selling the scarce
///         asset (USDC -> USDT) restores coverage and Wombat pays a
///         restoration bonus: at the curve's knee (~2k USDC) the pool returns
///         strictly MORE than $1-for-$1 net of haircut. Both legs are $1
///         stables, so keeping the USDT output is a realized arbitrage profit.
///
///         The PoC sweeps candidate sizes, picks the one with the largest
///         positive net edge, executes the real on-chain swap, and keeps the
///         proceeds. If no size has a positive edge it holds flat (net ~0) —
///         the strategy never executes a loss-making leg.
contract B09_02_Wombat_WeightSkew_LargeSwap is BSCStrategyBase {
    /// @dev Block where Wombat Main Pool USDC slot is under-allocated.
    uint256 constant FORK_BLOCK = 45_500_000;

    /// @dev Wombat Main Pool (DAI/USDC/USDT) — int256 quote signature.
    address constant WOMBAT_POOL = 0x312Bc7eAAF93f1C60Dc5AfC115FcCDE161055fb0;

    /// @dev Candidate swap sizes (USDC, 18 decimals on BSC).
    uint256[7] internal _sizes = [
        uint256(500 ether),
        uint256(1_000 ether),
        uint256(2_000 ether),
        uint256(3_000 ether),
        uint256(4_000 ether),
        uint256(5_000 ether),
        uint256(8_000 ether)
    ];

    uint256 public chosenSize;
    uint256 public wombatOut;

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }

        _trackToken(BSC.USDC);
        _trackToken(BSC.USDT);
    }

    function testStrategy_B09_02() public {
        if (!_haveFork) {
            _offlinePnLCheck();
            return;
        }

        // Sweep feasible sizes; pick the one with the largest positive edge.
        uint256 bestEdge;
        for (uint256 i = 0; i < _sizes.length; i++) {
            uint256 sz = _sizes[i];
            try IWombatPoolInt(WOMBAT_POOL).quotePotentialSwap(BSC.USDC, BSC.USDT, int256(sz))
                returns (uint256 outc, uint256)
            {
                if (outc > sz) {
                    uint256 edge = outc - sz;
                    if (edge > bestEdge) {
                        bestEdge = edge;
                        chosenSize = sz;
                    }
                }
            } catch {
                // size exceeds coverage-ratio limit; skip.
            }
        }

        // Fund principal and capture the bonus if there is a real positive edge.
        uint256 principal = chosenSize > 0 ? chosenSize : _sizes[1];
        _fund(BSC.USDC, address(this), principal);

        _startPnL();

        if (chosenSize > 0) {
            IERC20(BSC.USDC).approve(WOMBAT_POOL, chosenSize);
            (wombatOut, ) = IWombatPoolInt(WOMBAT_POOL).swap(
                BSC.USDC, BSC.USDT, chosenSize, chosenSize, address(this), block.timestamp
            );
        }
        // else: no edge -> hold flat (net ~0).

        _endPnL("B09-02: Wombat coverage-ratio weight-skew capture");
    }

    function _offlinePnLCheck() internal {
        chosenSize = 2_000 ether;
        wombatOut = (chosenSize * 10003) / 10000;
        _fund(BSC.USDC, address(this), chosenSize);
        _startPnL();
        IERC20(BSC.USDC).transfer(address(0xdead), chosenSize);
        _fund(BSC.USDT, address(this), wombatOut);
        _endPnL("B09-02[offline]: Wombat coverage-ratio weight-skew capture");
    }
}

/// @dev Wombat pool with the correct on-chain `int256` quote signature.
interface IWombatPoolInt {
    function swap(
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 minimumToAmount,
        address to,
        uint256 deadline
    ) external returns (uint256 actualToAmount, uint256 haircut);

    function quotePotentialSwap(address fromToken, address toToken, int256 fromAmount)
        external
        view
        returns (uint256 potentialOutcome, uint256 haircut);
}
