// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ISUSDe} from "src/interfaces/stable/ISUSDe.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";

/// @title F08-04 - sUSDe stablecoin e-mode loop on Aave v3
/// @notice Supply sUSDe to Aave v3, enter the stablecoin-correlated e-mode
///         category (where sUSDe + USDT/USDC/DAI share a high LTV), borrow
///         USDC, swap USDC->USDe on Curve, restake into sUSDe, redeposit.
///         Net APY = K * y_susde - (K-1) * y_borrow_usdc.
///
///         The Aave stablecoin e-mode for sUSDe was activated by AAVE-governance
///         AIP-369 (~Jul 2024). At enable time sUSDe e-mode LTV is 90% with
///         liquidation threshold 92%. Borrowed asset is USDC (routed via the
///         on-chain USDe/USDC Curve pool; the USDe/USDT pool does not exist at
///         this fork block).
contract F08_04_SusdeAaveStableEmodeLoopTest is StrategyBase {
    // ---- Pinned constants ----

    /// @dev Block 21,300,000 (~Dec 2024). sUSDe stablecoin e-mode (id=2) active
    ///      on Aave v3; the Morpho sUSDe/USDC 91.5% market is also live.
    ///      Block 20,400,000 was too early - the sUSDe e-mode only activated
    ///      between blocks 21,200,000 and 21,250,000.
    uint256 constant FORK_BLOCK = 21_300_000;

    /// @dev Aave v3 sUSDe-correlated stablecoin e-mode category id.
    ///      Category 2 = "sUSDe Stablecoins" (LTV 90%, LT 92%) on Aave v3
    ///      mainnet; confirmed live from block ~21,240,000 onward.
    uint8 constant EMODE_SUSDE_STABLE = 2;

    /// @dev Variable interest rate mode (Aave v3).
    uint256 constant RATE_MODE_VARIABLE = 2;

    /// @dev Curve USDe/USDC factory pool. coins[0]=USDe, coins[1]=USDC.
    ///      The USDe/USDT pool (0xa8A04E5d...) does not exist at any fork block
    ///      tested. We use the USDe/USDC pool instead (same peg, same mechanics).
    ///      setUp() asserts coin ordering at the fork block.
    address constant LOCAL_CURVE_USDE_USDC = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72;

    /// @dev Loop tuning.
    uint256 constant LOOPS = 4;
    uint256 constant LOOP_LTV_BPS = 8700; // 87% (e-mode ceiling 90%)

    uint256 constant EQUITY_USDE = 1_000_000e18; // 1M USDe principal

    /// @dev Aave v3 PoolConfigurator - can setSupplyCap (requires POOL_ADMIN role).
    address constant LOCAL_AAVE_CONFIGURATOR = 0x64b761D848206f447Fe2dd461b0c635Ec39EbB27;
    /// @dev Aave v3 Pool admin (holds POOL_ADMIN role in ACL) at fork block.
    address constant LOCAL_AAVE_POOL_ADMIN = 0x5300A1a15135EA4dc7aD5a167152C01EFc9b192A;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.USDE);
        _trackToken(Mainnet.SUSDE);
        _trackToken(Mainnet.USDC);

        // The sUSDe supply cap on Aave is perpetually filled by real users.
        // Raise the supply cap via PoolConfigurator to allow our test deposit.
        // This is a fork-only helper - production cannot bypass the cap.
        vm.prank(LOCAL_AAVE_POOL_ADMIN);
        (bool ok,) = LOCAL_AAVE_CONFIGURATOR.call(
            abi.encodeWithSignature(
                "setSupplyCap(address,uint256)",
                Mainnet.SUSDE,
                uint256(2_000_000_000) // 2 billion sUSDe cap (10x current max)
            )
        );
        require(ok, "F08-04: setSupplyCap failed");

        // Sanity-check Curve pool coin ordering.
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
        // USDC approve for Curve repurchase leg.
        IERC20(Mainnet.USDC).approve(LOCAL_CURVE_USDE_USDC, type(uint256).max);

        // Step 1: stake initial USDe -> sUSDe.
        uint256 initShares = ISUSDe(Mainnet.SUSDE).deposit(EQUITY_USDE, address(this));

        // Step 2: supply sUSDe to Aave, set e-mode to stablecoin.
        IAavePool(Mainnet.AAVE_V3_POOL).supply(Mainnet.SUSDE, initShares, address(this), 0);
        IAavePool(Mainnet.AAVE_V3_POOL).setUserEMode(EMODE_SUSDE_STABLE);

        // Step 3: loop borrow USDC -> swap to USDe -> stake -> supply.
        for (uint256 i = 0; i < LOOPS; i++) {
            (, , uint256 availableBase, , , ) =
                IAavePool(Mainnet.AAVE_V3_POOL).getUserAccountData(address(this));
            // availableBase is 1e8 USD. USDC amount (1e6) = availableBase / 1e2 with LTV scaling.
            uint256 borrowAmt = (availableBase * LOOP_LTV_BPS) / (1e2 * 10_000);
            if (borrowAmt < 1e6) break;

            IAavePool(Mainnet.AAVE_V3_POOL).borrow(
                Mainnet.USDC, borrowAmt, RATE_MODE_VARIABLE, 0, address(this)
            );

            // Swap USDC (6 dec, coin index 1) -> USDe (18 dec, coin index 0) on Curve USDe/USDC.
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
        // Tiny no-op supply to crystallise indices.
        _fund(Mainnet.SUSDE, address(this), 1);
        deal(Mainnet.SUSDE, address(this), 1);
        IAavePool(Mainnet.AAVE_V3_POOL).supply(Mainnet.SUSDE, 1, address(this), 0);

        // Step 5: surface Aave account data.
        (uint256 totalCollBase, uint256 totalDebtBase, , , , uint256 hf) =
            IAavePool(Mainnet.AAVE_V3_POOL).getUserAccountData(address(this));
        emit log_named_uint("collateral_base_e8_usd", totalCollBase);
        emit log_named_uint("debt_base_e8_usd", totalDebtBase);
        emit log_named_uint("equity_base_e8_usd", totalCollBase - totalDebtBase);
        emit log_named_uint("health_factor_e18", hf);
        emit log_named_uint("emode", IAavePool(Mainnet.AAVE_V3_POOL).getUserEMode(address(this)));

        _endPnL("F08-04: sUSDe Aave stable-emode loop");
    }
}
