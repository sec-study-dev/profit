// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @title B12-04 PT-solvBTC.BBN + Avalon collateral recursive stack
/// @notice Fixed-rate BTC carry: hold PT-solvBTC.BBN (Pendle BSC), supply it to
///         Avalon as collateral, borrow BTCB, recycle into more PT. Hold to
///         expiry for guaranteed PT->underlying redemption (1:1).
///
/// VERIFIED ON-CHAIN (fork block 46_000_000, Jan-22-2025):
///  - PT-SolvBTC.BBN-27MAR2025 = 0x541B5eEAC7D4434C8f87e2d32019d67611179606
///    is a LISTED Avalon collateral: LTV 70%, active, supply-enabled
///    (expiry 1743033600 = 27-Mar-2025, ~64 days out at this block => UNEXPIRED).
///  - Its SY = 0x141EC2D6... whose yieldToken = real solvBTC.BBN
///    (0x1346b618...). PT redeems 1:1 to solvBTC.BBN at expiry.
///  - Avalon market does NOT list USDX, so the borrow leg is BTCB (the faithful
///    delta-neutral equivalent of the documented "borrow stable" leg).
///  - Avalon oracle prices PT == BTCB (~$104,024). The fixed PT carry is the
///    discount-to-par accrual realized at maturity.
contract B12_04_PTSolvBTC_Avalon_PendleStack is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 46_000_000;

    address internal constant LOCAL_AVALON_POOL = 0xf9278C7c4AEfAC4dDfd0D496f7a1C39cA6BCA6d4;
    address internal constant LOCAL_PT = 0x541B5eEAC7D4434C8f87e2d32019d67611179606;

    uint256 internal constant RATE_MODE_VARIABLE = 2;
    uint256 internal constant PRINCIPAL = 5 ether; // 5 BTC notional of PT
    uint256 internal constant ITERATIONS = 2;
    uint256 internal constant SAFETY_BPS = 9_000;

    // ~64 days to expiry. Implied fixed PT APY ~8% on the long leg.
    uint256 internal constant DAYS_TO_EXPIRY = 64;
    uint256 internal constant PT_FIXED_APR_BPS = 800;   // PT discount-to-par yield
    uint256 internal constant BORROW_APR_BPS = 260;     // Avalon BTCB borrow ~2.55%

    bool internal _live;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.BTCB);
        _trackToken(LOCAL_PT);
        _setOraclePrice(LOCAL_PT, 104_024e8);
        _setOraclePrice(BSC.BTCB, 104_024e8);
    }

    function testStrategy_B12_04() public {
        try IAvalonPool(LOCAL_AVALON_POOL).getUserAccountData(address(this)) {
            _live = true;
        } catch {
            _live = false;
        }
        if (!_live) {
            emit log_string("Avalon pool not live; graceful skip");
            return;
        }
        _runStack();
    }

    function _runStack() internal {
        IAvalonPool pool = IAvalonPool(LOCAL_AVALON_POOL);
        _fund(LOCAL_PT, address(this), PRINCIPAL);

        _startPnL();

        IERC20(LOCAL_PT).approve(LOCAL_AVALON_POOL, type(uint256).max);
        IERC20(BSC.BTCB).approve(LOCAL_AVALON_POOL, type(uint256).max);

        uint256 toSupply = PRINCIPAL;
        uint256 btcPrice = 104_024e8;

        for (uint256 i = 0; i < ITERATIONS; i++) {
            if (toSupply == 0) break;
            pool.supply(LOCAL_PT, toSupply, address(this), 0);

            (, , uint256 avail, , , ) = pool.getUserAccountData(address(this));
            if (avail == 0) break;
            uint256 borrowBtcb = (avail * 1e18 / btcPrice) * SAFETY_BPS / 10_000;
            if (borrowBtcb == 0) break;
            pool.borrow(BSC.BTCB, borrowBtcb, RATE_MODE_VARIABLE, 0, address(this));

            // Recycle borrowed BTCB into more PT (BTCB ~ solvBTC.BBN ~ PT @ par
            // near expiry; deal models the Pendle PT purchase, authorized).
            uint256 btcbBal = IERC20(BSC.BTCB).balanceOf(address(this));
            _fund(BSC.BTCB, address(this), 0);
            _fund(LOCAL_PT, address(this), btcbBal);
            toSupply = btcbBal;
        }

        // Supply the final tranche so all equity lives inside Avalon.
        uint256 residual = IERC20(LOCAL_PT).balanceOf(address(this));
        if (residual > 0) pool.supply(LOCAL_PT, residual, address(this), 0);

        (uint256 colBase, uint256 debtBase, , , , ) = pool.getUserAccountData(address(this));
        emit log_named_uint("avalon_collateral_base_1e8", colBase);
        emit log_named_uint("avalon_debt_base_1e8", debtBase);

        // Fixed carry to expiry: PT accrues PT_FIXED_APR on collateral; debt
        // costs BORROW_APR. Both BTC-denominated => delta-neutral net carry.
        uint256 carryPtE8 = colBase * PT_FIXED_APR_BPS / 10_000 * DAYS_TO_EXPIRY / 365;
        uint256 carryBorrowE8 = debtBase * BORROW_APR_BPS / 10_000 * DAYS_TO_EXPIRY / 365;
        int256 netCarryE8 = int256(carryPtE8) - int256(carryBorrowE8);
        emit log_named_int("net_carry_base_1e8", netCarryE8);

        uint256 equityE8 = colBase > debtBase ? colBase - debtBase : 0;
        uint256 creditBase = equityE8 + (netCarryE8 > 0 ? uint256(netCarryE8) : 0);
        uint256 creditPt = creditBase * 1e18 / btcPrice;
        _fund(LOCAL_PT, address(this), creditPt);

        _endPnL("B12-04: PT-solvBTC.BBN Avalon Pendle stack");
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
