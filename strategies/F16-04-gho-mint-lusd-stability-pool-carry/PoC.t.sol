// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";

// ---- Local interfaces (do NOT modify shared) ----

/// @dev Aave V3 Pool subset.
interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf
    ) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function repay(address asset, uint256 amount, uint256 rateMode, address onBehalfOf) external returns (uint256);
    function getReserveData(address asset)
        external
        view
        returns (
            uint256 configuration,
            uint128 liquidityIndex,
            uint128 currentLiquidityRate,
            uint128 variableBorrowIndex,
            uint128 currentVariableBorrowRate,
            uint128 currentStableBorrowRate,
            uint40 lastUpdateTimestamp,
            uint16 id,
            address aTokenAddress,
            address stableDebtTokenAddress,
            address variableDebtTokenAddress,
            address interestRateStrategyAddress,
            uint128 accruedToTreasury,
            uint128 unbacked,
            uint128 isolationModeTotalDebt
        );
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

/// @dev Curve meta-pool exchange_underlying interface.
interface ICurveMeta {
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 min_dy)
        external returns (uint256);
    function get_dy_underlying(int128 i, int128 j, uint256 dx) external view returns (uint256);
}

/// @dev Liquity v1 Stability Pool subset.
interface IStabilityPool {
    function provideToSP(uint256 _amount, address _frontEndTag) external;
    function withdrawFromSP(uint256 _amount) external;
    function getCompoundedLUSDDeposit(address _depositor) external view returns (uint256);
    function getDepositorETHGain(address _depositor) external view returns (uint256);
    function getDepositorLQTYGain(address _depositor) external view returns (uint256);
    function getTotalLUSDDeposits() external view returns (uint256);
}

/// @title F16-04 - GHO mint -> LUSD Stability Pool carry
contract F16_04_GhoMintLusdStabilityPoolCarry is StrategyBase {
    // ---- Aave V3 ----
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    // ---- Liquity v1 Stability Pool ----
    address constant LIQUITY_SP = 0x66017D22b0f8556afDd19FC67041899Eb65a21bb;
    /// @dev LQTY token.
    address constant LQTY = 0x6DEA81C8171D0bA574754EF6F8b412F2Ed88c54D;

    // ---- Curve pools ----
    /// @dev Curve GHO/crvUSD 2-coin StableNG pool. Verified via Curve gov
    ///      `[crvUSD]: GHO Pegkeeper Review` (gov.curve.finance/t/.../11003).
    ///      Pool index ordering: 0=GHO, 1=crvUSD.
    address constant CURVE_GHO_CRVUSD = 0x635EF0056A597D13863B73825CcA297236578595;
    /// @dev Curve crvUSD/USDC StableNG. Used to bridge GHO -> crvUSD -> USDC.
    ///      Verified on-chain: coins[0]=USDC (0xA0b...), coins[1]=crvUSD (0xf939...).
    ///      Index ordering: 0=USDC, 1=crvUSD.
    address constant CURVE_CRVUSD_USDC = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
    /// @dev Curve LUSD/3pool meta-pool (underlying coins [LUSD, DAI, USDC, USDT]).
    address constant CURVE_LUSD_3POOL = 0xEd279fDD11cA84bEef15AF5D39BB4d4bEE23F0cA;

    // ---- Tunables ----
    uint256 constant FORK_BLOCK = 20_500_000;
    uint256 constant USDC_PRINCIPAL = 200_000e6;
    uint256 constant GHO_BORROW = 100_000e18;
    uint256 constant HORIZON = 365 days;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.GHO);
        _trackToken(Mainnet.CRVUSD);
        _trackToken(Mainnet.LUSD);
        _trackToken(LQTY);
        _setEthUsdFallback(2_400e8);
    }

    function testStrategy_F16_04() public {
        _fund(Mainnet.USDC, address(this), USDC_PRINCIPAL);

        _startPnL();
        vm.txGasPrice(20 gwei);

        // ---- 1) Supply USDC to Aave V3 ----
        IERC20(Mainnet.USDC).approve(AAVE_POOL, USDC_PRINCIPAL);
        IAaveV3Pool(AAVE_POOL).supply(Mainnet.USDC, USDC_PRINCIPAL, address(this), 0);

        // ---- 2) Borrow GHO at variable rate (mode = 2) ----
        try IAaveV3Pool(AAVE_POOL).borrow(Mainnet.GHO, GHO_BORROW, 2, 0, address(this)) {
            // ok
        } catch (bytes memory r) {
            emit log("GHO borrow reverted; aborting");
            emit log_bytes(r);
            _endPnL("F16-04-gho-mint-lusd-stability-pool-carry");
            return;
        }
        uint256 ghoBal = IERC20(Mainnet.GHO).balanceOf(address(this));
        emit log_named_uint("gho_borrowed", ghoBal);
        require(ghoBal >= GHO_BORROW, "GHO borrow shortfall");

        // ---- 3) Swap GHO -> crvUSD -> USDC ----
        //   The deployed cross-CDP venue is the GHO/crvUSD StableNG pool
        //   (no GHO/3CRV metapool exists with non-trivial depth), so we
        //   bridge via crvUSD/USDC NG.
        IERC20(Mainnet.GHO).approve(CURVE_GHO_CRVUSD, ghoBal);
        uint256 crvUsdMid;
        try ICurveStableSwap(CURVE_GHO_CRVUSD).exchange(int128(0), int128(1), ghoBal, 0)
            returns (uint256 o)
        {
            crvUsdMid = o;
        } catch {
            emit log("GHO/crvUSD swap failed; pool inactive at this block");
            _endPnL("F16-04-gho-mint-lusd-stability-pool-carry");
            return;
        }
        emit log_named_uint("crvusd_intermediate", crvUsdMid);

        // Swap crvUSD -> USDC: coins[0]=USDC, coins[1]=crvUSD, so sell idx 1 for idx 0.
        IERC20(Mainnet.CRVUSD).approve(CURVE_CRVUSD_USDC, crvUsdMid);
        uint256 usdcMid = ICurveStableSwap(CURVE_CRVUSD_USDC).exchange(
            int128(1), int128(0), crvUsdMid, 0
        );
        emit log_named_uint("usdc_intermediate", usdcMid);

        // ---- 4) Swap USDC -> LUSD via LUSD/3pool meta (underlying 2->0) ----
        IERC20(Mainnet.USDC).approve(CURVE_LUSD_3POOL, usdcMid);
        uint256 lusdOut = ICurveMeta(CURVE_LUSD_3POOL).exchange_underlying(2, 0, usdcMid, 0);
        emit log_named_uint("lusd_received", lusdOut);
        require(lusdOut > 0, "LUSD swap empty");

        // ---- 5) Provide LUSD to Liquity Stability Pool ----
        IERC20(Mainnet.LUSD).approve(LIQUITY_SP, lusdOut);
        IStabilityPool(LIQUITY_SP).provideToSP(lusdOut, address(0));

        // Snapshot SP state.
        uint256 spLusdStart = IStabilityPool(LIQUITY_SP).getCompoundedLUSDDeposit(address(this));
        emit log_named_uint("sp_lusd_deposited", spLusdStart);

        // ---- 6) Warp 30 days ----
        vm.warp(block.timestamp + HORIZON);

        // Read accrued gains BEFORE touching SP.
        uint256 ethGainPending = IStabilityPool(LIQUITY_SP).getDepositorETHGain(address(this));
        uint256 lqtyGainPending = IStabilityPool(LIQUITY_SP).getDepositorLQTYGain(address(this));
        emit log_named_uint("eth_gain_pending_wei", ethGainPending);
        emit log_named_uint("lqty_gain_pending", lqtyGainPending);

        // ---- 7) Touch SP with withdrawFromSP(0) to crystallise LQTY+ETH ----
        IStabilityPool(LIQUITY_SP).withdrawFromSP(0);
        uint256 lqtyBal = IERC20(LQTY).balanceOf(address(this));
        uint256 ethBal = address(this).balance;
        emit log_named_uint("lqty_received", lqtyBal);
        emit log_named_uint("eth_received_wei", ethBal);

        // ---- 8) Read remaining SP deposit + GHO debt accrued ----
        uint256 spLusdEnd = IStabilityPool(LIQUITY_SP).getCompoundedLUSDDeposit(address(this));
        emit log_named_uint("sp_lusd_after_30d", spLusdEnd);

        (uint256 totalCollBase, uint256 totalDebtBase, , , ,) = IAaveV3Pool(AAVE_POOL).getUserAccountData(address(this));
        emit log_named_uint("aave_user_total_coll_base", totalCollBase);
        emit log_named_uint("aave_user_total_debt_base", totalDebtBase);

        // A1: Credit the open position equity.
        // (a) Aave position: USDC collateral - GHO debt (both in 1e8 USD base).
        {
            int256 aaveEquityE8 = int256(totalCollBase) - int256(totalDebtBase);
            _creditPositionEquityE8(aaveEquityE8);
            emit log_named_int("A1_aave_equity_e8", aaveEquityE8);
        }
        // (b) Liquity SP: remaining LUSD deposit value (LUSD ~ $1, 1e18 dec -> 1e6 USD).
        {
            int256 spEquityE6 = int256(spLusdEnd / 1e12);
            _creditPositionEquityE6(spEquityE6);
            emit log_named_int("A1_sp_lusd_equity_e6", spEquityE6);
        }
        // (c) ETH gained from SP liquidations (already in address(this).balance, tracked via ETH).
        // ETH is tracked in pnl_usd via the ETH delta in _endPnL, so no separate credit needed.

        _endPnL("F16-04-gho-mint-lusd-stability-pool-carry");

        // Soft success: SP deposit must still be > 0 (not entirely wiped).
        assertGt(spLusdEnd, 0, "SP wiped");
    }
}
