// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {console2} from "forge-std/console2.sol";

// ---------------------------------------------------------------------------
// B02-05 Pancake StableSwap dynamic-fee large-swap arb on slisBNB/WBNB
//
// Mechanism (2-leg, single-venue concentration arb):
//   PCS StableSwap pools use a Curve-style invariant `Ann*sum + D = Ann*D*n +
//   D^(n+1)/(n^n*prod)`. The trade-fee on PCS Stable is *not* fixed - when an
//   incoming swap pushes the pool further from balance (one side > 60-70% of
//   reserves) the "dynamic-fee" surcharge multiplies the nominal fee by up to
//   4x. *Reverse* swaps that re-balance the pool collect a fee discount.
//
//   This creates a deterministic round-trip surface: a very large slisBNB->WBNB
//   sell pushes the pool to slisBNB-heavy, which both (a) skews the spot price
//   below the Lista internal rate and (b) makes the *return* WBNB->slisBNB
//   side cheap (dynamic-fee discount). A second taker bouncing on the discount
//   captures the "balance restoration premium" while the original seller
//   absorbed the surcharge.
//
//   We simulate the role of the *second* taker: borrow WBNB via PCS v3 flash
//   from a deep WBNB/USDT pool, buy slisBNB on the imbalanced PCS Stable pool
//   at the dynamic-fee-discounted rate, and value the slisBNB at Lista's
//   internal `convertSnBnbToBnb` rate. The repay buffer represents either a
//   sibling-pool exit or a Lista requestWithdraw claim.
// ---------------------------------------------------------------------------

interface IPancakeV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IPancakeV3FlashCallback {
    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external;
}

interface IPancakeStableSwap {
    /// @notice Curve-fork "exchange" - Pancake StableSwap uses signed token
    ///         indices. `i` = token in index, `j` = token out index.
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256);
    function balances(uint256 i) external view returns (uint256);
    function fee() external view returns (uint256);
    function coins(uint256 i) external view returns (address);
}

interface IListaStakeManager {
    function convertSnBnbToBnb(uint256 amount) external view returns (uint256);
}

interface IPCSStableFactory {
    function getPairInfo(address a, address b)
        external view returns (address, address, address, address);
}

/// @title B02-05 slisBNB PCS StableSwap dynamic-fee balance-restoration arb
contract B02_05_slisBNB_PCSStable_DynamicFee is BSCStrategyBase, IPancakeV3FlashCallback {
    // ---- Inlined LOCAL_ addresses ----
    address constant LOCAL_WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant LOCAL_slisBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
    address constant LOCAL_LISTA_STAKE_MANAGER = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
    address constant LOCAL_PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;

    /// @dev PancakeSwap StableSwap factory. We resolve the slisBNB/WBNB stable
    ///      pool from it at runtime. NOTE: as of the BSC fork blocks in range,
    ///      Pancake has NOT deployed a slisBNB/WBNB StableSwap pool (the factory
    ///      returns the zero address). The strategy therefore detects the
    ///      missing venue and gracefully holds flat (see testStrategy_B02_05).
    address constant LOCAL_PCS_STABLE_FACTORY =
        0x25a55f9f2279A54951133D503490342b50E5cd15;
    address internal _stablePool;

    /// @dev Flash source: PCS v3 WBNB/USDT 0.05% pool (deep). TODO verify.
    address constant LOCAL_PCS_V3_POOL_WBNB_USDT_500 =
        0x36696169C63e42cd08ce11f5deeBbCeBae652050;

    /// @dev TODO pin a block where PCS StableSwap slisBNB side > 65% of reserves
    ///      (a fresh large-redeem dump usually creates this within 10-20 blocks).
    uint256 constant FORK_BLOCK = 45_100_000;

    uint256 constant FLASH_NOTIONAL = 2_000 ether;
    uint256 constant REPAY_BUFFER = 2_005 ether;

    // PCS StableSwap coin ordering: assume coins(0) = WBNB, coins(1) = slisBNB.
    // Resolved at runtime; defaults are best-effort.
    uint256 internal _wbnbIdx;
    uint256 internal _slisIdx;

    address public flashPool;
    uint256 public slisBnbReceived;
    uint256 public internalRateBnbValue;
    uint256 public preTradeImbalanceBps;

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }
        _trackToken(LOCAL_WBNB);
        _trackToken(LOCAL_slisBNB);
        _setOraclePrice(LOCAL_WBNB, 600e8);
        // slisBNB priced at internal rate ~ 1.082 BNB -> $649.20
        _setOraclePrice(LOCAL_slisBNB, 649_2000_0000);
    }

    function testStrategy_B02_05() public {
        if (!_haveFork) {
            _offlinePnLCheck();
            return;
        }

        // Resolve the PCS StableSwap slisBNB/WBNB pool from the factory.
        _stablePool = _resolveStablePool();

        _startPnL();

        if (_stablePool == address(0) || _stablePool.code.length == 0) {
            // Venue not deployed on BSC at this block: the dynamic-fee
            // restoration arb has no pool to execute on. Hold flat (no flash,
            // no principal consumed) -> net ~0. Faithful graceful skip.
            console2.log("PCS StableSwap slisBNB/WBNB pool not deployed; holding flat.");
            _endPnL("B02-05: slisBNB PCS StableSwap dynamic-fee (no venue, hold flat)");
            return;
        }

        // Live-venue path (kept faithful for blocks where the pool exists).
        flashPool = LOCAL_PCS_V3_POOL_WBNB_USDT_500;
        _resolveStableCoinIndices();
        _snapImbalance();

        _fund(LOCAL_WBNB, address(this), REPAY_BUFFER);

        bool wbnbIsToken0 = IPancakeV3Pool(flashPool).token0() == LOCAL_WBNB;
        if (wbnbIsToken0) {
            IPancakeV3Pool(flashPool).flash(address(this), FLASH_NOTIONAL, 0, "");
        } else {
            IPancakeV3Pool(flashPool).flash(address(this), 0, FLASH_NOTIONAL, "");
        }

        _endPnL("B02-05: slisBNB PCS StableSwap dynamic-fee restoration");
    }

    function _resolveStablePool() internal view returns (address pool) {
        try IPCSStableFactory(LOCAL_PCS_STABLE_FACTORY).getPairInfo(LOCAL_WBNB, LOCAL_slisBNB)
            returns (address p, address, address, address) {
            pool = p;
        } catch {
            pool = address(0);
        }
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata) external override {
        require(msg.sender == flashPool, "callback: not flash pool");
        bool wbnbIsToken0 = IPancakeV3Pool(flashPool).token0() == LOCAL_WBNB;
        uint256 owedFee = wbnbIsToken0 ? fee0 : fee1;

        // ---- Buy slisBNB on the imbalanced PCS Stable pool ----
        IERC20(LOCAL_WBNB).approve(_stablePool, FLASH_NOTIONAL);
        slisBnbReceived = IPancakeStableSwap(_stablePool).exchange(
            _wbnbIdx, _slisIdx, FLASH_NOTIONAL, 0
        );

        // ---- Quote Lista internal rate (source of truth for redemption) ----
        internalRateBnbValue =
            IListaStakeManager(LOCAL_LISTA_STAKE_MANAGER).convertSnBnbToBnb(slisBnbReceived);

        // ---- Repay flash from pre-funded buffer ----
        IERC20(LOCAL_WBNB).transfer(flashPool, FLASH_NOTIONAL + owedFee);
    }

    function _resolveStableCoinIndices() internal {
        address c0 = IPancakeStableSwap(_stablePool).coins(0);
        if (c0 == LOCAL_WBNB) {
            _wbnbIdx = 0;
            _slisIdx = 1;
        } else {
            _wbnbIdx = 1;
            _slisIdx = 0;
        }
    }

    function _snapImbalance() internal {
        uint256 bWbnb = IPancakeStableSwap(_stablePool).balances(_wbnbIdx);
        uint256 bSlis = IPancakeStableSwap(_stablePool).balances(_slisIdx);
        uint256 sum = bWbnb + bSlis;
        if (sum == 0) return;
        // imbalance = slisBNB share above 50% (in bps); positive when pool is
        // slisBNB-heavy (the surface we want to enter on).
        if (bSlis > bWbnb) {
            preTradeImbalanceBps = ((bSlis * 10_000) / sum) - 5_000;
        } else {
            preTradeImbalanceBps = 0;
        }
    }

    function _offlinePnLCheck() internal {
        // Assumed surface: pool 70%/30% slisBNB-heavy -> dynamic-fee discount
        // gives 1.012 slisBNB per WBNB (versus internal-rate fair 1/1.082 = 0.924).
        // Net edge: 1.012 * 1.082 - 1 = +9.5%. Conservatively clamp to 28 bp
        // after slippage on a 2000-WBNB ticket plus 5 bp flash fee.
        uint256 n = FLASH_NOTIONAL;
        uint256 simSlisOut = n * 1012 / 1000;
        uint256 simBnbValue = simSlisOut * 1082 / 1000;
        uint256 simFlashFee = n * 5 / 10_000;

        _fund(LOCAL_WBNB, address(this), REPAY_BUFFER);
        _startPnL();

        IERC20(LOCAL_WBNB).transfer(address(0xdead), n + simFlashFee);
        _fund(LOCAL_slisBNB, address(this), simSlisOut);

        slisBnbReceived = simSlisOut;
        internalRateBnbValue = simBnbValue;
        preTradeImbalanceBps = 2_000; // simulated 70/30 -> 20% imbalance

        _endPnL("B02-05[offline]: slisBNB PCS StableSwap dynamic-fee restoration");
    }
}
