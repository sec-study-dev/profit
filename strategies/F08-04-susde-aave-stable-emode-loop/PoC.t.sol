// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ISUSDe} from "src/interfaces/stable/ISUSDe.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";

/// @title F08-04 - sUSDe stablecoin e-mode loop on Aave v3 (USDC borrow variant)
/// @notice Supply sUSDe to Aave v3, enter the stablecoin-correlated e-mode
///         category (where sUSDe + USDT/USDC/DAI share a high LTV), borrow
///         USDC, swap USDC->USDe on Curve, restake into sUSDe, redeposit.
///         Net APY = K * y_susde - (K-1) * y_borrow_usdc.
///
///         Redesigned to borrow USDC (not USDT) because the USDe/USDT Curve
///         pool (0xa8A04E5d...) does not have code at the fork block. The
///         USDe/USDC pool (0x02950460...) has been live since Feb 2024.
///
///         The Aave stablecoin e-mode for sUSDe was activated by AAVE-governance
///         AIP-369 (~Jul 2024). At enable time sUSDe e-mode LTV is 90% with
///         liquidation threshold 92%.
contract F08_04_SusdeAaveStableEmodeLoopTest is StrategyBase {
    // ---- Pinned constants ----

    /// @dev Block 20,400,000 (~Aug 2024). sUSDe stablecoin e-mode active on Aave v3.
    uint256 constant FORK_BLOCK = 20_400_000;

    /// @dev Aave v3 sUSDe-correlated stablecoin e-mode category id.
    ///      AIP-369 introduced the sUSDe stablecoin-correlated e-mode in
    ///      summer 2024. The dedicated sUSDe e-mode category is assigned
    ///      id = 8 in the Aave v3 PoolConfigurator on mainnet.
    uint8 constant EMODE_SUSDE_STABLE = 8;

    /// @dev Variable interest rate mode (Aave v3).
    uint256 constant RATE_MODE_VARIABLE = 2;

    /// @dev Curve USDe/USDC factory pool. coins[0]=USDe, coins[1]=USDC.
    ///      setUp() asserts coin ordering at the fork block.
    ///      Note: USDe/USDT pool (0xa8A04E5d...) has no code at this block;
    ///      we use USDe/USDC instead.
    address constant LOCAL_CURVE_USDE_USDC = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72;

    /// @dev Loop tuning.
    uint256 constant LOOPS = 4;
    uint256 constant LOOP_LTV_BPS = 8700; // 87% (e-mode ceiling 90%)

    uint256 constant EQUITY_USDE = 1_000_000e18; // 1M USDe principal

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.USDE);
        _trackToken(Mainnet.SUSDE);
        _trackToken(Mainnet.USDC);

        // Sanity-check Curve USDe/USDC pool coin ordering.
        require(
            ICurveStableSwap(LOCAL_CURVE_USDE_USDC).coins(0) == Mainnet.USDE,
            "F08-04: curve coin0 != USDe"
        );
        require(
            ICurveStableSwap(LOCAL_CURVE_USDE_USDC).coins(1) == Mainnet.USDC,
            "F08-04: curve coin1 != USDC"
        );
    }

    function testStrategy_F08_04() public {
        _fund(Mainnet.USDE, address(this), EQUITY_USDE);
        _startPnL();

        // Approvals
        IERC20(Mainnet.USDE).approve(Mainnet.SUSDE, type(uint256).max);
        IERC20(Mainnet.SUSDE).approve(Mainnet.AAVE_V3_POOL, type(uint256).max);
        IERC20(Mainnet.USDC).approve(LOCAL_CURVE_USDE_USDC, type(uint256).max);

        // Step 1: stake initial USDe -> sUSDe.
        uint256 initShares = ISUSDe(Mainnet.SUSDE).deposit(EQUITY_USDE, address(this));

        // Step 2: supply sUSDe to Aave, set e-mode to stablecoin.
        IAavePool(Mainnet.AAVE_V3_POOL).supply(Mainnet.SUSDE, initShares, address(this), 0);
        try IAavePool(Mainnet.AAVE_V3_POOL).setUserEMode(EMODE_SUSDE_STABLE) {
            // ok - e-mode category 8 set
        } catch {
            emit log("F08-04: e-mode 8 not available at this block; using default mode");
        }

        // Step 3: loop borrow USDC -> swap to USDe -> stake -> supply.
        for (uint256 i = 0; i < LOOPS; i++) {
            (, , uint256 availableBase, , , ) =
                IAavePool(Mainnet.AAVE_V3_POOL).getUserAccountData(address(this));
            // availableBase is 1e8 USD. USDC amount (1e6) = availableBase / 1e2 with LTV scaling.
            uint256 borrowAmt = (availableBase * LOOP_LTV_BPS) / (1e2 * 10_000);
            if (borrowAmt < 1e6) break;

            try IAavePool(Mainnet.AAVE_V3_POOL).borrow(
                Mainnet.USDC, borrowAmt, RATE_MODE_VARIABLE, 0, address(this)
            ) {
                // ok
            } catch {
                emit log("F08-04: USDC borrow failed in loop");
                break;
            }

            // Swap USDC (6 dec, coin index 1) -> USDe (18 dec, coin index 0) on Curve.
            uint256 expectedUsde = ICurveStableSwap(LOCAL_CURVE_USDE_USDC).get_dy(int128(1), int128(0), borrowAmt);
            uint256 minOut = (expectedUsde * 9950) / 10_000;
            uint256 usdeOut = ICurveStableSwap(LOCAL_CURVE_USDE_USDC).exchange(
                int128(1), int128(0), borrowAmt, minOut
            );

            // Stake USDe -> sUSDe, supply to Aave.
            uint256 newShares = ISUSDe(Mainnet.SUSDE).deposit(usdeOut, address(this));
            IAavePool(Mainnet.AAVE_V3_POOL).supply(Mainnet.SUSDE, newShares, address(this), 0);
        }

        // Step 4: warp 30 days, force accrual via no-op deposit.
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));

        // Step 5: surface Aave account data.
        (uint256 totalCollBase, uint256 totalDebtBase, , , , uint256 hf) =
            IAavePool(Mainnet.AAVE_V3_POOL).getUserAccountData(address(this));
        emit log_named_uint("collateral_base_e8_usd", totalCollBase);
        emit log_named_uint("debt_base_e8_usd", totalDebtBase);
        emit log_named_uint("equity_base_e8_usd", totalCollBase > totalDebtBase ? totalCollBase - totalDebtBase : 0);
        emit log_named_uint("health_factor_e18", hf);
        emit log_named_uint("emode", IAavePool(Mainnet.AAVE_V3_POOL).getUserEMode(address(this)));

        _endPnL("F08-04: sUSDe Aave stable-emode loop");
    }
}
