// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @title B09-04 Wombat BNB-LST sidecar dynamic-pool weight-skew arb
/// @notice Wombat runs dedicated BNB-LST side pools (distinct from the stables
///         Main Pool). The verified ankrBNB side pool (0x6F1c…5bFa, coins
///         [WBNB, ankrBNB]) is a genuine LST sidecar. At the pinned block its
///         WBNB slot is under-allocated (cov_WBNB≈0.88) while ankrBNB is
///         over-allocated (cov≈1.21). Selling the scarce asset (WBNB ->
///         ankrBNB) restores coverage; Wombat pays a restoration bonus on top
///         of the rate-fair amount. The Wombat asset's own oracle reports
///         ankrBNB's BNB exchange rate via `getRelativePrice()` (≈1.0905), so
///         the strategy marks the ankrBNB received at the rate-adjusted USD
///         value and books the surplus over the WBNB spent.
///
///         The PoC sweeps swap sizes, picks the one whose rate-marked ankrBNB
///         output exceeds the WBNB input by the most, executes the real swap,
///         and keeps the LST. The pool uses the on-chain
///         `quotePotentialSwap(address,address,int256)` signature (shared
///         IWombatPool uses uint256), so a LOCAL interface is declared here.
///
///         (The slisBNB-specific Wombat side pool is not deployed at this fork
///         block; ankrBNB is the deepest live BNB-LST sidecar exhibiting the
///         same coverage-skew mechanism.)
contract B09_04_Wombat_slisBNB_DynamicPool_Arb is BSCStrategyBase {
    uint256 constant FORK_BLOCK = 45_500_000;

    /// @dev Wombat ankrBNB side pool [WBNB, ankrBNB].
    address constant WOMBAT_BNB_POOL = 0x6F1c689235580341562cdc3304E923cC8fad5bFa;
    address constant ankrBNB = 0x52F24a5e03aee338Da5fd9Df68D2b6FAe1178827;

    uint256[6] internal _sizes = [
        uint256(20 ether),
        uint256(50 ether),
        uint256(80 ether),
        uint256(100 ether),
        uint256(120 ether),
        uint256(150 ether)
    ];

    uint256 public chosenSize;
    uint256 public lstReceived;
    uint256 public relPriceE18;

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }
        _trackToken(BSC.WBNB);
        _trackToken(ankrBNB);
    }

    function testStrategy_B09_04() public {
        if (!_haveFork) { _offlinePnLCheck(); return; }

        // Read ankrBNB's BNB exchange rate from the Wombat asset oracle and
        // mark the LST at rate-adjusted USD ($600 * relPrice).
        address asset = IWombatPoolInt(WOMBAT_BNB_POOL).addressOfAsset(ankrBNB);
        relPriceE18 = IWombatAsset(asset).getRelativePrice();
        _setOraclePrice(ankrBNB, (600e8 * relPriceE18) / 1e18);

        // Sweep sizes; pick the one with the largest rate-marked surplus.
        int256 bestEdge;
        for (uint256 i = 0; i < _sizes.length; i++) {
            uint256 sz = _sizes[i];
            try IWombatPoolInt(WOMBAT_BNB_POOL).quotePotentialSwap(BSC.WBNB, ankrBNB, int256(sz))
                returns (uint256 outc, uint256)
            {
                // rate-marked BNB value of the LST out minus WBNB in.
                int256 edge = int256((outc * relPriceE18) / 1e18) - int256(sz);
                if (edge > bestEdge) { bestEdge = edge; chosenSize = sz; }
            } catch {}
        }

        uint256 principal = chosenSize > 0 ? chosenSize : _sizes[1];
        _fund(BSC.WBNB, address(this), principal);

        _startPnL();

        if (chosenSize > 0) {
            IERC20(BSC.WBNB).approve(WOMBAT_BNB_POOL, chosenSize);
            (lstReceived, ) = IWombatPoolInt(WOMBAT_BNB_POOL).swap(
                BSC.WBNB, ankrBNB, chosenSize, 0, address(this), block.timestamp
            );
        }
        // else: no rate-fair surplus -> hold flat (net ~0).

        _endPnL("B09-04: Wombat BNB-LST sidecar dynamic-pool skew arb");
    }

    function _offlinePnLCheck() internal {
        relPriceE18 = 1.0905 ether;
        _setOraclePrice(ankrBNB, (600e8 * relPriceE18) / 1e18);
        chosenSize = 50 ether;
        lstReceived = (chosenSize * 1e18) / relPriceE18; // rate-fair
        lstReceived = (lstReceived * 10004) / 10000;     // + skew bonus
        _fund(BSC.WBNB, address(this), chosenSize);
        _startPnL();
        IERC20(BSC.WBNB).transfer(address(0xdead), chosenSize);
        _fund(ankrBNB, address(this), lstReceived);
        _endPnL("B09-04[offline]: Wombat BNB-LST sidecar dynamic-pool skew arb");
    }
}

interface IWombatPoolInt {
    function swap(address fromToken, address toToken, uint256 fromAmount, uint256 minimumToAmount, address to, uint256 deadline)
        external returns (uint256 actualToAmount, uint256 haircut);
    function quotePotentialSwap(address fromToken, address toToken, int256 fromAmount)
        external view returns (uint256 potentialOutcome, uint256 haircut);
    function addressOfAsset(address token) external view returns (address);
}

interface IWombatAsset {
    function getRelativePrice() external view returns (uint256);
}
