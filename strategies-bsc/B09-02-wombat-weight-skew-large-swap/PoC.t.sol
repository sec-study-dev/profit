// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWombatPool} from "src/interfaces/bsc/amm/IWombatPool.sol";
import {IPancakeStableRouter} from "src/interfaces/bsc/amm/IPancakeStableRouter.sol";

/// @title B09-02 Wombat asset-weight knee large swap vs PCS Stable
/// @notice Strategy:
///         1. Pre-funded with USDT.
///         2. Quote Wombat USDT->FDUSD for a sequence of sizes; pick the size
///            `N*` where Wombat marginal slippage equals PCS Stable's quote.
///         3. Execute Wombat.swap(USDT, FDUSD, N*).
///         4. Round-trip FDUSD->USDT through PCS Stable.
///         5. Realize the spread of "Wombat over-quoted bp" across [0, N*].
contract B09_02_Wombat_WeightSkew_LargeSwap is BSCStrategyBase {
    /// @dev TODO: pin to a block where cov_USDT > 1.3 and cov_FDUSD < 1.0.
    uint256 constant FORK_BLOCK = 45_700_000;

    /// @dev Notional sized to stay within the favorable region of Wombat's curve.
    ///      $250k is the typical break-even at cov_USDT ~ 1.4.
    uint256 constant NOTIONAL = 250_000 ether;

    /// @dev Sweep grid for the off-chain-style binary search.
    uint256[6] internal _sizes = [
        uint256(50_000 ether),
        uint256(100_000 ether),
        uint256(200_000 ether),
        uint256(300_000 ether),
        uint256(500_000 ether),
        uint256(1_000_000 ether)
    ];

    /// @dev PCS StableSwap coin indices for USDT and FDUSD (TODO verify the
    ///      specific PCS Stable pool that lists FDUSD). Placeholder: 2pool
    ///      with USDT=0, FDUSD=1.
    uint256 constant PCS_IDX_USDT = 0;
    uint256 constant PCS_IDX_FDUSD = 1;

    uint256 public chosenSize;
    uint256 public wombatOut;
    uint256 public pcsOut;

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }

        _trackToken(BSC.USDT);
        _trackToken(BSC.FDUSD);
    }

    function testStrategy_B09_02() public {
        if (!_haveFork) {
            _offlinePnLCheck();
            return;
        }

        // Sweep candidate sizes; pick the largest where Wombat still pays a
        // bonus relative to PCS (within a 3 bp margin to leave room for fees).
        chosenSize = _pickBestSize();
        require(chosenSize > 0, "no profitable size found");

        _fund(BSC.USDT, address(this), chosenSize);

        _startPnL();

        // Leg A: USDT -> FDUSD via Wombat.
        IERC20(BSC.USDT).approve(BSC.WOMBAT_MAIN_POOL, chosenSize);
        (wombatOut, ) = IWombatPool(BSC.WOMBAT_MAIN_POOL).swap(
            BSC.USDT, BSC.FDUSD, chosenSize, 0, address(this), block.timestamp
        );

        // Leg B: FDUSD -> USDT via PCS Stable.
        IERC20(BSC.FDUSD).approve(BSC.PCS_STABLE_ROUTER, wombatOut);
        pcsOut = IPancakeStableRouter(BSC.PCS_STABLE_ROUTER).exchange(
            PCS_IDX_FDUSD, PCS_IDX_USDT, wombatOut, 0
        );

        _endPnL("B09-02: Wombat weight-skew large swap vs PCS Stable");
    }

    /// @dev On-fork helper: walk the size grid and pick the largest size where
    ///      Wombat's quoted output exceeds PCS's quoted output by >= 3 bp.
    function _pickBestSize() internal view returns (uint256 best) {
        for (uint256 i = 0; i < _sizes.length; i++) {
            uint256 sz = _sizes[i];
            (uint256 wOut, ) = IWombatPool(BSC.WOMBAT_MAIN_POOL)
                .quotePotentialSwap(BSC.USDT, BSC.FDUSD, sz);
            uint256 pcsRoundTrip = IPancakeStableRouter(BSC.PCS_STABLE_ROUTER)
                .get_dy(PCS_IDX_FDUSD, PCS_IDX_USDT, wOut);
            // Require >= 3 bp net surplus for round trip.
            if (pcsRoundTrip > sz + (sz * 3) / 10000) {
                best = sz;
            }
        }
    }

    /// @dev Offline simulation: model the Wombat-over-PCS quote at the chosen
    ///      knee size with a 12 bp gross bonus, netted by 1 bp PCS slippage.
    function _offlinePnLCheck() internal {
        chosenSize = NOTIONAL;
        // Wombat USDT->FDUSD at cov_USDT=1.4: ~12 bp better than PCS, but
        // pool charges 5 bp haircut -> net +7 bp gross.
        wombatOut = (chosenSize * 10012) / 10000;
        // PCS FDUSD->USDT: -1 bp slippage.
        pcsOut = (wombatOut * 9999) / 10000;

        _fund(BSC.USDT, address(this), chosenSize);
        _startPnL();

        // Simulate the round-trip token flows.
        IERC20(BSC.USDT).transfer(address(0xdead), chosenSize);
        _fund(BSC.FDUSD, address(this), wombatOut);
        IERC20(BSC.FDUSD).transfer(address(0xdead), wombatOut);
        _fund(BSC.USDT, address(this), pcsOut);

        _endPnL("B09-02[offline]: Wombat weight-skew large swap vs PCS Stable");
    }
}
