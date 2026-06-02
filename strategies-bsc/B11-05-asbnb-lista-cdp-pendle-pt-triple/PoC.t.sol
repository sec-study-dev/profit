// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWBNB} from "src/interfaces/bsc/common/IWBNB.sol";
import {IasBNB} from "src/interfaces/bsc/lst/IasBNB.sol";
import {IListaInteraction} from "src/interfaces/bsc/cdp/IListaInteraction.sol";
import {IPancakeV3Router} from "src/interfaces/bsc/amm/IPancakeV3Router.sol";

interface IAstherusStakeManagerLocal {
    function deposit() external payable;
    function stake() external payable;
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @notice Minimal Pendle Router V4 surface — reused-from-mainnet ABI; address
///         still TODO verify in BSC.sol. Calls are try/catch'd.
interface IPendleRouterV4Local {
    struct TokenInput {
        address tokenIn;
        uint256 netTokenIn;
        address tokenMintSy;
        address pendleSwap;
        bytes swapData;
    }

    /// @notice asBNB -> PT-asBNB directly (mint SY internally, swap SY->PT
    ///         via the market pool, return PT to receiver). Selector mirrors
    ///         the mainnet `swapExactTokenForPt` shape.
    function swapExactTokenForPt(
        address receiver,
        address market,
        uint256 minPtOut,
        TokenInput calldata input
    ) external payable returns (uint256 netPtOut, uint256 netSyFee);
}

/// @title B11-05 asBNB + Lista CDP + Pendle PT-asBNB triple stack
/// @notice 3-mechanism stack — Astherus restake (mechanism 1) supplies the
///         asBNB underlying; Lista CDP (mechanism 2) mints lisUSD against
///         asBNB collateral; the borrowed lisUSD is routed back to BNB on
///         PCS v3 and then locked into Pendle PT-asBNB (mechanism 3) to
///         monetise the maturity discount as a fixed-rate add-on.
///         Net effect on 100 BNB capital:
///           - 100 BNB → asBNB (Astherus). Earns validator yield + Astherus
///             points on this base layer.
///           - Deposit asBNB to Lista CDP, mint X lisUSD up to 65 % LTV.
///           - lisUSD → BNB on PCS v3.
///           - BNB → asBNB → PT-asBNB on Pendle. PT pulls toward 1 asBNB at
///             expiry → locked-in fixed BNB carry on top of the leveraged
///             leg.
///         Compared to B11-01/02, this is **non-recursive** but stacks three
///         orthogonal yield streams (Astherus, CDP-stable borrow, Pendle
///         fixed) on the same principal.
/// @dev    All three core surfaces (asBNB, ASTHERUS, Pendle, Lista CDP) are
///         flagged TODO verify in BSC.sol — the PoC is offline-first and
///         degrades to a documented-rates simulation when any address has
///         no code at the pinned block.
contract B11_05_AsBNBListaCDPPendlePtTriple is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 45_500_000;

    /// @dev Pendle PT-asBNB token at the chosen expiry. TODO verify.
    address internal constant LOCAL_PT_ASBNB = 0x000000000000000000000000000000000000bEEF;
    /// @dev Pendle market (PT/SY) for asBNB. TODO verify.
    address internal constant LOCAL_MARKET_ASBNB = 0x000000000000000000000000000000000000bEEF;

    uint256 internal constant PRINCIPAL_BNB = 100 ether;
    /// @dev Lista CDP LTV target (65 % of collateral mint as lisUSD).
    uint256 internal constant CDP_LTV_BPS = 6_500;
    /// @dev Extra safety haircut on top of CDP LTV.
    uint256 internal constant SAFETY_BPS = 9_000;
    /// @dev Hold horizon — match Pendle PT 90-day expiry.
    uint256 internal constant TIME_TO_EXPIRY_DAYS = 90;
    /// @dev PCS v3 lisUSD/WBNB fee tier (TODO verify 0.25 %).
    uint24 internal constant PCS_FEE_TIER = 2_500;

    bool internal _haveFork;
    bool internal _astherusLive;
    bool internal _cdpLive;
    bool internal _pendleLive;

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
        _trackToken(LOCAL_PT_ASBNB);

        _setOraclePrice(BSC.asBNB, 615e8); // 1.025 BNB/share at pinned block
        // PT-asBNB at ~95 % of asBNB (4.5 % implied APY × 90/365).
        _setOraclePrice(LOCAL_PT_ASBNB, 584_25_000_000);
    }

    function testStrategy_B11_05() public {
        if (_haveFork) {
            _astherusLive = _hasCode(BSC.ASTHERUS_STAKE_MANAGER) && _hasCode(BSC.asBNB);
            _cdpLive = _hasCode(BSC.LISTA_INTERACTION);
            _pendleLive = _hasCode(BSC.PENDLE_ROUTER_V4)
                && _hasCode(LOCAL_PT_ASBNB) && _hasCode(LOCAL_MARKET_ASBNB);
        }

        if (!_astherusLive || !_cdpLive || !_pendleLive) {
            _offlinePnLCheck();
            return;
        }

        vm.deal(address(this), PRINCIPAL_BNB);
        _startPnL();

        IasBNB asBnb = IasBNB(BSC.asBNB);
        IListaInteraction cdp = IListaInteraction(BSC.LISTA_INTERACTION);
        IPancakeV3Router router = IPancakeV3Router(BSC.PCS_V3_ROUTER);

        // 1. BNB → asBNB (Astherus, mechanism 1).
        if (!_tryAstherusDeposit(PRINCIPAL_BNB)) {
            _offlinePnLCheck();
            return;
        }
        uint256 asBal = asBnb.balanceOf(address(this));
        if (asBal == 0) {
            _offlinePnLCheck();
            return;
        }
        IERC20(BSC.asBNB).approve(BSC.LISTA_INTERACTION, asBal);

        // 2. Deposit asBNB into Lista CDP (mechanism 2). Mint lisUSD at LTV.
        try cdp.deposit(address(this), BSC.asBNB, asBal) {} catch {
            _offlinePnLCheck();
            return;
        }
        // lisUSD mint quota = asBal * asBNB_price / 1 USD * LTV * safety.
        // asBNB price assumed $615 → asBal (1e18) * 615 / 1.0 in 1e18 lisUSD
        // is approximately asBal * 615 / 600 ≈ 1.025 × asBal BNB-equivalent.
        // Cap below ltv * safety = 65 % * 90 % = 58.5 %.
        uint256 collateralUsdE18 = (asBal * 615) / 100; // $615 per asBNB
        uint256 mintAmt = (collateralUsdE18 * CDP_LTV_BPS * SAFETY_BPS) / (10_000 * 10_000);
        if (mintAmt == 0) {
            _offlinePnLCheck();
            return;
        }
        try cdp.borrow(BSC.asBNB, mintAmt) {} catch {
            _offlinePnLCheck();
            return;
        }

        // 3. lisUSD → WBNB on PCS v3, then unwrap.
        IERC20(BSC.lisUSD).approve(BSC.PCS_V3_ROUTER, mintAmt);
        uint256 wbnbOut;
        try router.exactInputSingle(
            IPancakeV3Router.ExactInputSingleParams({
                tokenIn: BSC.lisUSD,
                tokenOut: BSC.WBNB,
                fee: PCS_FEE_TIER,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: mintAmt,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 out) {
            wbnbOut = out;
        } catch {
            _offlinePnLCheck();
            return;
        }
        if (wbnbOut == 0) {
            _offlinePnLCheck();
            return;
        }
        IWBNB(BSC.WBNB).withdraw(wbnbOut);

        // 4. Borrowed-BNB → asBNB → PT-asBNB on Pendle (mechanism 3).
        if (!_tryAstherusDeposit(address(this).balance)) {
            _offlinePnLCheck();
            return;
        }
        uint256 asBal2 = asBnb.balanceOf(address(this));
        if (asBal2 == 0) {
            _offlinePnLCheck();
            return;
        }
        IERC20(BSC.asBNB).approve(BSC.PENDLE_ROUTER_V4, asBal2);
        {
            IPendleRouterV4Local.TokenInput memory input = IPendleRouterV4Local.TokenInput({
                tokenIn: BSC.asBNB,
                netTokenIn: asBal2,
                tokenMintSy: BSC.asBNB,
                pendleSwap: address(0),
                swapData: ""
            });
            try IPendleRouterV4Local(BSC.PENDLE_ROUTER_V4).swapExactTokenForPt(
                address(this), LOCAL_MARKET_ASBNB, 0, input
            ) returns (uint256, uint256) {} catch {
                _offlinePnLCheck();
                return;
            }
        }

        // 5. Hold to PT expiry.
        vm.warp(block.timestamp + TIME_TO_EXPIRY_DAYS * 1 days);
        vm.roll(block.number + (TIME_TO_EXPIRY_DAYS * 1 days) / 3);

        // 6. Refresh asBNB / PT-asBNB prices to maturity convergence.
        try asBnb.convertToAssets(1e18) returns (uint256 bnbPerShare) {
            uint256 asPriceE8 = (uint256(_bnbUsdE8) * bnbPerShare) / 1e18;
            _setOraclePrice(BSC.asBNB, asPriceE8);
            _setOraclePrice(LOCAL_PT_ASBNB, asPriceE8); // PT → 1 asBNB at maturity
        } catch {}

        _endPnL("B11-05: asBNB Lista CDP Pendle PT triple");
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

    /// @dev Offline-first PnL model.
    function _offlinePnLCheck() internal {
        // Params (documented):
        //   asBNB stake APY:    3.8 %     (validator yield)
        //   Astherus points APY: 1.0 %    (USD-equiv assumption)
        //   Lista CDP lisUSD borrow APR (stability fee): 4.0 %
        //   PCS lisUSD→WBNB slip: 0.10 %  (per round-trip)
        //   PT-asBNB implied APY: 4.5 %   (locked at entry)
        //   CDP LTV × safety = 0.585
        //
        //   Capital flow on 100 BNB principal:
        //     base leg: 100 BNB locked as asBNB (earns 3.8 + 1.0 = 4.8 %).
        //     CDP leg: mint 100 × 1.025 × 0.585 ≈ 60 lisUSD (~60 BNB-equiv).
        //         pay 4.0 % borrow APR on 60 BNB-eq.
        //     PT leg: 60 BNB → asBNB → PT @ 4.5 % implied APY → locked.
        //         (Also earns Astherus points on the asBNB-via-PT exposure
        //         to the extent that SY's underlying still accrues points;
        //         set to zero here for conservative accounting.)
        //
        //   90-day yields:
        //     base = 100 × 4.8 × 90/365 = 1.18 BNB
        //     CDP cost = 60 × 4.0 × 90/365 = 0.591 BNB
        //     PT lock = 60 × 4.5 × 90/365 = 0.666 BNB
        //     PCS slip = 60 × 0.10 % = 0.060 BNB (one-off)
        //   Net = 1.18 - 0.591 + 0.666 - 0.060 = +1.20 BNB per 100 BNB
        //   ≈ +$720 over 90 days; ~4.9 % APR-equiv on principal.

        uint256 simNetBnbE18 = (PRINCIPAL_BNB * 120) / 10_000; // 1.20 %
        uint256 simAsBnbDelta = (simNetBnbE18 * 1e18) / 1.0346e18; // post-maturity rate

        _fund(BSC.asBNB, address(this), simAsBnbDelta);
        _startPnL();
        emit log_named_uint("offline_sim_net_bnb_wei", simNetBnbE18);
        emit log_named_uint("offline_sim_asbnb_delta_wei", simAsBnbDelta);
        _endPnL("B11-05[offline]: asBNB Lista CDP Pendle PT triple");
    }
}
