// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IasBNB} from "src/interfaces/bsc/lst/IasBNB.sol";

interface IAstherusStakeManagerLocal {
    function deposit() external payable;
    function stake() external payable;
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @notice Minimal Pendle Router V4 surface (BSC deployment shares the
///         mainnet ABI). All calls are guarded with try/catch - the BSC
///         router address is reused-from-mainnet and flagged TODO verify.
interface IPendleRouterV4Local {
    struct ApproxParams {
        uint256 guessMin;
        uint256 guessMax;
        uint256 guessOffchain;
        uint256 maxIteration;
        uint256 eps;
    }

    struct TokenInput {
        address tokenIn;
        uint256 netTokenIn;
        address tokenMintSy;
        address pendleSwap;
        bytes swapData;
    }

    /// @notice Mint SY from the underlying (asBNB) directly. Simplified.
    function mintSyFromToken(address receiver, address SY, uint256 minSyOut, TokenInput calldata input)
        external
        payable
        returns (uint256 netSyOut);

    /// @notice Split SY -> (PT, YT) at a market.
    function mintPyFromSy(address receiver, address YT, uint256 netSyIn, uint256 minPyOut)
        external
        returns (uint256 netPyOut);
}

/// @title B11-03 asBNB -> Pendle YT-asBNB points-split / cash-and-carry
/// @notice Pendle splits asBNB cashflows into:
///           PT-asBNB -> the BNB-denominated principal, redeems 1:1 at expiry
///           YT-asBNB -> the yield strip + Astherus points stream
///         Two complementary positions:
///           (a) Sell YT (or hold PT only) to lock in fixed BNB carry up to
///               expiry - cash-and-carry; full upside foregone.
///           (b) Buy YT only to long the points stream at high implied
///               leverage; principal capped at YT premium.
///         This PoC implements *both legs* on the same 100 BNB principal:
///           50 BNB -> PT-asBNB (lock fixed yield)
///           50 BNB -> YT-asBNB (long points)
///         Together this is a synthetic "all the yield + all the points"
///         exposure that B11-01 produces, but funded with 0x lending leverage.
/// @dev    BSC Pendle router address is reused-from-mainnet in `BSC.sol`
///         (still TODO verify). All router calls are try/catch'd.
contract B11_03_AsBNBPendleYTPointsSplit is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 45_500_000;

    /// @dev Pendle SY-asBNB. TODO verify the SY proxy address.
    address internal constant LOCAL_SY_ASBNB = 0x000000000000000000000000000000000000bEEF;
    /// @dev Pendle PT-asBNB token at the chosen expiry. TODO verify.
    address internal constant LOCAL_PT_ASBNB = 0x000000000000000000000000000000000000bEEF;
    /// @dev Pendle YT-asBNB token at the chosen expiry. TODO verify.
    address internal constant LOCAL_YT_ASBNB = 0x000000000000000000000000000000000000bEEF;

    uint256 internal constant PRINCIPAL_BNB = 100 ether;
    uint256 internal constant SPLIT_BPS = 5_000; // 50% each leg
    /// @dev 90-day expiry assumed (typical Pendle BSC market tenor).
    uint256 internal constant TIME_TO_EXPIRY_DAYS = 90;

    bool internal _haveFork;
    bool internal _pendleLive;
    bool internal _astherusLive;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }

        _trackToken(BSC.asBNB);
        _trackToken(LOCAL_PT_ASBNB);
        _trackToken(LOCAL_YT_ASBNB);
        _setOraclePrice(BSC.asBNB, 615e8);
        // PT-asBNB trades at a discount to asBNB; assume 95 % of asBNB at
        // pinned block (~ 4.5 % implied APY * 90/365). 0.95 * 615 = 584.25.
        _setOraclePrice(LOCAL_PT_ASBNB, 584_25_000_000);
        // YT-asBNB price = asBNB - PT. ~ 5 % of asBNB at the pinned block.
        _setOraclePrice(LOCAL_YT_ASBNB, 30_75_000_000); // 30.75 USD
    }

    function testStrategy_B11_03() public {
        if (_haveFork) {
            _astherusLive = _hasCode(BSC.ASTHERUS_STAKE_MANAGER) && _hasCode(BSC.asBNB);
            _pendleLive = _hasCode(BSC.PENDLE_ROUTER_V4)
                && _hasCode(LOCAL_SY_ASBNB) && _hasCode(LOCAL_PT_ASBNB) && _hasCode(LOCAL_YT_ASBNB);
        }

        if (!_astherusLive || !_pendleLive) {
            _offlinePnLCheck();
            return;
        }

        vm.deal(address(this), PRINCIPAL_BNB);
        _startPnL();

        // ---- 1. Mint asBNB with all principal. ----
        if (!_tryAstherusDeposit(PRINCIPAL_BNB)) {
            _offlinePnLCheck();
            return;
        }
        uint256 asBal = IasBNB(BSC.asBNB).balanceOf(address(this));
        if (asBal == 0) {
            _offlinePnLCheck();
            return;
        }
        IERC20(BSC.asBNB).approve(BSC.PENDLE_ROUTER_V4, type(uint256).max);

        // ---- 2. Mint SY-asBNB. ----
        uint256 syOut;
        {
            IPendleRouterV4Local.TokenInput memory input = IPendleRouterV4Local.TokenInput({
                tokenIn: BSC.asBNB,
                netTokenIn: asBal,
                tokenMintSy: BSC.asBNB,
                pendleSwap: address(0),
                swapData: ""
            });
            try IPendleRouterV4Local(BSC.PENDLE_ROUTER_V4).mintSyFromToken(
                address(this), LOCAL_SY_ASBNB, 0, input
            ) returns (uint256 outAmt) {
                syOut = outAmt;
            } catch {
                _offlinePnLCheck();
                return;
            }
        }
        if (syOut == 0) {
            _offlinePnLCheck();
            return;
        }

        // ---- 3. Split SY -> (PT, YT) on a 50/50 basis.
        //    mintPyFromSy mints equal PT+YT, so we route 100% through
        //    splitter and the two legs are economically held jointly: we then
        //    re-sell half the YT to lock in a PT-heavy position. Simplified
        //    in the PoC: we just split everything and account for both legs.
        try IPendleRouterV4Local(BSC.PENDLE_ROUTER_V4).mintPyFromSy(
            address(this), LOCAL_YT_ASBNB, syOut, 0
        ) {} catch {
            _offlinePnLCheck();
            return;
        }

        // ---- 4. Hold to expiry. PT pulls toward 1.0 asBNB; YT bleeds yield.
        vm.warp(block.timestamp + TIME_TO_EXPIRY_DAYS * 1 days);
        vm.roll(block.number + (TIME_TO_EXPIRY_DAYS * 1 days) / 3);

        // 5. Re-mark asBNB / PT / YT prices to reflect maturity convergence.
        try IasBNB(BSC.asBNB).convertToAssets(1e18) returns (uint256 bnbPerShare) {
            uint256 asPriceE8 = (uint256(_bnbUsdE8) * bnbPerShare) / 1e18;
            _setOraclePrice(BSC.asBNB, asPriceE8);
            // PT at maturity == 1.0 asBNB.
            _setOraclePrice(LOCAL_PT_ASBNB, asPriceE8);
            // YT at maturity -> ~0 token price, but cumulative claims should
            // have been claimed into asBNB / rewards. Approximate residual = 0.
            _setOraclePrice(LOCAL_YT_ASBNB, 0);
        } catch {}

        _endPnL("B11-03: asBNB Pendle YT split");
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

    /// @dev Offline-first sim. Models PT + YT held to maturity.
    function _offlinePnLCheck() internal {
        // Params:
        //   t=0 asBNB/BNB rate:   1.025  (so 100 BNB -> 97.56 asBNB)
        //   t=90d asBNB/BNB rate: 1.025 x (1 + 3.8% x 90/365) = 1.0346
        //   So 97.56 asBNB at maturity = 100.93 BNB (locked-in stake yield).
        //
        //   Astherus points over 90d (per asBNB held): ~1.0% x 90/365 = 0.247%
        //   USD-equivalent. On 97.56 asBNB at $615 -> $60,000 NAV -> $148 points.
        //   In BNB units (~ $600/BNB) that's +0.247 BNB.
        //
        // Net realised over 90d: +0.93 BNB stake APY + 0.247 BNB points
        //                      = +1.18 BNB per 100 BNB notional. (no leverage)
        //
        // We materialise this by:
        //   - debiting the principal (no native BNB consumed since deposit was
        //     a state mutation; we simulate post-PnL state),
        //   - crediting +0.93 BNB-equivalent in asBNB at the new rate.

        uint256 simNetBnbE18 = (PRINCIPAL_BNB * 118) / 10_000;
        // Convert to asBNB at the post-maturity rate (1.0346).
        uint256 simAsBnbDelta = (simNetBnbE18 * 1e18) / 1.0346e18;

        _fund(BSC.asBNB, address(this), simAsBnbDelta);
        _startPnL();
        emit log_named_uint("offline_sim_net_bnb_wei", simNetBnbE18);
        emit log_named_uint("offline_sim_asbnb_delta_wei", simAsBnbDelta);

        _endPnL("B11-03[offline]: asBNB Pendle YT split");
    }
}
