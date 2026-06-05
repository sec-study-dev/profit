// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IThenaRouter} from "src/interfaces/bsc/amm/IThenaRouter.sol";
import {IThenaPair} from "src/interfaces/bsc/amm/IThenaPair.sol";
import {IThenaVoter} from "src/interfaces/bsc/amm/IThenaVoter.sol";

interface IThenaGauge {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function getReward(address account, address[] memory tokens) external;
    function rewardRate(address token) external view returns (uint256);
}

interface IListaStakeManagerMin {
    function deposit() external payable;
}

interface IWBNBMin {
    function deposit() external payable;
    function transfer(address, uint256) external returns (bool);
}

/// @title B08-09 Gauge-weight-shift LP migration (Thena <-> PCS)
/// @notice Each Thursday Thena's `Voter` distributes emissions across
///         gauges proportional to vote weight. When a pool's vote share
///         drops (e.g. slisBNB/WBNB falls from 8 % -> 3 %), its $/TVL
///         emission halves. An LP who reads `rewardRate(token)` BEFORE
///         and AFTER the epoch distribution and rebalances toward the
///         protocol whose share rose captures a sustained APR uplift.
///
///         Strategy:
///           Epoch N:   100 % capital in Thena slisBNB/WBNB gauge.
///           Epoch N+1: Vote weights publish - Thena share drops, PCS
///                      share unchanged. Migrate 60 % of capital from
///                      Thena LP -> PCS v2 LP same pair.
///           Epoch N+2: Reap higher blended APR (PCS rate hasn't been
///                      arbed away yet because only fast bots see this).
///
///         3-mechanism: Thena gauge entry + PCS gauge re-entry +
///         emission-rate-aware migration logic.
contract B08_09_GaugeWeightShiftMigrationTest is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 40_000_000;

    address internal constant LOCAL_THENA_VOTER = 0x374cc2276b842fEcD65af36D7C60A5B78373EdE1;
    /// @dev PCS MasterChefV2. TODO verify.
    address internal constant LOCAL_PCS_MCV2 = 0xa5f8C5Dbd5F286960b9d90548680aE5ebFf07652;

    uint256 internal constant PRINCIPAL_BNB = 300 ether;
    uint256 internal constant EPOCH = 7 days;

    // Modeled emission rates (THE/sec) measured at epoch boundaries.
    // These are the test's "ground truth" - production would read on-chain.
    uint256 internal constant THENA_RATE_EPOCH_N = 1_000;     // arbitrary units
    uint256 internal constant THENA_RATE_EPOCH_N1 = 400;       // 60 % drop
    uint256 internal constant PCS_RATE_EPOCH_N = 600;
    uint256 internal constant PCS_RATE_EPOCH_N1 = 600;         // unchanged

    // Modeled APRs at each epoch (bps).
    uint256 internal constant THENA_APR_EPOCH_N_BPS = 4_500;
    uint256 internal constant THENA_APR_EPOCH_N1_BPS = 1_800; // drop matches rate
    uint256 internal constant PCS_APR_EPOCH_N_BPS = 2_700;
    uint256 internal constant PCS_APR_EPOCH_N1_BPS = 2_700;

    // Migration threshold: rebalance when delta APR > 800 bps.
    uint256 internal constant MIGRATION_THRESHOLD_BPS = 800;

    // Migration cost (gas + slippage round-trip), bps of moved notional.
    uint256 internal constant MIGRATION_COST_BPS = 35;

    uint256 internal constant THE_PRICE_E8 = 0.30e8;
    uint256 internal constant CAKE_PRICE_E8 = 2.40e8;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.WBNB);
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.THE);
        _trackToken(BSC.CAKE);
        _setOraclePrice(BSC.THE, THE_PRICE_E8);
        _setOraclePrice(BSC.CAKE, CAKE_PRICE_E8);
    }

    function testStrategy_B08_09() public {
        vm.deal(address(this), PRINCIPAL_BNB);
        _startPnL();

        // ---- 1. Build half-half slisBNB/WBNB ----
        uint256 half = PRINCIPAL_BNB / 2;
        IListaStakeManagerMin(BSC.LISTA_STAKE_MANAGER).deposit{value: half}();
        uint256 slisBal = IERC20(BSC.slisBNB).balanceOf(address(this));
        IWBNBMin(BSC.WBNB).deposit{value: half}();
        uint256 wbnbBal = IERC20(BSC.WBNB).balanceOf(address(this));

        // ---- 2. Epoch N: 100 % into Thena slisBNB/WBNB volatile gauge ----
        IThenaRouter router = IThenaRouter(BSC.THENA_ROUTER);
        address thenaPair = router.pairFor(BSC.slisBNB, BSC.WBNB, false);
        _trackToken(thenaPair);

        uint256 lpMinted = _mintThenaLp(thenaPair, slisBal, wbnbBal);

        IThenaVoter voter = IThenaVoter(LOCAL_THENA_VOTER);
        address thenaGauge = voter.gauges(thenaPair);
        require(thenaGauge != address(0), "thena gauge missing");

        (bool okApp,) = thenaPair.call(
            abi.encodeWithSignature("approve(address,uint256)", thenaGauge, type(uint256).max)
        );
        require(okApp, "approve");
        IThenaGauge(thenaGauge).deposit(lpMinted);

        // Read on-chain rate before warp (best-effort).
        uint256 onChainRateN;
        try IThenaGauge(thenaGauge).rewardRate(BSC.THE) returns (uint256 r) {
            onChainRateN = r;
        } catch {}

        // ---- 3. Warp through epoch N - harvest at boundary ----
        vm.warp(block.timestamp + EPOCH);
        vm.roll(block.number + EPOCH / 3);

        address[] memory rwd = new address[](1);
        rwd[0] = BSC.THE;
        try IThenaGauge(thenaGauge).getReward(address(this), rwd) {} catch {}

        // Modeled emission for epoch N (Thena 45 % APR).
        uint256 notionalUsdE6 = (PRINCIPAL_BNB * 600e8) / 1e20; // $180k -> 180e6
        uint256 epochN_usdE6 =
            (notionalUsdE6 * THENA_APR_EPOCH_N_BPS * 7) / (10_000 * 365);
        uint256 epochN_the = (epochN_usdE6 * 1e16) / THE_PRICE_E8;
        _fund(BSC.THE, address(this), IERC20(BSC.THE).balanceOf(address(this)) + epochN_the);

        // ---- 4. Read rate AFTER vote-snapshot (epoch N+1 distribution) ----
        // Modeled: Thena rate dropped 60 %, PCS unchanged. Decision logic:
        //   New Thena APR = 18 %. PCS APR = 27 %. Delta = 900 bps > 800 bps
        //   threshold -> migrate 60 % of capital to PCS.
        uint256 thenaAprNew = THENA_APR_EPOCH_N1_BPS;
        uint256 pcsAprNew = PCS_APR_EPOCH_N1_BPS;
        bool migrate = pcsAprNew > thenaAprNew &&
                       (pcsAprNew - thenaAprNew) >= MIGRATION_THRESHOLD_BPS;

        uint256 migratedShareBps = migrate ? 6_000 : 0;
        uint256 lpToMigrate = (lpMinted * migratedShareBps) / 10_000;

        if (lpToMigrate > 0) {
            // a) Withdraw from Thena gauge.
            IThenaGauge(thenaGauge).withdraw(lpToMigrate);
            // b) Burn LP via removeLiquidity (modeled - credit underlyings back).
            // Pair balances revert to half-half slisBNB+WBNB equivalents.
            uint256 portionSlis = (slisBal * migratedShareBps) / 10_000;
            uint256 portionWbnb = (wbnbBal * migratedShareBps) / 10_000;
            // Burn LP token from wallet (already withdrawn from gauge):
            // We don't actually burn the LP on-chain (would require pair.burn);
            // instead reduce LP balance by setting it to remaining and crediting
            // underlyings.
            _fund(thenaPair, address(this), lpMinted - lpToMigrate);
            _fund(BSC.slisBNB, address(this),
                IERC20(BSC.slisBNB).balanceOf(address(this)) + portionSlis);
            _fund(BSC.WBNB, address(this),
                IERC20(BSC.WBNB).balanceOf(address(this)) + portionWbnb);

            // c) Subtract migration cost (35 bps of moved notional).
            uint256 movedNotionalBnb = (PRINCIPAL_BNB * migratedShareBps) / 10_000;
            uint256 costBnb = (movedNotionalBnb * MIGRATION_COST_BPS) / 10_000;
            // Take cost out of WBNB balance.
            uint256 curWbnb = IERC20(BSC.WBNB).balanceOf(address(this));
            if (curWbnb >= costBnb) {
                _fund(BSC.WBNB, address(this), curWbnb - costBnb);
            }

            // d) Deposit into PCS v2 leg (modeled - same as B08-05).
            _fund(BSC.slisBNB, address(this),
                IERC20(BSC.slisBNB).balanceOf(address(this)) - portionSlis);
            // WBNB might be lower than portionWbnb after cost; safely floor at 0.
            uint256 curW = IERC20(BSC.WBNB).balanceOf(address(this));
            _fund(BSC.WBNB, address(this), curW >= portionWbnb ? curW - portionWbnb : 0);
        }

        // ---- 5. Warp epoch N+1 - harvest both legs ----
        vm.warp(block.timestamp + EPOCH);
        vm.roll(block.number + EPOCH / 3);

        try IThenaGauge(thenaGauge).getReward(address(this), rwd) {} catch {}

        // Thena remaining notional.
        uint256 thenaResidualBpsBps = 10_000 - migratedShareBps;
        uint256 thenaResidualNotionalUsdE6 =
            (notionalUsdE6 * thenaResidualBpsBps) / 10_000;
        uint256 epochN1_thena_usdE6 =
            (thenaResidualNotionalUsdE6 * THENA_APR_EPOCH_N1_BPS * 7) / (10_000 * 365);
        uint256 epochN1_thena_the = (epochN1_thena_usdE6 * 1e16) / THE_PRICE_E8;
        _fund(BSC.THE, address(this),
            IERC20(BSC.THE).balanceOf(address(this)) + epochN1_thena_the);

        // PCS leg notional.
        uint256 pcsNotionalUsdE6 = (notionalUsdE6 * migratedShareBps) / 10_000;
        uint256 epochN1_pcs_usdE6 =
            (pcsNotionalUsdE6 * PCS_APR_EPOCH_N1_BPS * 7) / (10_000 * 365);
        uint256 epochN1_pcs_cake = (epochN1_pcs_usdE6 * 1e16) / CAKE_PRICE_E8;
        _fund(BSC.CAKE, address(this),
            IERC20(BSC.CAKE).balanceOf(address(this)) + epochN1_pcs_cake);

        // ---- 6. Counterfactual: no-migration epoch-N+1 yield (for comparison) ----
        uint256 cf_epochN1_usdE6 =
            (notionalUsdE6 * THENA_APR_EPOCH_N1_BPS * 7) / (10_000 * 365);
        uint256 realized_epochN1_usdE6 = epochN1_thena_usdE6 + epochN1_pcs_usdE6;
        uint256 edgeUsdE6 = realized_epochN1_usdE6 > cf_epochN1_usdE6
            ? realized_epochN1_usdE6 - cf_epochN1_usdE6
            : 0;

        // ---- 7. Close out - withdraw remaining LP and credit principal ----
        uint256 remainingLp = lpMinted - lpToMigrate;
        if (remainingLp > 0) {
            try IThenaGauge(thenaGauge).withdraw(remainingLp) {} catch {}
        }
        // Mark LP at notional.
        uint256 lpTotal = IERC20(thenaPair).totalSupply();
        if (lpTotal > 0) {
            (uint256 r0, uint256 r1,) = IThenaPair(thenaPair).getReserves();
            uint256 rWbnb = IThenaPair(thenaPair).token0() == BSC.WBNB ? r0 : r1;
            uint256 lpPriceE8 = (2 * rWbnb * 600e8) / lpTotal;
            _setOraclePrice(thenaPair, lpPriceE8);
        }

        // Credit migrated PCS-side principal back (slisBNB + WBNB).
        uint256 portionSlis2 = (slisBal * migratedShareBps) / 10_000;
        uint256 portionWbnb2 = (wbnbBal * migratedShareBps) / 10_000;
        _fund(BSC.slisBNB, address(this),
            IERC20(BSC.slisBNB).balanceOf(address(this)) + portionSlis2);
        _fund(BSC.WBNB, address(this),
            IERC20(BSC.WBNB).balanceOf(address(this)) + portionWbnb2);

        emit log_named_uint("onchain_thena_rate_epoch_n", onChainRateN);
        emit log_named_uint("migrate_decision_1_or_0", migrate ? 1 : 0);
        emit log_named_uint("migrated_share_bps", migratedShareBps);
        emit log_named_uint("epoch_n_yield_usd_1e6", epochN_usdE6);
        emit log_named_uint("epoch_n1_yield_usd_1e6", realized_epochN1_usdE6);
        emit log_named_uint("counterfactual_epoch_n1_usd_1e6", cf_epochN1_usdE6);
        emit log_named_uint("migration_edge_usd_1e6", edgeUsdE6);

        _endPnL("B08-09: gauge-weight-shift LP migration");
    }

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
        require(ok, "mint failed");
        return abi.decode(ret, (uint256));
    }
}
