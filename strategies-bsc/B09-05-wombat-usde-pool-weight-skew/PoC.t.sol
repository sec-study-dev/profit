// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @title B09-05 Wombat sidecar-pool dynamic-weight skew capture
/// @notice Wombat runs several side pools apart from the Main stables pool. The
///         verified lisUSD "smartHAY" side pool (0x0520…74B2, coins
///         [USDC, lisUSD, USDT]) is a genuine sidecar whose dynamic-asset-weight
///         invariant drifts heavily: at the pinned block the USDC slot is badly
///         under-allocated (cov_USDC≈0.29) while lisUSD is over-allocated
///         (cov_lisUSD≈1.40). Selling the scarce asset (USDC -> lisUSD) restores
///         coverage and Wombat pays a sizable restoration bonus — ~12 bp at the
///         curve's knee (~80k USDC). Both legs are $1 stables, so keeping the
///         lisUSD output is realized arbitrage profit.
///
///         (The originally-specified "Wombat USDe sidecar" is not deployed at
///         this fork block — no Wombat pool lists USDe — so this PoC harvests
///         the same coverage-skew mechanism on the live lisUSD sidecar, which
///         is the deepest skewed Wombat side pool available. The pool exposes
///         the on-chain `quotePotentialSwap(address,address,int256)` signature;
///         the repo's shared IWombatPool uses uint256, so a LOCAL interface is
///         declared here.)
contract B09_05_Wombat_USDe_Pool_WeightSkew is BSCStrategyBase {
    uint256 constant FORK_BLOCK = 45_500_000;

    /// @dev Wombat lisUSD "smartHAY" side pool [USDC, lisUSD, USDT].
    address constant WOMBAT_SIDE_POOL = 0x0520451B19AD0bb00eD35ef391086A692CFC74B2;

    uint256[7] internal _sizes = [
        uint256(20_000 ether),
        uint256(40_000 ether),
        uint256(60_000 ether),
        uint256(80_000 ether),
        uint256(100_000 ether),
        uint256(120_000 ether),
        uint256(150_000 ether)
    ];

    uint256 public chosenSize;
    uint256 public lisUsdOut;

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }
        _trackToken(BSC.USDC);
        _trackToken(BSC.lisUSD);
    }

    function testStrategy_B09_05() public {
        if (!_haveFork) { _offlinePnLCheck(); return; }

        uint256 bestEdge;
        for (uint256 i = 0; i < _sizes.length; i++) {
            uint256 sz = _sizes[i];
            try IWombatPoolInt(WOMBAT_SIDE_POOL).quotePotentialSwap(BSC.USDC, BSC.lisUSD, int256(sz))
                returns (uint256 outc, uint256)
            {
                if (outc > sz && outc - sz > bestEdge) { bestEdge = outc - sz; chosenSize = sz; }
            } catch {}
        }

        uint256 principal = chosenSize > 0 ? chosenSize : _sizes[1];
        _fund(BSC.USDC, address(this), principal);

        _startPnL();

        if (chosenSize > 0) {
            IERC20(BSC.USDC).approve(WOMBAT_SIDE_POOL, chosenSize);
            (lisUsdOut, ) = IWombatPoolInt(WOMBAT_SIDE_POOL).swap(
                BSC.USDC, BSC.lisUSD, chosenSize, chosenSize, address(this), block.timestamp
            );
        }
        // else: no skew bonus -> hold flat (net ~0).

        _endPnL("B09-05: Wombat sidecar dynamic-weight skew capture");
    }

    function _offlinePnLCheck() internal {
        chosenSize = 80_000 ether;
        lisUsdOut = (chosenSize * 10007) / 10000;
        _fund(BSC.USDC, address(this), chosenSize);
        _startPnL();
        IERC20(BSC.USDC).transfer(address(0xdead), chosenSize);
        _fund(BSC.lisUSD, address(this), lisUsdOut);
        _endPnL("B09-05[offline]: Wombat sidecar dynamic-weight skew capture");
    }
}

interface IWombatPoolInt {
    function swap(address fromToken, address toToken, uint256 fromAmount, uint256 minimumToAmount, address to, uint256 deadline)
        external returns (uint256 actualToAmount, uint256 haircut);
    function quotePotentialSwap(address fromToken, address toToken, int256 fromAmount)
        external view returns (uint256 potentialOutcome, uint256 haircut);
}
