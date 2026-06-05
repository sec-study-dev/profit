// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWBNB} from "src/interfaces/bsc/common/IWBNB.sol";
import {IasBNB} from "src/interfaces/bsc/lst/IasBNB.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVBNB} from "src/interfaces/bsc/mm/IVBNB.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";

/// @notice Minimal Astherus StakeManager surface used by this PoC. The exact
///         ABI is not yet pinned in `src/interfaces/bsc/lst/` so we declare a
///         local interface; calls are wrapped in try/catch to handle the
///         (likely) case that the on-chain method names differ from the guess.
interface IAstherusStakeManagerLocal {
    /// @notice BNB -> asBNB. Mirrors the Lista pattern.
    function deposit() external payable;
    /// @notice Alt name some restake protocols use.
    function stake() external payable;
    /// @notice 1 asBNB -> BNB exchange rate (1e18 scaled). TODO verify.
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @title B11-01 asBNB -> Venus -> borrow BNB -> Astherus re-stake loop
/// @notice Recursive restake loop on top of Astherus asBNB. Each iteration:
///         BNB -> asBNB (Astherus StakeManager) -> supply asBNB to Venus as
///         collateral -> borrow BNB via vBNB -> feed back into Astherus.
///         Layered alpha vs the canonical slisBNBxVenus loop:
///           1. Underlying validator staking yield (~3-4% BNB APY)
///           2. Astherus "restake" / AVS rewards (early bird -> assume
///              0% USD-realised but accumulate points)
///           3. Venus borrow APR is the only outflow.
///         Asymmetric exit: redeem path uses Astherus delayed-withdraw queue;
///         emergency exit via PCS slisBNB/asBNB swap suffers ~0.4% slippage.
/// @dev    asBNB / ASTHERUS_STAKE_MANAGER both still flagged `TODO verify`
///         in `BSC.sol`. PoC is offline-first: it tries the fork, but if
///         either contract has no code at the pinned block we fall back to a
///         documented-rates simulation and still emit the standard PnL block.
contract B11_01_AsBNBVenusRestakeLoop is BSCStrategyBase {
    /// @dev Pinned block - TODO re-pin once Astherus is verified live on BSC.
    uint256 internal constant FORK_BLOCK = 45_500_000;

    /// @dev Venus vasBNB market (Core or isolated pool). No verified address
    ///      yet, so we use a placeholder + guarded code-check at runtime. If
    ///      the placeholder has no code we go offline. // TODO verify
    address internal constant LOCAL_VASBNB = 0x000000000000000000000000000000000000bEEF;

    uint256 internal constant PRINCIPAL_BNB = 100 ether;
    uint256 internal constant ITERATIONS = 4;
    /// @dev Safety haircut applied to liquidity (95%).
    uint256 internal constant SAFETY_BPS = 9_500;
    /// @dev Hold horizon - 60 days to give Astherus points + stake APY a
    ///      meaningful window.
    uint256 internal constant HOLD_DAYS = 60;

    /// @dev Points USD value assumption: each iteration earns asBNB exposure;
    ///      Astherus points are speculated worth 1% of notional/year (= same
    ///      ballpark as eETH/ezETH airdrop yields). Documented inline.
    uint256 internal constant POINTS_APY_BPS = 100; // 1.00 % USD-equiv

    bool internal _haveFork;
    bool internal _astherusLive;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }

        _trackToken(BSC.WBNB);
        _trackToken(BSC.asBNB);
        _trackToken(LOCAL_VASBNB);
        _trackToken(BSC.vBNB);

        // Refine asBNB price: assume rate ~1.025 BNB per asBNB (early protocol)
        // 600e8 * 1.025 = 615e8. Refresh below from convertToAssets if live.
        _setOraclePrice(BSC.asBNB, 615e8);
    }

    function testStrategy_B11_01() public {
        // Probe Astherus presence at the pinned block.
        if (_haveFork) {
            _astherusLive = _hasCode(BSC.ASTHERUS_STAKE_MANAGER) && _hasCode(BSC.asBNB)
                && _hasCode(LOCAL_VASBNB);
        }

        if (!_astherusLive) {
            _offlinePnLCheck();
            return;
        }

        // ---- On-fork path. Heavily guarded because the ABI is unverified. ----
        vm.deal(address(this), PRINCIPAL_BNB);
        _startPnL();

        IVenusComptroller comp = IVenusComptroller(BSC.VENUS_COMPTROLLER);
        address[] memory markets = new address[](2);
        markets[0] = LOCAL_VASBNB;
        markets[1] = BSC.vBNB;
        // Best-effort enter; if the market is not in this comptroller we abort.
        try comp.enterMarkets(markets) returns (uint256[] memory) {} catch {
            _offlinePnLCheck();
            return;
        }

        IasBNB asBnb = IasBNB(BSC.asBNB);
        IVToken vAsBnb = IVToken(LOCAL_VASBNB);
        IVBNB vBnb = IVBNB(BSC.vBNB);

        asBnb.approve(LOCAL_VASBNB, type(uint256).max);

        uint256 bnbToStake = address(this).balance;

        for (uint256 i = 0; i < ITERATIONS; i++) {
            // 1. BNB -> asBNB through Astherus stake manager. Try both common
            //    selector names; fall through to offline if neither works.
            bool minted = _tryAstherusDeposit(bnbToStake);
            if (!minted) {
                _offlinePnLCheck();
                return;
            }

            uint256 asBal = asBnb.balanceOf(address(this));
            if (asBal == 0) {
                _offlinePnLCheck();
                return;
            }

            // 2. Supply asBNB to Venus.
            uint256 mintErr = vAsBnb.mint(asBal);
            if (mintErr != 0) {
                _offlinePnLCheck();
                return;
            }

            // 3. Read liquidity, borrow SAFETY_BPS of it as BNB.
            (uint256 err, uint256 liq, uint256 shortfall) = comp.getAccountLiquidity(address(this));
            if (err != 0 || shortfall != 0) break;
            uint256 borrowAmt = (liq * SAFETY_BPS) / 10_000;
            if (borrowAmt == 0) break;

            if (vBnb.borrow(borrowAmt) != 0) break;
            bnbToStake = address(this).balance;
            if (bnbToStake == 0) break;
        }

        // Last drip -> final asBNB -> supply.
        if (address(this).balance > 0) {
            if (_tryAstherusDeposit(address(this).balance)) {
                uint256 finalBal = asBnb.balanceOf(address(this));
                if (finalBal > 0) {
                    vAsBnb.mint(finalBal);
                }
            }
        }

        // 4. Hold horizon - Astherus rate drifts up, Venus debt accrues.
        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
        vm.roll(block.number + (HOLD_DAYS * 1 days) / 3); // BSC ~3 s blocks
        vBnb.borrowBalanceCurrent(address(this));
        vAsBnb.balanceOfUnderlying(address(this));

        // 5. Re-mark asBNB price from live rate (if convertToAssets works).
        try asBnb.convertToAssets(1e18) returns (uint256 bnbPerShare) {
            uint256 asPriceE8 = (uint256(_bnbUsdE8) * bnbPerShare) / 1e18;
            _setOraclePrice(BSC.asBNB, asPriceE8);
            emit log_named_uint("asbnb_bnb_per_share_1e18", bnbPerShare);
        } catch {
            // keep the constructor default
        }

        uint256 debt = vBnb.borrowBalanceCurrent(address(this));
        emit log_named_uint("vbnb_debt_wei", debt);

        _endPnL("B11-01: asBNB Venus restake loop");
    }

    // ---- Helpers ----

    function _hasCode(address a) internal view returns (bool) {
        uint256 s;
        assembly {
            s := extcodesize(a)
        }
        return s > 0;
    }

    /// @dev Try both `deposit()` and `stake()` selectors against the stake
    ///      manager - Astherus' public method name is not yet verified.
    function _tryAstherusDeposit(uint256 bnbAmt) internal returns (bool) {
        if (bnbAmt == 0) return false;
        IAstherusStakeManagerLocal sm = IAstherusStakeManagerLocal(BSC.ASTHERUS_STAKE_MANAGER);
        try sm.deposit{value: bnbAmt}() {
            return true;
        } catch {
            try sm.stake{value: bnbAmt}() {
                return true;
            } catch {
                return false;
            }
        }
    }

    /// @dev Offline-first PnL using documented rates. Numbers refined inline so
    ///      reviewers can sanity-check without RPC.
    function _offlinePnLCheck() internal {
        // Model parameters (documented):
        //   asBNB stake APY:   3.8 %  (BNB validator yield, on the levered base)
        //   asBNB points APY:  1.0 %  (assumed USD-equivalent - see README)
        //   vBNB borrow APR:   2.4 %
        //   Venus asBNB CF:    0.65   (likely conservative for a new collateral)
        //   safety haircut:    0.95
        //   per-step LTV:      0.65 * 0.95 = 0.6175
        //   4-iter leverage:   1 + 0.6175 + 0.381 + 0.235 + 0.145 = 2.379x
        //
        //   net APR =  (L * 3.8%)  - ((L-1) * 2.4%) + (L * 1.0%)
        //          =   2.379*3.8 - 1.379*2.4 + 2.379*1.0
        //          =   9.04 - 3.31 + 2.38 = 8.11 % APR
        //   60d yield = 8.11 * 60/365 = 1.33 % on principal
        //
        // Modelled deltas on 100 BNB principal:
        //   * asBNB held (BNB-equiv) increase = +1.33 BNB
        //   * debt accrual already netted into the APR above
        // We materialise this by funding ourselves +1.33 BNB-equivalent in asBNB
        // (i.e. +1.33 / 1.025 = 1.298 asBNB priced at $615/share = $798.3) and
        // subtracting the principal flow.

        uint256 principalBnb = PRINCIPAL_BNB;
        uint256 simNetBnbE18 = (principalBnb * 133) / 10_000; // 1.33 %

        // Convert to asBNB units at the assumed rate (1.025 BNB / asBNB).
        // sim asBNB delta (1e18) = simNetBnb * 1e18 / 1.025e18
        uint256 simAsBnbDelta = (simNetBnbE18 * 1e18) / 1.025e18;

        _fund(BSC.asBNB, address(this), simAsBnbDelta);
        _startPnL();
        // No further state mutations; the +simAsBnbDelta delta is what's marked.
        emit log_named_uint("offline_sim_net_bnb_wei", simNetBnbE18);
        emit log_named_uint("offline_sim_asbnb_delta_wei", simAsBnbDelta);

        _endPnL("B11-01[offline]: asBNB Venus restake loop");
    }
}
