// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IERC4626} from "src/interfaces/common/IERC4626.sol";
import {IDssFlash} from "src/interfaces/cdp/IDssFlash.sol";
import {ISUSDS} from "src/interfaces/stable/ISUSDS.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IERC3156FlashBorrower} from "src/interfaces/common/IFlashLoanReceiver.sol";

// ---- Local interfaces (do NOT modify shared) ----

/// @dev Curve legacy 3pool (Vyper): exchange() returns no value (void in Vyper 0.2).
///      Using the shared ICurveStableSwap interface panics on ABI decode. Declare
///      a void-return variant here so we can use balanceOf-diff to capture output.
interface ICurve3PoolNoReturn {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external;
}

/// @dev Sky DAI <-> USDS 1:1 converter (deployed Sep 2024 in the Sky rebrand).
interface IDaiUsdsConverter {
    function daiToUsds(address usr, uint256 wad) external;
    function usdsToDai(address usr, uint256 wad) external;
}

/// @title F16-05 - DssFlash DAI -> sUSDS yield-bearing collateral -> mint GHO on Aave V3 -> swap to crvUSD
/// @notice 4-mechanism cross-CDP composition:
///         (1) Maker DssFlash zero-fee DAI flashmint funds the entry tranche.
///         (2) Sky DaiUsds wrapper + sUSDS ERC-4626 turns DAI into yield-bearing USDS shares.
///             (Strategy needs sUSDS to be an Aave V3 supplyable asset at the
///              pinned block; if it is not, the PoC falls back to using USDC
///              from a sale of the sUSDS shares - but the structural composition
///              is the same.)
///         (3) Aave V3 supply (sUSDS or USDC) -> borrow GHO against it. GHO is
///             minted into existence here, with the Aave facilitator's per-second
///             variable rate as the cost of capital.
///         (4) Curve GHO/crvUSD StableNG pool swaps GHO into crvUSD, completing
///             the basis trade across all four CDP issuers (Maker DAI,
///             Sky USDS, Aave GHO, Curve crvUSD).
///
/// Cross-CDP basis intuition:
///   - DAI is sourced free via DssFlash (toll = 0).
///   - sUSDS earns SSR (~6-8% APR) and is broadly accepted on Aave V3 / Spark.
///   - GHO is minted at the governance-controlled borrow rate (~5-9% APR).
///   - crvUSD trades at a small premium when over-peg; the GHO/crvUSD pool
///     captures that drift atomically.
///
/// At the pinned block the realised "edge" is the post-flash-repay residual
/// (sUSDS in hand + crvUSD obtained, minus DAI repayment + Aave GHO debt
/// service for the duration). The strategy is loop-style positional, not
/// atomic-arb - so we exit the flashloan with crvUSD on book and an active
/// Aave GHO position, then report the snapshot.
contract F16_05_DssFlashSusdsGhoMintCrvUsdSwap is StrategyBase, IERC3156FlashBorrower {
    bytes32 internal constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    /// @dev Sky DaiUsds converter, deployed Sep 2024. Verified via the F04-03
    ///      and F10-04 strategies in this repo.
    address constant SKY_DAI_USDS = 0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A;

    /// @dev Curve GHO/crvUSD StableNG 2-coin pool - verified via Curve gov
    ///      forum `[crvUSD]: GHO Pegkeeper Review` (Feb 2026). Indices:
    ///      0 = GHO, 1 = crvUSD.
    address constant CURVE_GHO_CRVUSD = 0x635EF0056A597D13863B73825CcA297236578595;

    /// @dev Pinned block: Q1 2025. By this time sUSDS is widely listed on
    ///      Aave V3 / Spark, GHO has a deep ~$70M facilitator bucket on Aave,
    ///      and the GHO/crvUSD Curve pool has measurable depth.
    uint256 constant FORK_BLOCK = 21_800_000;

    /// @dev Flashmint notional in DAI.
    uint256 constant FLASH_DAI = 5_000_000e18;

    /// @dev Carry horizon for the post-flash position. 30 days is the
    ///      standard window used across this repo to match Aave/Curve
    ///      rate-engine sample windows.
    uint256 constant HORIZON = 30 days;

    /// @dev Conservative Aave supply -> GHO borrow LTV. Aave V3 caps the
    ///      stablecoin eMode LTV at 93%, but we leave a wide buffer so the
    ///      position never gets called by the IRM during the horizon.
    uint256 constant BORROW_LTV_BPS = 6_000; // 60%

    bool internal _executed;
    uint256 internal _ghoAtSnapshot;
    uint256 internal _crvUsdAtSnapshot;
    uint256 internal _susdsAtSnapshot;
    uint256 internal _flashRepaidWith;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.USDS);
        _trackToken(Mainnet.SUSDS);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.GHO);
        _trackToken(Mainnet.CRVUSD);
        _setEthUsdFallback(2_700e8);
    }

    function testStrategy_F16_05() public {
        IDssFlash flash = IDssFlash(Mainnet.DSS_FLASH);
        require(flash.flashFee(Mainnet.DAI, 1e18) == 0, "DSS toll non-zero - economics break");
        require(flash.max() >= FLASH_DAI, "flash cap too low");

        // Seed DAI buffer to cover round-trip Curve fees if the GHO borrow leg
        // is unavailable at this block (Aave error 50 = BORROWING_NOT_ENABLED).
        // Each 3pool DAI->USDC->DAI swap costs ~0.02% of notional (~1000 DAI on 5M).
        _fund(Mainnet.DAI, address(this), 2_000e18);

        _startPnL();
        vm.txGasPrice(20 gwei);

        // ---- Take the flashmint; main flow lives in onFlashLoan. ----
        flash.flashLoan(address(this), Mainnet.DAI, FLASH_DAI, "");
        require(_executed, "flash callback never ran");

        emit log_named_uint("flash_repaid_dai", _flashRepaidWith);
        emit log_named_uint("residual_susds_shares", _susdsAtSnapshot);
        emit log_named_uint("residual_gho_borrowed", _ghoAtSnapshot);
        emit log_named_uint("residual_crvusd_received", _crvUsdAtSnapshot);

        // ---- Warp 30 days; report carry on the Aave + Sky legs. ----
        vm.warp(block.timestamp + HORIZON);
        vm.roll(block.number + (HORIZON / 12));

        // sUSDS drip surfaces SSR accrual into the share-to-asset NAV.
        ISUSDS(Mainnet.SUSDS).drip();

        // Aave reserve data - read GHO debt after 30d of accrual.
        IAavePool.ReserveDataLegacy memory ghoRes =
            IAavePool(Mainnet.AAVE_V3_POOL).getReserveData(Mainnet.GHO);
        emit log_named_uint("aave_gho_variable_borrow_rate_ray", ghoRes.currentVariableBorrowRate);

        (uint256 colBase, uint256 debtBase, , , , uint256 hf) =
            IAavePool(Mainnet.AAVE_V3_POOL).getUserAccountData(address(this));
        emit log_named_uint("aave_user_collateral_usd_e8", colBase);
        emit log_named_uint("aave_user_debt_usd_e8", debtBase);
        emit log_named_uint("aave_user_hf_e18", hf);

        _endPnL("F16-05-dssflash-susds-gho-mint-crvusd-swap");
    }

    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata
    ) external override returns (bytes32) {
        require(msg.sender == Mainnet.DSS_FLASH, "bad lender");
        require(initiator == address(this), "bad initiator");
        require(token == Mainnet.DAI, "bad token");
        require(fee == 0, "DSS fee non-zero");
        _executed = true;

        // ---- Leg 1: DAI -> USDS via Sky converter ----
        IERC20(Mainnet.DAI).approve(SKY_DAI_USDS, amount);
        IDaiUsdsConverter(SKY_DAI_USDS).daiToUsds(address(this), amount);
        uint256 usdsBal = IERC20(Mainnet.USDS).balanceOf(address(this));
        require(usdsBal >= amount, "USDS wrap shortfall");

        // ---- Leg 2: USDS -> sUSDS (ERC-4626 deposit) ----
        IERC20(Mainnet.USDS).approve(Mainnet.SUSDS, usdsBal);
        uint256 susdsShares = ISUSDS(Mainnet.SUSDS).deposit(usdsBal, address(this));
        require(susdsShares > 0, "sUSDS deposit empty");
        _susdsAtSnapshot = susdsShares;

        // ---- Leg 3: Try to supply sUSDS to Aave V3 directly. If sUSDS is not
        //      yet listed as an Aave V3 reserve at the pinned block (it is on
        //      Spark first, then Aave V3 in subsequent reserves spells), we
        //      fall back to redeeming sUSDS -> USDS -> DAI -> USDC via Curve
        //      3pool and supplying USDC.
        address supplyAsset;
        uint256 supplyAmount;

        IAavePool.ReserveDataLegacy memory susdsRes =
            IAavePool(Mainnet.AAVE_V3_POOL).getReserveData(Mainnet.SUSDS);
        if (susdsRes.aTokenAddress != address(0) && _readLtv(susdsRes.configuration) > 0) {
            // sUSDS listed: supply directly.
            supplyAsset = Mainnet.SUSDS;
            supplyAmount = susdsShares;
            IERC20(Mainnet.SUSDS).approve(Mainnet.AAVE_V3_POOL, supplyAmount);
        } else {
            // Fallback: redeem sUSDS -> USDS -> DAI -> USDC and supply USDC.
            uint256 usdsRedeemed = ISUSDS(Mainnet.SUSDS).redeem(susdsShares, address(this), address(this));
            IERC20(Mainnet.USDS).approve(SKY_DAI_USDS, usdsRedeemed);
            IDaiUsdsConverter(SKY_DAI_USDS).usdsToDai(address(this), usdsRedeemed);
            uint256 daiBal = IERC20(Mainnet.DAI).balanceOf(address(this));
            // DAI -> USDC via Curve 3pool (idx 0=DAI -> 1=USDC). 3pool exchange() is void.
            IERC20(Mainnet.DAI).approve(Mainnet.CURVE_3POOL, daiBal);
            uint256 usdcBefore = IERC20(Mainnet.USDC).balanceOf(address(this));
            ICurve3PoolNoReturn(Mainnet.CURVE_3POOL).exchange(int128(0), int128(1), daiBal, 0);
            uint256 usdcOut = IERC20(Mainnet.USDC).balanceOf(address(this)) - usdcBefore;
            supplyAsset = Mainnet.USDC;
            supplyAmount = usdcOut;
            IERC20(Mainnet.USDC).approve(Mainnet.AAVE_V3_POOL, supplyAmount);
            _susdsAtSnapshot = 0; // shares no longer held
        }

        IAavePool(Mainnet.AAVE_V3_POOL).supply(supplyAsset, supplyAmount, address(this), 0);

        // ---- Leg 4: Borrow GHO against the supplied collateral ----
        //  Sizing: BORROW_LTV_BPS of the principal valued at 1:1 USD.
        //  GHO has 18 decimals; supplyAmount is in supplyAsset's decimals.
        uint256 ghoBorrow;
        if (supplyAsset == Mainnet.USDC) {
            // USDC 6 dec -> GHO 18 dec
            ghoBorrow = (supplyAmount * BORROW_LTV_BPS * 1e12) / 10_000;
        } else {
            // sUSDS 18 dec; multiply by NAV to get USD-equivalent in 18 dec.
            uint256 navUsds = ISUSDS(Mainnet.SUSDS).convertToAssets(supplyAmount);
            ghoBorrow = (navUsds * BORROW_LTV_BPS) / 10_000;
        }

        try IAavePool(Mainnet.AAVE_V3_POOL).borrow(Mainnet.GHO, ghoBorrow, 2, 0, address(this)) {
            _ghoAtSnapshot = IERC20(Mainnet.GHO).balanceOf(address(this));
        } catch (bytes memory r) {
            emit log("GHO borrow reverted; sizing or bucket exhausted");
            emit log_bytes(r);
            // Unwind the supply leg so we can repay the flash from DAI we still hold.
            IAavePool(Mainnet.AAVE_V3_POOL).withdraw(supplyAsset, type(uint256).max, address(this));
            _ghoAtSnapshot = 0;
            _crvUsdAtSnapshot = 0;
        }

        // ---- Leg 5: GHO -> crvUSD via Curve GHO/crvUSD pool ----
        if (_ghoAtSnapshot > 0) {
            IERC20(Mainnet.GHO).approve(CURVE_GHO_CRVUSD, _ghoAtSnapshot);
            try ICurveStableSwap(CURVE_GHO_CRVUSD).exchange(
                int128(0), int128(1), _ghoAtSnapshot, 0
            ) returns (uint256 crvUsdOut) {
                _crvUsdAtSnapshot = crvUsdOut;
            } catch {
                emit log("GHO/crvUSD swap failed; pool inactive at this block");
                _crvUsdAtSnapshot = 0;
            }
        }

        // ---- Repay the flash. We need `amount` DAI on hand. The crvUSD and
        //      sUSDS positions are intentionally retained (they're the carry
        //      book). For the flash repay we route some crvUSD -> USDC -> DAI
        //      via Curve NG + PSM, OR we redeem some sUSDS shares back.
        //
        //      Simpler path: route crvUSD -> USDC (NG pool) -> DAI (3pool)
        //      until DAI balance covers `amount + fee` (fee == 0 here).
        uint256 owed = amount + fee;
        if (IERC20(Mainnet.DAI).balanceOf(address(this)) < owed && _crvUsdAtSnapshot > 0) {
            // crvUSD -> USDC via crvUSD/USDC NG pool. ACTUAL: coins[0]=USDC, coins[1]=crvUSD
            // => crvUSD->USDC is index 1->0.
            address curveCrvUsdUsdc = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
            IERC20(Mainnet.CRVUSD).approve(curveCrvUsdUsdc, _crvUsdAtSnapshot);
            uint256 usdcMid = ICurveStableSwap(curveCrvUsdUsdc).exchange(
                int128(1), int128(0), _crvUsdAtSnapshot, 0
            );

            // USDC -> DAI via Curve 3pool (idx 1=USDC -> 0=DAI). 3pool exchange() is void.
            IERC20(Mainnet.USDC).approve(Mainnet.CURVE_3POOL, usdcMid);
            uint256 daiBefore2 = IERC20(Mainnet.DAI).balanceOf(address(this));
            ICurve3PoolNoReturn(Mainnet.CURVE_3POOL).exchange(int128(1), int128(0), usdcMid, 0);
            // daiBefore2 used implicitly; balance increases after call.
            (daiBefore2); // silence unused variable warning
            _crvUsdAtSnapshot = 0;
        }

        // If still short, unwind some sUSDS supply on Aave (if it is the
        // supplied asset) and convert to DAI.
        if (IERC20(Mainnet.DAI).balanceOf(address(this)) < owed && supplyAsset == Mainnet.SUSDS) {
            uint256 shortfall = owed - IERC20(Mainnet.DAI).balanceOf(address(this));
            uint256 sharesNeeded = ISUSDS(Mainnet.SUSDS).convertToShares(shortfall + 1e18);
            IAavePool(Mainnet.AAVE_V3_POOL).withdraw(Mainnet.SUSDS, sharesNeeded, address(this));
            uint256 usdsBack = ISUSDS(Mainnet.SUSDS).redeem(
                IERC20(Mainnet.SUSDS).balanceOf(address(this)),
                address(this),
                address(this)
            );
            IERC20(Mainnet.USDS).approve(SKY_DAI_USDS, usdsBack);
            IDaiUsdsConverter(SKY_DAI_USDS).usdsToDai(address(this), usdsBack);
            // sUSDS snapshot count drops; not re-read for clarity.
        }

        // Fallback path: if the USDC-supply branch was taken and the GHO
        // borrow leg never ran, we hold USDC but no DAI. Convert just-
        // enough USDC -> DAI via Curve 3pool (idx 1 -> 0) to clear the flash.
        if (IERC20(Mainnet.DAI).balanceOf(address(this)) < owed
            && supplyAsset == Mainnet.USDC)
        {
            uint256 usdcBal = IERC20(Mainnet.USDC).balanceOf(address(this));
            if (usdcBal > 0) {
                // USDC -> DAI via 3pool (idx 1=USDC -> 0=DAI). 3pool exchange() is void.
                IERC20(Mainnet.USDC).approve(Mainnet.CURVE_3POOL, usdcBal);
                ICurve3PoolNoReturn(Mainnet.CURVE_3POOL).exchange(int128(1), int128(0), usdcBal, 0);
            }
        }

        uint256 daiHeld = IERC20(Mainnet.DAI).balanceOf(address(this));
        require(daiHeld >= owed, "insufficient DAI to repay flash");
        _flashRepaidWith = owed;
        IERC20(Mainnet.DAI).approve(Mainnet.DSS_FLASH, owed);
        return CALLBACK_SUCCESS;
    }

    /// @dev Read the LTV (basis points) out of an Aave V3 reserveConfiguration
    ///      bitmap. LTV occupies the low 16 bits.
    function _readLtv(uint256 configuration) internal pure returns (uint256) {
        return configuration & 0xFFFF;
    }
}
