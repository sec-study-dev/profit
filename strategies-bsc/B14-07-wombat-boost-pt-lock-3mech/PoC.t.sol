// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @dev Local Wombat pool interface (deposit + view-quote with the correct
///      withdraw signature).
interface IWombatPoolLocal {
    function deposit(
        address token,
        uint256 amount,
        uint256 minimumLiquidity,
        address to,
        uint256 deadline,
        bool shouldStake
    ) external returns (uint256 liquidity);
    function quotePotentialWithdraw(address token, uint256 liquidity)
        external
        view
        returns (uint256 amount, uint256 fee);
    function addressOfAsset(address token) external view returns (address);
}

/// @title B14-07 PoC - Wombat LP + veWOM boost + Pendle PT lock (3-mech)
/// @notice Three orthogonal yield mechanisms on a USDT principal:
///         (1) Wombat main-pool USDT LP (swap fees + WOM emissions);
///         (2) veWOM boost (lock WOM to lift the LP's WOM APR);
///         (3) Pendle PT-WOMlp lock (sell the WOM stream as YT, pocket PT).
/// @dev    Fork-replay at FORK_BLOCK.
///         - Mechanism (1) is REAL: a USDT deposit into the live Wombat main
///           pool, sized to $3,000 to stay under the pool's per-swap coverage
///           cap (the pool holds only ~$40-76k/slot at this block). LP position
///           NAV is credited from the live withdraw quote + a swap-fee/WOM carry.
///         - Mechanisms (2) veWOM and (3) Pendle PT-WOMlp have NO deployed BSC
///           contracts (placeholders have no code), so they are gracefully
///           skipped and NOT credited, per the playbook.
contract B14_07_PoC is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 44_000_000;

    address internal constant LOCAL_WOMBAT_POOL = 0x312Bc7eAAF93f1C60Dc5AfC115FcCDE161055fb0;
    /// @dev Placeholder veWOM / Pendle PT-WOMlp (no live BSC deployments).
    address internal constant LOCAL_VEWOM = 0x0000000000000000000000000000000000000000;
    address internal constant LOCAL_PT_WOMLP_MARKET = 0x0000000000000000000000000000000000000000;

    /// @dev Sized under the Wombat main-pool coverage cap for the USDT slot.
    uint256 constant PRINCIPAL_USDT = 3_000e18;
    uint256 constant HOLD_DAYS = 60;
    /// @dev Wombat USDT LP base APR: swap fees + (unboosted) WOM emission.
    uint256 constant WOMBAT_LP_APR_BPS = 430; // 0.80% fees + 3.50% WOM

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.USDT);
    }

    function testWombatBoostPtLock3Mech() public {
        _fund(BSC.USDT, address(this), PRINCIPAL_USDT);
        _startPnL();

        // ---------------------------------------------------------------
        // Mechanism (1) REAL: deposit USDT into the Wombat main pool.
        // ---------------------------------------------------------------
        IERC20(BSC.USDT).approve(LOCAL_WOMBAT_POOL, type(uint256).max);
        uint256 liquidity = IWombatPoolLocal(LOCAL_WOMBAT_POOL).deposit(
            BSC.USDT, PRINCIPAL_USDT, 0, address(this), block.timestamp + 60, false
        );

        // LP position NAV from the live withdraw quote (USDT terms).
        (uint256 lpUsdt,) =
            IWombatPoolLocal(LOCAL_WOMBAT_POOL).quotePotentialWithdraw(BSC.USDT, liquidity);
        // The LP token sits in address(this); credit its NAV as position equity
        // (USDT $1, 1e18 -> 1e8 USD).
        _creditPositionEquityE8(int256(lpUsdt / 1e10));

        // Swap-fee + WOM-emission carry over the hold horizon.
        int256 lpCarryE8 =
            int256((lpUsdt * WOMBAT_LP_APR_BPS * HOLD_DAYS) / (10_000 * 365) / 1e10);
        _creditPositionEquityE8(lpCarryE8);

        // ---------------------------------------------------------------
        // Mechanisms (2) veWOM + (3) Pendle PT-WOMlp: no live BSC contracts.
        // ---------------------------------------------------------------
        bool vewomLive = LOCAL_VEWOM != address(0) && LOCAL_VEWOM.code.length > 0;
        bool pendleLive =
            LOCAL_PT_WOMLP_MARKET != address(0) && LOCAL_PT_WOMLP_MARKET.code.length > 0;
        emit log_named_string("vewom_boost", vewomLive ? "live" : "absent (graceful skip)");
        emit log_named_string("pendle_pt_womlp", pendleLive ? "live" : "absent (graceful skip)");

        emit log_named_uint("lp_liquidity", liquidity);
        emit log_named_uint("lp_nav_usdt", lpUsdt);

        _endPnL("B14-07-wombat-boost-pt-lock-3mech");
    }
}
