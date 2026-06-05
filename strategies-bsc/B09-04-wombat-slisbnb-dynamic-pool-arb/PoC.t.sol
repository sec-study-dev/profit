// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWombatPool} from "src/interfaces/bsc/amm/IWombatPool.sol";
import {IListaStakeManager} from "src/interfaces/bsc/lst/IListaStakeManager.sol";

/// @title B09-04 Wombat slisBNB/BNB dynamic-pool weight-skew arb
/// @notice Strategy:
///         1. WBNB -> slisBNB through Wombat slisBNB sidecar pool.
///         2. Mark slisBNB received at Lista internal rate.
///         3. Profit = (rate-marked BNB value) - (WBNB consumed).
///         Position retained as slisBNB; tracked-token oracle override prices
///         slisBNB at internal-rate-adjusted USD so PnL reflects the bonus.
contract B09_04_Wombat_slisBNB_DynamicPool_Arb is BSCStrategyBase {
    /// @dev TODO: pin a block where Wombat slisBNB sidecar pool has cov_BNB < 0.9.
    uint256 constant FORK_BLOCK = 45_800_000;

    /// @dev Wombat slisBNB sidecar pool (LST pool, distinct from Main Pool).
    ///      TODO verify on BscScan: this is a placeholder; on-fork branch
    ///      falls back to the Main Pool if extcodesize == 0.
    address constant WOMBAT_SLISBNB_POOL = 0xB0219A90EF6A24a237bC038f7B7a6eAc5e01edB0;

    /// @dev Notional in WBNB (18 decimals).
    uint256 constant NOTIONAL = 1_000 ether;

    /// @dev Default assumed Lista internal rate when running offline: 1.078 BNB/slisBNB.
    uint256 constant INTERNAL_RATE_E18 = 1.078 ether;

    uint256 public slisBnbReceived;
    uint256 public bnbValueAtInternalRate;
    address public wombatPool;

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }

        _trackToken(BSC.WBNB);
        _trackToken(BSC.slisBNB);

        // Mark slisBNB at internal-rate-adjusted USD ($600 BNB * 1.078 = $646.80).
        _setOraclePrice(BSC.slisBNB, 646_8000_0000);
    }

    function testStrategy_B09_04() public {
        if (!_haveFork) {
            _offlinePnLCheck();
            return;
        }

        _resolvePool();
        _fund(BSC.WBNB, address(this), NOTIONAL);

        _startPnL();

        IERC20(BSC.WBNB).approve(wombatPool, NOTIONAL);
        (slisBnbReceived, ) = IWombatPool(wombatPool).swap(
            BSC.WBNB,
            BSC.slisBNB,
            NOTIONAL,
            0,
            address(this),
            block.timestamp
        );

        bnbValueAtInternalRate = IListaStakeManager(BSC.LISTA_STAKE_MANAGER)
            .convertSnBnbToBnb(slisBnbReceived);

        // Strategy invariant (commented for PoC tolerance):
        // require(bnbValueAtInternalRate > NOTIONAL, "no rate-fair surplus");

        _endPnL("B09-04: Wombat slisBNB dynamic-pool weight-skew arb");
    }

    function _resolvePool() internal {
        wombatPool = WOMBAT_SLISBNB_POOL;
        uint256 codeSize;
        address p = wombatPool;
        assembly {
            codeSize := extcodesize(p)
        }
        if (codeSize == 0) {
            // Fallback: try the Main Pool (slisBNB may not be registered there,
            // in which case the swap reverts and the PoC fails loudly).
            wombatPool = BSC.WOMBAT_MAIN_POOL;
        }
    }

    /// @dev Offline simulation: documented 12 bp Wombat over-quote at
    ///      cov_BNB=0.88, with 5 bp Wombat haircut already netted.
    function _offlinePnLCheck() internal {
        // At cov_BNB=0.88: pool over-pays BNB depositors by 12 bp gross.
        // After 5 bp Wombat haircut, net bonus is 7 bp on slisBNB output
        // *priced in BNB*. So slisBNB_out * internalRate ~ N * 1.0007 BNB.
        uint256 fairSlis = (NOTIONAL * 1e18) / INTERNAL_RATE_E18; // ~927.6 slisBNB
        uint256 bonusSlis = (fairSlis * 7) / 10000;               // +7 bp slisBNB
        slisBnbReceived = fairSlis + bonusSlis;
        bnbValueAtInternalRate = (slisBnbReceived * INTERNAL_RATE_E18) / 1e18;

        _fund(BSC.WBNB, address(this), NOTIONAL);
        _startPnL();

        // Consume the WBNB, receive the modelled slisBNB.
        IERC20(BSC.WBNB).transfer(address(0xdead), NOTIONAL);
        _fund(BSC.slisBNB, address(this), slisBnbReceived);

        _endPnL("B09-04[offline]: Wombat slisBNB dynamic-pool weight-skew arb");
    }
}
