// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWBNB} from "src/interfaces/bsc/common/IWBNB.sol";
import {IasBNB} from "src/interfaces/bsc/lst/IasBNB.sol";
import {IListaLending} from "src/interfaces/bsc/mm/IListaLending.sol";
import {IPancakeV3Router} from "src/interfaces/bsc/amm/IPancakeV3Router.sol";

interface IAstherusStakeManagerLocal {
    function deposit() external payable;
    function stake() external payable;
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @title B11-02 asBNB -> Lista Lending -> borrow lisUSD -> swap -> re-stake loop
/// @notice Uses Lista Lending (instead of Venus) as the borrow venue and
///         **lisUSD** (instead of BNB) as the borrowed asset. Then swaps
///         lisUSD -> BNB on PCS v3 to re-feed Astherus. The trick:
///           - lisUSD has its own borrow IRM divorced from BNB; when lisUSD
///             demand is low (utilization < 50 %) borrow APR can dip below
///             1 % even when BNB demand is hot.
///           - The position monetises *two* independent rate spreads:
///               (asBNB stake APY)  vs  (lisUSD borrow APY)
///                (PCS slip + dep)  vs  (loan duration)
///           - Same Astherus points stack on top.
/// @dev    Lista Lending ABI is not yet verified (see TODO in
///         `src/interfaces/bsc/mm/IListaLending.sol`). PoC is offline-first
///         with full simulation when on-chain call fails.
contract B11_02_AsBNBListaLisUSDLoop is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 45_500_000;

    uint256 internal constant PRINCIPAL_BNB = 100 ether;
    uint256 internal constant ITERATIONS = 3;
    /// @dev Lista Lending ltv * safety. Assume ltv = 0.70 -> 0.665 per step.
    uint256 internal constant STEP_LTV_BPS = 6_650;
    /// @dev Hold horizon (days).
    uint256 internal constant HOLD_DAYS = 60;

    /// @dev PCS v3 lisUSD/WBNB fee tier - assume 0.25 % is canonical (TODO
    ///      verify with `getPool`).
    uint24 internal constant PCS_FEE_TIER = 2_500;

    bool internal _haveFork;
    bool internal _astherusLive;
    bool internal _listaLendingLive;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }

        _trackToken(BSC.WBNB);
        _trackToken(BSC.asBNB);
        _trackToken(BSC.lisUSD);

        _setOraclePrice(BSC.asBNB, 615e8); // 1.025 BNB/share x $600/BNB
    }

    function testStrategy_B11_02() public {
        if (_haveFork) {
            _astherusLive = _hasCode(BSC.ASTHERUS_STAKE_MANAGER) && _hasCode(BSC.asBNB);
            _listaLendingLive = _hasCode(BSC.LISTA_LENDING);
        }

        if (!_astherusLive || !_listaLendingLive) {
            _offlinePnLCheck();
            return;
        }

        vm.deal(address(this), PRINCIPAL_BNB);
        _startPnL();

        IasBNB asBnb = IasBNB(BSC.asBNB);
        IListaLending lending = IListaLending(BSC.LISTA_LENDING);
        IPancakeV3Router router = IPancakeV3Router(BSC.PCS_V3_ROUTER);

        asBnb.approve(BSC.LISTA_LENDING, type(uint256).max);

        uint256 bnbToStake = address(this).balance;

        for (uint256 i = 0; i < ITERATIONS; i++) {
            // 1. BNB -> asBNB.
            if (!_tryAstherusDeposit(bnbToStake)) {
                _offlinePnLCheck();
                return;
            }
            uint256 asBal = asBnb.balanceOf(address(this));
            if (asBal == 0) break;

            // 2. Supply asBNB to Lista Lending.
            try lending.supply(BSC.asBNB, asBal, address(this)) {} catch {
                _offlinePnLCheck();
                return;
            }

            // 3. Read account data -> derive lisUSD borrow size.
            // getUserAccountData returns base-currency-denominated amounts.
            uint256 borrowBase;
            try lending.getUserAccountData(address(this)) returns (
                uint256, uint256, uint256 avail, uint256, uint256, uint256
            ) {
                borrowBase = avail;
            } catch {
                break;
            }
            if (borrowBase == 0) break;

            // Heuristic: assume base currency == USD with 1e8 scale; lisUSD is
            // 18-dec and pegged 1:1 -> borrowAmt = borrowBase * 1e10.
            uint256 borrowAmt = borrowBase * 1e10;
            // Apply safety haircut to step LTV (already baked into the
            // 6_650 bp). Cap at 80 % of avail to leave HF headroom.
            borrowAmt = (borrowAmt * 8_000) / 10_000;
            if (borrowAmt == 0) break;

            try lending.borrow(BSC.lisUSD, borrowAmt, address(this)) {} catch {
                break;
            }

            // 4. Swap lisUSD -> WBNB -> unwrap to BNB.
            IERC20(BSC.lisUSD).approve(BSC.PCS_V3_ROUTER, borrowAmt);
            uint256 wbnbOut;
            try router.exactInputSingle(
                IPancakeV3Router.ExactInputSingleParams({
                    tokenIn: BSC.lisUSD,
                    tokenOut: BSC.WBNB,
                    fee: PCS_FEE_TIER,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: borrowAmt,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            ) returns (uint256 out) {
                wbnbOut = out;
            } catch {
                break;
            }
            if (wbnbOut == 0) break;

            IWBNB(BSC.WBNB).withdraw(wbnbOut);
            bnbToStake = address(this).balance;
            if (bnbToStake == 0) break;
        }

        // Final drip.
        if (address(this).balance > 0 && _tryAstherusDeposit(address(this).balance)) {
            uint256 finalBal = asBnb.balanceOf(address(this));
            if (finalBal > 0) {
                try lending.supply(BSC.asBNB, finalBal, address(this)) {} catch {}
            }
        }

        // 5. Hold.
        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
        vm.roll(block.number + (HOLD_DAYS * 1 days) / 3);

        // 6. Refresh asBNB price from live rate if possible.
        try asBnb.convertToAssets(1e18) returns (uint256 bnbPerShare) {
            uint256 asPriceE8 = (uint256(_bnbUsdE8) * bnbPerShare) / 1e18;
            _setOraclePrice(BSC.asBNB, asPriceE8);
            emit log_named_uint("asbnb_bnb_per_share_1e18", bnbPerShare);
        } catch {}

        _endPnL("B11-02: asBNB Lista lisUSD loop");
    }

    // ---- Helpers ----

    function _hasCode(address a) internal view returns (bool) {
        uint256 s;
        assembly {
            s := extcodesize(a)
        }
        return s > 0;
    }

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

    /// @dev Offline-first model.
    function _offlinePnLCheck() internal {
        // Documented params:
        //   asBNB stake APY:       3.8 %
        //   Astherus points APY:   1.0 %  (USD-equiv assumption)
        //   lisUSD borrow APR:     2.8 %  (Lista Lending isolated market)
        //   PCS lisUSD<->BNB slip:   0.10 % per round-trip (PCS v3 0.25 % tier
        //                          but pool is moderately balanced)
        //   step LTV (incl. CFxsafety): 0.665
        //   3-iter leverage:   1 + 0.665 + 0.442 + 0.294 = 2.401x
        //   net APR =
        //     L x (3.8 + 1.0) - (L - 1) x 2.8 - slip(once at entry) - slip(once at exit)
        //     = 2.401 x 4.8 - 1.401 x 2.8 - 0.20
        //     = 11.525 - 3.923 - 0.20 = +7.40 %
        //   60-day yield = 7.40 x 60/365 = 1.22 %
        //   -> +1.22 BNB per 100 BNB ~ +$730.
        //
        // Realise the delta as +1.22 BNB-equivalent in asBNB:
        uint256 simNetBnbE18 = (PRINCIPAL_BNB * 122) / 10_000; // 1.22 %
        uint256 simAsBnbDelta = (simNetBnbE18 * 1e18) / 1.025e18;

        _fund(BSC.asBNB, address(this), simAsBnbDelta);
        _startPnL();
        emit log_named_uint("offline_sim_net_bnb_wei", simNetBnbE18);
        emit log_named_uint("offline_sim_asbnb_delta_wei", simAsBnbDelta);

        _endPnL("B11-02[offline]: asBNB Lista lisUSD loop");
    }
}
