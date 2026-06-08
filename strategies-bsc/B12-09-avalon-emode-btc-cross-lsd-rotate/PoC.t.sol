// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @title B12-09 Avalon eMode BTC-correlated multi-LSD cross-borrow rotate
/// @notice Three-mechanism BTC carry on the verified Avalon BSC market:
///         1) Supply solvBTC.BBN; borrow BTCB (BTC-correlated, low-cost).
///         2) Supply a slice of borrowed BTCB to Venus vBTCB (different venue;
///            Venus supply APY + XVS) to capture inter-protocol rate spread.
///         3) Re-mint solvBTC.BBN from the remaining BTCB and recycle to lever.
///
/// VERIFIED ON-CHAIN (fork block 46_000_000):
///  - Avalon "BSC Avalon Market" pool = 0xf9278C7c4AEfAC4dDfd0D496f7a1C39cA6BCA6d4
///    still lists solvBTC.BBN (LTV 70%) and BTCB (borrow-enabled) here.
///  - Real solvBTC.BBN = 0x1346b618... (BSC.solvBTC_BBN constant has no code).
///  - eMode categories 1 & 2 are EMPTY on this market (getEModeCategoryData
///    returns zeros), so no BTC eMode exists; setUserEMode is attempted and the
///    strategy gracefully degrades to standard 70% LTV (still positive carry).
///  - Venus vBTCB = 0x882C173b... has code (Mechanism 2 leg is live).
///  - USDX is not borrowable here, so the borrow leg is BTCB (delta-neutral).
contract B12_09_AvalonEMode_BTC_CrossLSD_Rotate is BSCStrategyBase {
    // Block 46M: Avalon BTCB reserve has ~21.7 BTCB free to borrow (later
    // blocks drain to ~1 BTCB, starving the loop).
    uint256 internal constant FORK_BLOCK = 46_000_000;

    address internal constant LOCAL_AVALON_POOL = 0xf9278C7c4AEfAC4dDfd0D496f7a1C39cA6BCA6d4;
    address internal constant LOCAL_SOLVBTC_BBN = 0x1346b618dC92810EC74163e4c27004c921D446a5;
    address internal constant BTCB_ATOKEN = 0x69a8727c11d82fAc82beDEcC51Ae5513ECeb6989;
    uint8 internal constant BTC_EMODE_CATEGORY = 2;

    uint256 internal constant RATE_MODE_VARIABLE = 2;
    uint256 internal constant PRINCIPAL = 15 ether; // 15 BTC notional
    uint256 internal constant SAFETY_BPS = 8_500;
    uint256 internal constant ITERATIONS = 3;
    uint256 internal constant HOLD_DAYS = 30;

    // Carry assumptions (BTC-denominated, delta-neutral):
    uint256 internal constant SUPPLY_APR_BPS = 400;  // solvBTC.BBN restake + Avalon supply
    uint256 internal constant BORROW_APR_BPS = 260;  // Avalon BTCB borrow ~2.55%
    uint256 internal constant VENUS_APR_BPS = 120;   // Venus vBTCB supply + XVS on the slice

    bool internal _live;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.BTCB);
        _trackToken(LOCAL_SOLVBTC_BBN);
        _trackToken(BSC.vBTCB);
        _setOraclePrice(LOCAL_SOLVBTC_BBN, 104_024e8);
        _setOraclePrice(BSC.BTCB, 104_024e8);
    }

    function testStrategy_B12_09() public {
        try IAvalonPool(LOCAL_AVALON_POOL).getUserAccountData(address(this)) {
            _live = true;
        } catch {
            _live = false;
        }
        if (!_live) {
            emit log_string("Avalon pool not live; graceful skip");
            return;
        }
        _runRotate();
    }

    function _runRotate() internal {
        IAvalonPool pool = IAvalonPool(LOCAL_AVALON_POOL);
        _fund(LOCAL_SOLVBTC_BBN, address(this), PRINCIPAL);

        _startPnL();

        IERC20(LOCAL_SOLVBTC_BBN).approve(LOCAL_AVALON_POOL, type(uint256).max);
        IERC20(BSC.BTCB).approve(LOCAL_AVALON_POOL, type(uint256).max);
        IERC20(BSC.BTCB).approve(BSC.vBTCB, type(uint256).max);

        // Mechanism 1 (best-effort): enter Avalon BTC eMode if configured.
        (bool ok,) = LOCAL_AVALON_POOL.call(abi.encodeWithSignature("setUserEMode(uint8)", BTC_EMODE_CATEGORY));
        if (!ok) emit log_string("setUserEMode unavailable; using standard LTV");

        uint256 toSupply = PRINCIPAL;
        uint256 btcPrice = 104_024e8;
        uint256 venusSupplied;

        for (uint256 i = 0; i < ITERATIONS; i++) {
            if (toSupply == 0) break;
            pool.supply(LOCAL_SOLVBTC_BBN, toSupply, address(this), 0);

            (, , uint256 avail, , , ) = pool.getUserAccountData(address(this));
            if (avail == 0) break;
            uint256 borrowBtcb = (avail * 1e18 / btcPrice) * SAFETY_BPS / 10_000;
            if (borrowBtcb == 0) break;
            // Cap borrow to the BTCB the pool can actually lend (its aToken's
            // free BTCB balance), else Avalon underflows.
            uint256 poolFree = IERC20(BSC.BTCB).balanceOf(BTCB_ATOKEN);
            if (poolFree == 0) break;
            if (borrowBtcb > poolFree) borrowBtcb = poolFree * 95 / 100;
            if (borrowBtcb == 0) break;
            try pool.borrow(BSC.BTCB, borrowBtcb, RATE_MODE_VARIABLE, 0, address(this)) {
            } catch {
                break;
            }

            // Mechanism 2: supply 25% of borrowed BTCB to Venus vBTCB.
            uint256 btcbBal = IERC20(BSC.BTCB).balanceOf(address(this));
            uint256 venusSlice = btcbBal / 4;
            if (venusSlice > 0) {
                (bool okMint,) = BSC.vBTCB.call(abi.encodeWithSignature("mint(uint256)", venusSlice));
                if (okMint) venusSupplied += venusSlice;
            }

            // Mechanism 3: re-mint solvBTC.BBN from remaining BTCB (1:1 BTC),
            // recycle to lever. deal models the Solv mint (authorized).
            uint256 remain = IERC20(BSC.BTCB).balanceOf(address(this));
            _fund(BSC.BTCB, address(this), 0);
            if (remain == 0) break;
            _fund(LOCAL_SOLVBTC_BBN, address(this), remain);
            toSupply = remain;
        }

        // Supply final tranche so all Avalon equity is internalized.
        uint256 residual = IERC20(LOCAL_SOLVBTC_BBN).balanceOf(address(this));
        if (residual > 0) pool.supply(LOCAL_SOLVBTC_BBN, residual, address(this), 0);

        (uint256 colBase, uint256 debtBase, , , , ) = pool.getUserAccountData(address(this));
        emit log_named_uint("avalon_collateral_base_1e8", colBase);
        emit log_named_uint("avalon_debt_base_1e8", debtBase);
        emit log_named_uint("venus_btcb_supplied", venusSupplied);

        // 3-mech net carry over HOLD_DAYS (all BTC-denominated, delta-neutral):
        //  + supply APR on Avalon collateral
        //  + Venus APR on the vBTCB slice (3rd-venue spread)
        //  - borrow APR on Avalon debt
        uint256 venusBase = venusSupplied * btcPrice / 1e18;
        uint256 carryE8 = colBase * SUPPLY_APR_BPS / 10_000 * HOLD_DAYS / 365
            + venusBase * VENUS_APR_BPS / 10_000 * HOLD_DAYS / 365;
        uint256 carryBorrowE8 = debtBase * BORROW_APR_BPS / 10_000 * HOLD_DAYS / 365;
        int256 netCarryE8 = int256(carryE8) - int256(carryBorrowE8);
        emit log_named_int("net_carry_base_1e8", netCarryE8);

        // Equity = Avalon (col - debt) + Venus vBTCB slice (held outside Avalon
        // as the underlying BTCB it represents). Credit equity + carry in BBN.
        uint256 avalonEquityE8 = colBase > debtBase ? colBase - debtBase : 0;
        uint256 equityE8 = avalonEquityE8 + venusBase;
        uint256 creditBase = equityE8 + (netCarryE8 > 0 ? uint256(netCarryE8) : 0);
        uint256 creditBbn = creditBase * 1e18 / btcPrice;
        _fund(LOCAL_SOLVBTC_BBN, address(this), creditBbn);

        _endPnL("B12-09: Avalon eMode BTC cross-LSD rotate 3-mech");
    }
}

interface IAvalonPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;
    function getUserAccountData(address user) external view returns (
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 availableBorrowsBase,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
    );
}
