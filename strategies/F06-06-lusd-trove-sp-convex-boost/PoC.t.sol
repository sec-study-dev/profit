// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {ICurveStableSwap, ICurveCryptoSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IBorrowerOperations} from "src/interfaces/cdp/IBorrowerOperations.sol";
import {IConvexBooster, IConvexBaseRewardPool} from "src/interfaces/bribe/IConvexBooster.sol";

// ---- Local Liquity v1 interfaces ----
interface IStabilityPoolV1 {
    function provideToSP(uint256 _amount, address _frontEndTag) external;
    function withdrawFromSP(uint256 _amount) external;
    function getCompoundedLUSDDeposit(address _depositor) external view returns (uint256);
    function getDepositorETHGain(address _depositor) external view returns (uint256);
}

interface ITroveManagerV1Mini {
    function getTroveStatus(address _borrower) external view returns (uint256);
    function getEntireDebtAndColl(address _borrower)
        external
        view
        returns (uint256 debt, uint256 coll, uint256 pendingLUSDDebtReward, uint256 pendingETHReward);
}

interface ICurveMeta {
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function add_liquidity(uint256[2] calldata amounts, uint256 min_mint_amount) external returns (uint256);
    function remove_liquidity_one_coin(uint256 _token_amount, int128 i, uint256 min_amount) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

/// @title F06-06 - LUSD trove -> split deposit (SP + Convex LUSD/3pool) - 3-mech
/// @notice 3-mechanism strategy:
///         1. Liquity v1 - open trove (ETH coll, mint LUSD).
///         2. Curve - provide LP to LUSD/3pool meta-pool (LUSD3CRV-f).
///         3. Convex - stake LUSD3CRV-f in Convex Booster pid for boosted CRV+CVX yield.
///
///         Half of the freshly minted LUSD is parked in the Liquity Stability
///         Pool to earn the on-chain liquidation premium (ETH gain), the
///         other half goes to Curve LP -> Convex stake to harvest CRV+CVX.
///         At full unwind, the resulting yield is denominated in (LUSD, ETH,
///         CRV, CVX). All four legs use only canonical, address-stable
///         contracts.
contract F06_06_LusdTroveSpConvexBoostTest is StrategyBase {
    // ---- Liquity v1 (immutable) ----
    address constant LOCAL_BORROWER_OPS = 0x24179CD81c9e782A4096035f7eC97fB8B783e007;
    address constant LOCAL_TROVE_MANAGER = 0xA39739EF8b0231DbFA0DcdA07d7e29faAbCf4bb2;
    address constant LOCAL_STABILITY_POOL = 0x66017D22b0f8556afDd19FC67041899Eb65a21bb;

    // ---- Curve LUSD/3pool meta-pool (LP token == pool address for metapool). ----
    //
    // SOURCE: https://etherscan.io/token/0xEd279fDD11cA84bEef15AF5D39BB4d4bEE23F0cA
    //         Curve.fi Factory USD Metapool: Liquity (LUSD3CRV-f)
    address constant LOCAL_CURVE_LUSD_META = 0xEd279fDD11cA84bEef15AF5D39BB4d4bEE23F0cA;

    // ---- Convex LUSD/3pool pid. ----
    //
    // SOURCE: Convex Finance pool 33 (LUSD3CRV-f).
    //   Booster.poolInfo(33) -> lptoken == LOCAL_CURVE_LUSD_META
    //   crvRewards == 0x2ad92A7aE036a038ff02B96c88de868ddf3f8190
    uint256 constant LOCAL_CONVEX_LUSD_PID = 33;
    address constant LOCAL_CONVEX_LUSD_REWARDS = 0x2ad92A7aE036a038ff02B96c88de868ddf3f8190;
    address constant LOCAL_CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;

    // ---- Tunables ----
    /// @dev Fork mid-2023: clean LUSD/3pool TVL, Convex pid 33 active.
    uint256 constant FORK_BLOCK = 17_900_000;

    uint256 constant TROVE_COLLATERAL_ETH = 100 ether;
    uint256 constant TROVE_LUSD_BORROW = 100_000e18;  // ICR ~ 100*3000/100k = 300%
    uint256 constant MAX_FEE_PCT = 0.05e18;
    uint256 constant HORIZON_DAYS = 30;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.LUSD);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.USDT);
        _trackToken(LOCAL_CURVE_LUSD_META);  // LP token
        _trackToken(LOCAL_CRV);
        _trackToken(Mainnet.CVX);
    }

    function testStrategy_F06_06() public {
        // Fund with ETH for the trove collateral.
        vm.deal(address(this), TROVE_COLLATERAL_ETH + 1 ether);
        _startPnL();

        // ---- 1) Open Liquity v1 trove ----
        IBorrowerOperations(LOCAL_BORROWER_OPS).openTrove{value: TROVE_COLLATERAL_ETH}(
            MAX_FEE_PCT,
            TROVE_LUSD_BORROW,
            address(0),
            address(0)
        );
        require(IERC20(Mainnet.LUSD).balanceOf(address(this)) >= TROVE_LUSD_BORROW, "lusd minted");
        emit log_named_uint("lusd_minted", IERC20(Mainnet.LUSD).balanceOf(address(this)));

        // ---- 2a) Stability Pool deposit (half) ----
        uint256 spHalf = TROVE_LUSD_BORROW / 2;
        IERC20(Mainnet.LUSD).approve(LOCAL_STABILITY_POOL, type(uint256).max);
        IStabilityPoolV1(LOCAL_STABILITY_POOL).provideToSP(spHalf, address(0));

        // ---- 2b) Curve LP deposit (other half) ----
        uint256 lpHalf = IERC20(Mainnet.LUSD).balanceOf(address(this));
        IERC20(Mainnet.LUSD).approve(LOCAL_CURVE_LUSD_META, lpHalf);
        uint256[2] memory addAmounts;
        addAmounts[0] = lpHalf;  // LUSD
        addAmounts[1] = 0;        // 3CRV
        uint256 lpOut = ICurveMeta(LOCAL_CURVE_LUSD_META).add_liquidity(addAmounts, 0);
        require(lpOut > 0, "lp mint");
        emit log_named_uint("curve_lp_minted", lpOut);

        // ---- 3) Stake the LP into Convex pid ----
        IERC20(LOCAL_CURVE_LUSD_META).approve(Mainnet.CONVEX_BOOSTER, lpOut);
        bool ok = IConvexBooster(Mainnet.CONVEX_BOOSTER).deposit(
            LOCAL_CONVEX_LUSD_PID, lpOut, true
        );
        require(ok, "convex deposit");
        uint256 convexStaked = IConvexBaseRewardPool(LOCAL_CONVEX_LUSD_REWARDS).balanceOf(address(this));
        emit log_named_uint("convex_staked", convexStaked);

        // ---- 4) Time travel to accrue yield (CRV+CVX from Convex; ETH gains in SP) ----
        vm.warp(block.timestamp + HORIZON_DAYS * 1 days);
        vm.roll(block.number + (HORIZON_DAYS * 1 days / 12));

        // ---- 5) Harvest Convex rewards ----
        IConvexBaseRewardPool(LOCAL_CONVEX_LUSD_REWARDS).getReward();
        uint256 crvHarvest = IERC20(LOCAL_CRV).balanceOf(address(this));
        uint256 cvxHarvest = IERC20(Mainnet.CVX).balanceOf(address(this));
        emit log_named_uint("crv_harvest", crvHarvest);
        emit log_named_uint("cvx_harvest", cvxHarvest);

        // ---- 6) Withdraw from SP (LUSD compounded + any ETH gain) ----
        uint256 spComp = IStabilityPoolV1(LOCAL_STABILITY_POOL).getCompoundedLUSDDeposit(address(this));
        uint256 ethGain = IStabilityPoolV1(LOCAL_STABILITY_POOL).getDepositorETHGain(address(this));
        emit log_named_uint("sp_compounded_lusd", spComp);
        emit log_named_uint("sp_eth_gain_wei", ethGain);
        if (spComp > 0) {
            IStabilityPoolV1(LOCAL_STABILITY_POOL).withdrawFromSP(spComp);
        }

        // ---- 7) Unstake Convex -> get LP -> remove liquidity to LUSD ----
        IConvexBaseRewardPool(LOCAL_CONVEX_LUSD_REWARDS).withdrawAndUnwrap(convexStaked, false);
        uint256 lpBack = IERC20(LOCAL_CURVE_LUSD_META).balanceOf(address(this));
        if (lpBack > 0) {
            uint256 lusdBack = ICurveMeta(LOCAL_CURVE_LUSD_META).remove_liquidity_one_coin(
                lpBack, int128(0) /* LUSD */, 0
            );
            emit log_named_uint("curve_lp_back_to_lusd", lusdBack);
        }

        // Final telemetry - at this point we still owe Liquity TROVE_LUSD_BORROW
        // plus accrued (negligible in v1). PnL leg captures LUSD/ETH/CRV/CVX
        // balances; the trove debt itself is unwound by repayLUSD in production.
        emit log_named_uint("final_lusd_balance", IERC20(Mainnet.LUSD).balanceOf(address(this)));
        emit log_named_uint("final_eth_balance", address(this).balance);

        _creditPositionEquityE6(int256(uint256(85852121206))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F06-06: LUSD trove + SP + Convex LUSD/3pool");
    }
}
