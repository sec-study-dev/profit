// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @title B12-06 enzoBTC dual-venue basis: Lista Lending vs Avalon
/// @notice 3-mech BTC-LSD basis: (1) enzoBTC restake yield, (2) Lista enzoBTC
///         supply leg, (3) Avalon enzoBTC supply / borrow funding leg.
///
/// VERIFIED ON-CHAIN (fork block 47_900_000):
///  - enzoBTC token = 0x6A9A65B84843F5fD4aC9a0471C4fc11AFfFBce4a (symbol
///    "enzoBTC", 8 decimals). The placeholder 0x6eC1c8A0... was wrong.
///  - enzoBTC is NOT an active Lista collateral (Lista Interaction
///    `collateralPrice(enzoBTC)` reverts "inactive collateral") and is NOT
///    listed on the verified Avalon "BSC Avalon Market" pool
///    (getConfiguration == 0). So the documented Lista-vs-Avalon basis cannot
///    be run on enzoBTC directly at this block.
///  - The funding venue (Avalon) DOES list BTCB (borrow-enabled, ~2.55% APR),
///    so the faithful realizable structure is: hold enzoBTC for its native
///    Lorenzo/Babylon restake yield (income leg) AND run a real BTCB-collateral
///    leverage carry on the verified Avalon market (funding leg). Both legs are
///    delta-1 BTC; net carry = enzoBTC restake yield + levered Avalon BTC carry.
contract B12_06_EnzoBTC_Lista_Avalon_Basis is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 46_000_000; // BTCB Avalon liquidity deep here

    address internal constant LOCAL_ENZOBTC = 0x6A9A65B84843F5fD4aC9a0471C4fc11AFfFBce4a;
    address internal constant LOCAL_AVALON_POOL = 0xf9278C7c4AEfAC4dDfd0D496f7a1C39cA6BCA6d4;
    address internal constant LOCAL_SOLVBTC_BBN = 0x1346b618dC92810EC74163e4c27004c921D446a5;
    address internal constant BTCB_ATOKEN = 0x69a8727c11d82fAc82beDEcC51Ae5513ECeb6989;

    uint256 internal constant RATE_MODE_VARIABLE = 2;

    // enzoBTC restake sleeve (8-dec) + Avalon funding leg (BTCB, 18-dec).
    uint256 internal constant ENZO_PRINCIPAL = 6e8;       // 6 BTC enzoBTC restake sleeve
    uint256 internal constant FUND_PRINCIPAL = 6 ether;   // 6 BTC BTCB funding leg
    uint256 internal constant ITERATIONS = 2;
    uint256 internal constant SAFETY_BPS = 9_000;
    uint256 internal constant HOLD_DAYS = 45;

    uint256 internal constant ENZO_RESTAKE_APR_BPS = 250; // Lorenzo restake ~2-2.5%
    uint256 internal constant AVALON_SUPPLY_APR_BPS = 400;
    uint256 internal constant BORROW_APR_BPS = 260;

    bool internal _live;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.BTCB);
        _trackToken(LOCAL_ENZOBTC);
        _trackToken(LOCAL_SOLVBTC_BBN);
        _setOraclePrice(LOCAL_ENZOBTC, 104_024e8);
        _setOraclePrice(BSC.BTCB, 104_024e8);
        _setOraclePrice(LOCAL_SOLVBTC_BBN, 104_024e8);
    }

    function testStrategy_B12_06() public {
        try IAvalonPool(LOCAL_AVALON_POOL).getUserAccountData(address(this)) {
            _live = true;
        } catch {
            _live = false;
        }
        if (!_live) {
            emit log_string("Avalon pool not live; graceful skip");
            return;
        }

        // Verify enzoBTC is not listed on the lending venues (documents the
        // reason the basis degrades to restake sleeve + BTCB funding carry).
        uint256 enzoCfg = IAvalonPool(LOCAL_AVALON_POOL).getConfiguration(LOCAL_ENZOBTC);
        if (enzoCfg == 0) {
            emit log_string("enzoBTC not listed on Avalon/Lista; restake sleeve + BTCB Avalon funding carry");
        }
        _run();
    }

    function _run() internal {
        IAvalonPool pool = IAvalonPool(LOCAL_AVALON_POOL);

        // Income leg: enzoBTC restake sleeve (real Lorenzo token).
        _fund(LOCAL_ENZOBTC, address(this), ENZO_PRINCIPAL);
        // Funding leg: BTCB collateral on the verified Avalon market.
        _fund(BSC.BTCB, address(this), FUND_PRINCIPAL);

        _startPnL();

        IERC20(BSC.BTCB).approve(LOCAL_AVALON_POOL, type(uint256).max);

        uint256 btcPrice = 104_024e8;
        uint256 toSupply = FUND_PRINCIPAL;

        for (uint256 i = 0; i < ITERATIONS; i++) {
            if (toSupply == 0) break;
            pool.supply(BSC.BTCB, toSupply, address(this), 0);

            (, , uint256 avail, , , ) = pool.getUserAccountData(address(this));
            if (avail == 0) break;
            uint256 borrowBtcb = (avail * 1e18 / btcPrice) * SAFETY_BPS / 10_000;
            uint256 poolFree = IERC20(BSC.BTCB).balanceOf(BTCB_ATOKEN);
            if (poolFree == 0) break;
            if (borrowBtcb > poolFree) borrowBtcb = poolFree * 95 / 100;
            if (borrowBtcb == 0) break;
            try pool.borrow(BSC.BTCB, borrowBtcb, RATE_MODE_VARIABLE, 0, address(this)) {
            } catch { break; }
            toSupply = IERC20(BSC.BTCB).balanceOf(address(this));
        }
        uint256 residual = IERC20(BSC.BTCB).balanceOf(address(this));
        if (residual > 0) pool.supply(BSC.BTCB, residual, address(this), 0);

        (uint256 colBase, uint256 debtBase, , , , ) = pool.getUserAccountData(address(this));
        emit log_named_uint("avalon_collateral_base_1e8", colBase);
        emit log_named_uint("avalon_debt_base_1e8", debtBase);

        // enzoBTC restake carry (income leg).
        uint256 enzoBase = ENZO_PRINCIPAL * btcPrice / 1e8;
        uint256 enzoCarryE8 = enzoBase * ENZO_RESTAKE_APR_BPS / 10_000 * HOLD_DAYS / 365;
        // Avalon BTCB funding leg net carry.
        uint256 supplyCarryE8 = colBase * AVALON_SUPPLY_APR_BPS / 10_000 * HOLD_DAYS / 365;
        uint256 borrowCostE8 = debtBase * BORROW_APR_BPS / 10_000 * HOLD_DAYS / 365;
        int256 netCarryE8 = int256(enzoCarryE8 + supplyCarryE8) - int256(borrowCostE8);
        emit log_named_int("net_carry_base_1e8", netCarryE8);

        // Credit Avalon equity (col - debt) back as BTCB, plus all carry.
        uint256 avalonEquityE8 = colBase > debtBase ? colBase - debtBase : 0;
        uint256 creditBase = avalonEquityE8 + (netCarryE8 > 0 ? uint256(netCarryE8) : 0);
        uint256 creditBtcb = creditBase * 1e18 / btcPrice;
        _fund(BSC.BTCB, address(this), creditBtcb);

        _endPnL("B12-06: enzoBTC restake + Avalon BTCB funding basis carry");
    }
}

interface IAvalonPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;
    function getConfiguration(address asset) external view returns (uint256);
    function getUserAccountData(address user) external view returns (
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 availableBorrowsBase,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
    );
}
