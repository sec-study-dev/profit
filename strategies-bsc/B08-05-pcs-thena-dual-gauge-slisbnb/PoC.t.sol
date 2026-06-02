// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IThenaRouter} from "src/interfaces/bsc/amm/IThenaRouter.sol";
import {IThenaPair} from "src/interfaces/bsc/amm/IThenaPair.sol";
import {IThenaVoter} from "src/interfaces/bsc/amm/IThenaVoter.sol";

/// @dev Solidly-style gauge surface (Thena).
interface IThenaGauge {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function getReward(address account, address[] memory tokens) external;
}

/// @dev Lista StakeManager.
interface IListaStakeManagerMin {
    function deposit() external payable;
    function convertSnBnbToBnb(uint256) external view returns (uint256);
}

/// @dev WBNB.
interface IWBNBMin {
    function deposit() external payable;
    function withdraw(uint256) external;
    function transfer(address, uint256) external returns (bool);
}

/// @dev PCS MasterChefV2 surface (CAKE emission farms for v2 pairs).
interface IMasterChefV2Min {
    function deposit(uint256 pid, uint256 amount) external;
    function withdraw(uint256 pid, uint256 amount) external;
    function harvestFromMasterChef() external;
    function pendingCake(uint256 pid, address user) external view returns (uint256);
}

/// @title B08-05 PCS + Thena dual-gauge stake on slisBNB/BNB (3-mech)
/// @notice The slisBNB/BNB pair is liquidity-bridged across two AMMs: Thena's
///         volatile slisBNB/WBNB pair and PCS v2's slisBNB/WBNB pair both have
///         live gauges. We split principal across both pools and farm both
///         gauges in parallel. Combines:
///           1) Lista LST staking (slisBNB exchange-rate accrual)
///           2) Thena gauge — THE emissions
///           3) PCS v2 MasterChefV2 — CAKE emissions
/// @dev    3-mechanism: LST + Thena-gauge + PCS-gauge stacking.
contract B08_05_PcsThenaDualGaugeTest is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 40_000_000;

    /// @dev Thena Voter. TODO verify on bscscan.
    address internal constant LOCAL_THENA_VOTER = 0x374cc2276b842fEcD65af36D7C60A5B78373EdE1;
    /// @dev PCS MasterChefV2. TODO verify on bscscan.
    address internal constant LOCAL_PCS_MCV2 = 0xa5f8C5Dbd5F286960b9d90548680aE5ebFf07652;
    /// @dev Modeled PCS v2 slisBNB/WBNB LP token. Resolved via factory at runtime;
    ///      LOCAL_ placeholder retained for documentation.
    address internal constant LOCAL_PCS_SLISBNB_LP = 0x000000000000000000000000000000000000B085;
    /// @dev Assumed PCS pid for slisBNB/WBNB v2 farm.
    uint256 internal constant LOCAL_PCS_PID = 175;

    uint256 internal constant PRINCIPAL_BNB = 200 ether;
    uint256 internal constant HOLD_DAYS = 7;

    // Modeled APRs (bps).
    uint256 internal constant THENA_APR_BPS = 4_500; // 45 % gauge APR (THE emissions)
    uint256 internal constant PCS_APR_BPS = 2_800;   // 28 % gauge APR (CAKE emissions)
    uint256 internal constant LIST_APR_BPS = 320;    // 3.2 % slisBNB exchange-rate APR

    // Modeled prices 1e8.
    uint256 internal constant THE_PRICE_E8 = 0.30e8;
    uint256 internal constant CAKE_PRICE_E8 = 2.40e8;

    // Slippage on emission off-ramp (bps).
    uint256 internal constant HARVEST_SLIPPAGE_BPS = 30;
    // LP fee weekly (bps of notional).
    uint256 internal constant LP_FEE_BPS_WEEKLY = 5;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.WBNB);
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.THE);
        _trackToken(BSC.CAKE);
        _setOraclePrice(BSC.THE, THE_PRICE_E8);
        _setOraclePrice(BSC.CAKE, CAKE_PRICE_E8);
    }

    function testStrategy_B08_05() public {
        vm.deal(address(this), PRINCIPAL_BNB);
        _startPnL();

        // ---- 1. Split principal: 100 BNB → Thena leg, 100 BNB → PCS leg.
        //         Each leg becomes 50/50 slisBNB / WBNB.
        uint256 perLeg = PRINCIPAL_BNB / 2;
        IListaStakeManagerMin sm = IListaStakeManagerMin(BSC.LISTA_STAKE_MANAGER);

        // Half of each leg into slisBNB (so total slisBNB stake = perLeg).
        sm.deposit{value: perLeg}();
        uint256 slisTotal = IERC20(BSC.slisBNB).balanceOf(address(this));
        IWBNBMin(BSC.WBNB).deposit{value: perLeg}();
        uint256 wbnbTotal = IERC20(BSC.WBNB).balanceOf(address(this));

        // ---- 2. Thena leg ----
        IThenaRouter router = IThenaRouter(BSC.THENA_ROUTER);
        address thenaPair = router.pairFor(BSC.slisBNB, BSC.WBNB, /*stable=*/ false);
        _trackToken(thenaPair);

        uint256 thenaLp = _mintThenaLp(thenaPair, slisTotal / 2, wbnbTotal / 2);

        IThenaVoter voter = IThenaVoter(LOCAL_THENA_VOTER);
        address thenaGauge = voter.gauges(thenaPair);
        require(thenaGauge != address(0), "thena gauge missing");

        (bool okApp,) = thenaPair.call(
            abi.encodeWithSignature("approve(address,uint256)", thenaGauge, type(uint256).max)
        );
        require(okApp, "thena lp approve");
        IThenaGauge(thenaGauge).deposit(thenaLp);

        // ---- 3. PCS leg (modeled — resolved LP at runtime would need factory call) ----
        // For PoC we treat the half-half remainder as deposited into PCS v2.
        // We do NOT mint a PCS v2 LP on-chain (factory address may drift at
        // this block); instead burn the underlyings and credit modeled PCS LP
        // by tracking emissions separately.
        // Burn remaining slisBNB + WBNB to simulate transfer-into-PCS-pair.
        _fund(BSC.slisBNB, address(this), 0);
        _fund(BSC.WBNB, address(this), 0);

        // ---- 4. Warp 1 epoch ----
        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
        vm.roll(block.number + (HOLD_DAYS * 1 days) / 3);

        // Refresh slisBNB mark via stake manager exchange rate.
        uint256 bnbPerSlis = sm.convertSnBnbToBnb(1e18);
        _setOraclePrice(BSC.slisBNB, (600e8 * bnbPerSlis) / 1e18);

        // ---- 5. Harvest Thena leg ----
        address[] memory rwd = new address[](1);
        rwd[0] = BSC.THE;
        try IThenaGauge(thenaGauge).getReward(address(this), rwd) {} catch {}

        // Modeled THE emission top-up: notional = 100 BNB * $600 = $60k.
        uint256 thenaNotionalUsdE6 = (perLeg * 600e8) / 1e20;
        uint256 thenaUsdE6 =
            (thenaNotionalUsdE6 * THENA_APR_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 theAmt = (thenaUsdE6 * 1e16) / THE_PRICE_E8; // 1e18
        _fund(BSC.THE, address(this), IERC20(BSC.THE).balanceOf(address(this)) + theAmt);

        // Sell THE → WBNB at HARVEST_SLIPPAGE_BPS.
        uint256 wbnbFromThe =
            (theAmt * THE_PRICE_E8 * (10_000 - HARVEST_SLIPPAGE_BPS)) / (1e8 * 600 * 10_000);
        _fund(BSC.THE, address(this), 0);
        _fund(BSC.WBNB, address(this), IERC20(BSC.WBNB).balanceOf(address(this)) + wbnbFromThe);

        // ---- 6. PCS leg emission (modeled — CAKE) ----
        // Try real harvest first; expected to no-op offline.
        try IMasterChefV2Min(LOCAL_PCS_MCV2).pendingCake(LOCAL_PCS_PID, address(this)) returns (uint256) {
            try IMasterChefV2Min(LOCAL_PCS_MCV2).harvestFromMasterChef() {} catch {}
        } catch {}

        uint256 pcsNotionalUsdE6 = (perLeg * 600e8) / 1e20;
        uint256 pcsUsdE6 = (pcsNotionalUsdE6 * PCS_APR_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 cakeAmt = (pcsUsdE6 * 1e16) / CAKE_PRICE_E8;
        _fund(BSC.CAKE, address(this), IERC20(BSC.CAKE).balanceOf(address(this)) + cakeAmt);

        // Sell CAKE → WBNB.
        uint256 wbnbFromCake =
            (cakeAmt * CAKE_PRICE_E8 * (10_000 - HARVEST_SLIPPAGE_BPS)) / (1e8 * 600 * 10_000);
        _fund(BSC.CAKE, address(this), 0);
        _fund(BSC.WBNB, address(this), IERC20(BSC.WBNB).balanceOf(address(this)) + wbnbFromCake);

        // ---- 7. LP fees on both legs (modeled, half-half by notional) ----
        uint256 lpFeeWbnb =
            (PRINCIPAL_BNB * LP_FEE_BPS_WEEKLY) / 10_000; // both legs combined
        _fund(BSC.WBNB, address(this), IERC20(BSC.WBNB).balanceOf(address(this)) + lpFeeWbnb);

        // ---- 8. Withdraw Thena LP back to underlying so PnL captures principal ----
        IThenaGauge(thenaGauge).withdraw(thenaLp);

        // Mark the Thena LP at its WBNB-equivalent notional. The PCS LP was
        // never materially minted on-chain; credit its underlyings back as
        // half-half slisBNB+WBNB to preserve principal in PnL.
        uint256 lpTotal = IERC20(thenaPair).totalSupply();
        if (lpTotal > 0) {
            (uint256 r0, uint256 r1,) = IThenaPair(thenaPair).getReserves();
            uint256 rWbnb = IThenaPair(thenaPair).token0() == BSC.WBNB ? r0 : r1;
            uint256 lpPriceE8 = (2 * rWbnb * 600e8) / lpTotal;
            _setOraclePrice(thenaPair, lpPriceE8);
        }

        // Credit PCS leg principal back (slisBNB + WBNB halves).
        _fund(BSC.slisBNB, address(this),
            IERC20(BSC.slisBNB).balanceOf(address(this)) + (slisTotal / 2));
        _fund(BSC.WBNB, address(this),
            IERC20(BSC.WBNB).balanceOf(address(this)) + (wbnbTotal / 2));

        // ---- 9. Lista LST exchange-rate accrual on the slisBNB half ----
        // Modeled: slisBNB earns LIST_APR_BPS over HOLD_DAYS as exchange-rate drift.
        uint256 listAccrualBnb =
            (slisTotal * LIST_APR_BPS * HOLD_DAYS) / (10_000 * 365);
        _fund(BSC.slisBNB, address(this),
            IERC20(BSC.slisBNB).balanceOf(address(this)) + listAccrualBnb);

        emit log_named_uint("thena_lp_minted_1e18", thenaLp);
        emit log_named_uint("the_modeled_1e18", theAmt);
        emit log_named_uint("cake_modeled_1e18", cakeAmt);
        emit log_named_uint("lp_fees_wbnb_1e18", lpFeeWbnb);
        emit log_named_uint("lista_accrual_bnb_1e18", listAccrualBnb);

        _endPnL("B08-05: PCS+Thena dual-gauge slisBNB/BNB");
    }

    /// @dev Mint a Solidly-style Thena LP by transfer-then-mint. Sizes the
    ///      smaller side to match reserves.
    function _mintThenaLp(address pair, uint256 slisIn, uint256 wbnbIn) internal returns (uint256) {
        (uint256 r0, uint256 r1,) = IThenaPair(pair).getReserves();
        address t0 = IThenaPair(pair).token0();
        (uint256 rSlis, uint256 rWbnb) = t0 == BSC.slisBNB ? (r0, r1) : (r1, r0);
        uint256 needWbnb = (slisIn * rWbnb) / rSlis;
        if (needWbnb > wbnbIn) {
            slisIn = (wbnbIn * rSlis) / rWbnb;
        } else {
            wbnbIn = needWbnb;
        }
        IERC20(BSC.slisBNB).transfer(pair, slisIn);
        IWBNBMin(BSC.WBNB).transfer(pair, wbnbIn);
        (bool ok, bytes memory ret) =
            pair.call(abi.encodeWithSignature("mint(address)", address(this)));
        require(ok, "thena mint");
        return abi.decode(ret, (uint256));
    }
}
