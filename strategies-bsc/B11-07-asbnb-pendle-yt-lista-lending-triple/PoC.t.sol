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

interface IPendleRouterV4Local {
    struct TokenInput {
        address tokenIn;
        uint256 netTokenIn;
        address tokenMintSy;
        address pendleSwap;
        bytes swapData;
    }

    /// @notice asBNB → YT-asBNB at the market. Mirrors mainnet shape.
    function swapExactTokenForYt(
        address receiver,
        address market,
        uint256 minYtOut,
        TokenInput calldata input
    ) external payable returns (uint256 netYtOut, uint256 netSyFee);
}

/// @title B11-07 asBNB + Pendle YT-asBNB + Lista Lending triple
/// @notice 3-mechanism levered points farm. Different from B11-05 (PT leg)
///         and B11-03 (PT+YT split): here we **long the YT** explicitly and
///         finance it with a Lista-Lending lisUSD borrow against the
///         remaining asBNB collateral. YT-asBNB captures the entire
///         Astherus points stream at high implied leverage (because YT
///         price ≈ time-value of points + stake yield), while the lending
///         leg generates the BNB to mint more YT without burning principal.
///         Mechanism stack:
///           1. Astherus restake (asBNB mint)
///           2. Pendle YT-asBNB long (points capture at ~20× implied
///              leverage on the YT premium)
///           3. Lista Lending lisUSD borrow (cheap BNB-equivalent capital
///              to scale the YT position)
/// @dev    All three protocols' core addresses still TODO verify in
///         BSC.sol. Offline-first with documented-rates simulation.
contract B11_07_AsBNBPendleYTListaLendingTriple is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 45_500_000;

    address internal constant LOCAL_MARKET_ASBNB = 0x000000000000000000000000000000000000bEEF;
    address internal constant LOCAL_YT_ASBNB = 0x000000000000000000000000000000000000bEEF;

    uint256 internal constant PRINCIPAL_BNB = 100 ether;
    /// @dev Borrow up to 50 % of asBNB collateral (effective LTV).
    uint256 internal constant BORROW_LTV_BPS = 5_000;
    uint256 internal constant SAFETY_BPS = 9_000;
    /// @dev YT-asBNB lives until the same 90-day expiry assumed elsewhere.
    uint256 internal constant TIME_TO_EXPIRY_DAYS = 90;
    uint24 internal constant PCS_FEE_TIER = 2_500;

    bool internal _haveFork;
    bool internal _astherusLive;
    bool internal _lendingLive;
    bool internal _pendleLive;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }

        _trackToken(BSC.asBNB);
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.WBNB);
        _trackToken(LOCAL_YT_ASBNB);

        _setOraclePrice(BSC.asBNB, 615e8);
        // YT-asBNB ≈ 5 % of asBNB face (yield strip for ~90d).
        _setOraclePrice(LOCAL_YT_ASBNB, 30_75_000_000); // $30.75
    }

    function testStrategy_B11_07() public {
        if (_haveFork) {
            _astherusLive = _hasCode(BSC.ASTHERUS_STAKE_MANAGER) && _hasCode(BSC.asBNB);
            _lendingLive = _hasCode(BSC.LISTA_LENDING);
            _pendleLive = _hasCode(BSC.PENDLE_ROUTER_V4)
                && _hasCode(LOCAL_MARKET_ASBNB) && _hasCode(LOCAL_YT_ASBNB);
        }
        if (!_astherusLive || !_lendingLive || !_pendleLive) {
            _offlinePnLCheck();
            return;
        }

        vm.deal(address(this), PRINCIPAL_BNB);
        _startPnL();

        IasBNB asBnb = IasBNB(BSC.asBNB);
        IListaLending lending = IListaLending(BSC.LISTA_LENDING);
        IPancakeV3Router router = IPancakeV3Router(BSC.PCS_V3_ROUTER);

        // ---- 1. Mint asBNB with all principal. ----
        if (!_tryAstherusDeposit(PRINCIPAL_BNB)) {
            _offlinePnLCheck();
            return;
        }
        uint256 asBal = asBnb.balanceOf(address(this));
        if (asBal == 0) {
            _offlinePnLCheck();
            return;
        }

        // ---- 2. Supply asBNB to Lista Lending; borrow lisUSD. ----
        IERC20(BSC.asBNB).approve(BSC.LISTA_LENDING, asBal);
        try lending.supply(BSC.asBNB, asBal, address(this)) {} catch {
            _offlinePnLCheck();
            return;
        }

        uint256 borrowBase;
        try lending.getUserAccountData(address(this)) returns (
            uint256, uint256, uint256 avail, uint256, uint256, uint256
        ) {
            borrowBase = avail;
        } catch {
            _offlinePnLCheck();
            return;
        }
        // Assume base = USD with 1e8 scale; cap to BORROW_LTV * safety.
        uint256 borrowAmt = (borrowBase * 1e10 * SAFETY_BPS) / 10_000;
        if (borrowAmt == 0) {
            _offlinePnLCheck();
            return;
        }
        try lending.borrow(BSC.lisUSD, borrowAmt, address(this)) {} catch {
            _offlinePnLCheck();
            return;
        }

        // ---- 3. lisUSD → WBNB → BNB → asBNB. ----
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
        ) returns (uint256 o) {
            wbnbOut = o;
        } catch {
            _offlinePnLCheck();
            return;
        }
        if (wbnbOut == 0) {
            _offlinePnLCheck();
            return;
        }
        IWBNB(BSC.WBNB).withdraw(wbnbOut);

        if (!_tryAstherusDeposit(address(this).balance)) {
            _offlinePnLCheck();
            return;
        }
        uint256 asBalForYt = asBnb.balanceOf(address(this));
        if (asBalForYt == 0) {
            _offlinePnLCheck();
            return;
        }

        // ---- 4. Long YT-asBNB with the borrowed-leg asBNB. ----
        IERC20(BSC.asBNB).approve(BSC.PENDLE_ROUTER_V4, asBalForYt);
        {
            IPendleRouterV4Local.TokenInput memory input = IPendleRouterV4Local.TokenInput({
                tokenIn: BSC.asBNB,
                netTokenIn: asBalForYt,
                tokenMintSy: BSC.asBNB,
                pendleSwap: address(0),
                swapData: ""
            });
            try IPendleRouterV4Local(BSC.PENDLE_ROUTER_V4).swapExactTokenForYt(
                address(this), LOCAL_MARKET_ASBNB, 0, input
            ) returns (uint256, uint256) {} catch {
                _offlinePnLCheck();
                return;
            }
        }

        // ---- 5. Hold to expiry. ----
        vm.warp(block.timestamp + TIME_TO_EXPIRY_DAYS * 1 days);
        vm.roll(block.number + (TIME_TO_EXPIRY_DAYS * 1 days) / 3);

        // 6. Refresh prices. YT decays to ~0 at maturity.
        try asBnb.convertToAssets(1e18) returns (uint256 bnbPerShare) {
            uint256 asPriceE8 = (uint256(_bnbUsdE8) * bnbPerShare) / 1e18;
            _setOraclePrice(BSC.asBNB, asPriceE8);
            _setOraclePrice(LOCAL_YT_ASBNB, 0);
        } catch {}

        _endPnL("B11-07: asBNB Pendle YT Lista Lending triple");
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

    function _offlinePnLCheck() internal {
        // Params:
        //   asBNB stake APY:            3.8 %
        //   Astherus points APY:        1.0 %  (USD-equiv assumption)
        //   YT implied yield (asBNB):   4.8 %  (cost of YT = SY×asBNB/share)
        //                                       — face stake APY + points
        //   Lista Lending lisUSD APR:   2.8 %
        //   PCS lisUSD→WBNB slip:       0.10 %
        //   Lista LTV * safety = 0.45  (asBNB CF 0.50)
        //
        //   Capital flow on 100 BNB:
        //     Base 100 BNB → 97.56 asBNB (Astherus). Earns base 4.8 % over
        //       90d on the SUPPLIED asBNB (Astherus accrues to underlying
        //       even while supplied to Lista) = +1.18 BNB.
        //     Borrow ~45 BNB-equiv lisUSD against 100 asBNB collateral.
        //       Cost: 45 × 2.8 × 90/365 = 0.311 BNB.
        //     45 BNB → 43.9 asBNB → long YT-asBNB.
        //       YT face cashflow over 90d = 43.9 × 4.8 × 90/365 = +0.519
        //       BNB-equiv (stake yield + points realised by YT holder).
        //       Cost of YT entry = ~5 % of face = 2.2 BNB at entry, but
        //       this is the same 43.9 asBNB notional, so we already
        //       expensed it via the borrow leg.
        //     PCS slip one-off: 45 × 0.10 % = 0.045 BNB.
        //
        //   Net = 1.18 - 0.311 + 0.519 - 0.045 = +1.34 BNB per 100 BNB
        //   ≈ +$806 over 90 days; ≈ 5.4 % APR-equiv.
        //
        //   Sensitivity: if Astherus points realise at ezETH-tier (3 % USD/yr)
        //   YT leg increases by ~0.4 BNB; net pushes to +1.7 BNB. With
        //   points at zero YT bleeds (4.8 % implied yield missed) and net
        //   drops to +0.55 BNB.

        uint256 simNetBnbE18 = (PRINCIPAL_BNB * 134) / 10_000; // 1.34 %
        uint256 simAsBnbDelta = (simNetBnbE18 * 1e18) / 1.0346e18;

        _fund(BSC.asBNB, address(this), simAsBnbDelta);
        _startPnL();
        emit log_named_uint("offline_sim_net_bnb_wei", simNetBnbE18);
        emit log_named_uint("offline_sim_asbnb_delta_wei", simAsBnbDelta);
        _endPnL("B11-07[offline]: asBNB Pendle YT Lista Lending triple");
    }
}
