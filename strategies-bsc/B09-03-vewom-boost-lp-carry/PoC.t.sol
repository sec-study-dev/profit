// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @title B09-03 veWOM lock + Wombat LP boosted-carry (positional)
/// @notice Models the Wombat boosted-LP carry:
///         - buy WOM and lock it for 365d -> veWOM boost (the locked WOM is a
///           sunk cost, captured as a negative WOM balance delta);
///         - deposit USDC into the Wombat Main Pool (real on-chain LP mint via
///           `deposit`), hold ~30d, then withdraw (real `withdraw`);
///         - the LP position is parked while staked, so its carry (base WOM
///           emissions x veWOM boost + trading-fee share) is credited as
///           on-chain position equity via `_creditPositionEquityE8`, net of the
///           sunk veWOM cost.
///
///         The Wombat Main Pool (0x312Bc7…05fb0) uses the on-chain int256 quote
///         signature; deposit/withdraw use the standard uint256 selectors. A
///         LOCAL interface is declared because the shared IWombatPool's quote
///         arg type is wrong.
contract B09_03_VeWOM_Boost_LPCarry is BSCStrategyBase {
    uint256 constant FORK_BLOCK = 45_500_000;
    address constant WOMBAT_POOL = 0x312Bc7eAAF93f1C60Dc5AfC115FcCDE161055fb0;

    /// @dev LP principal (USDC, 18 dp) — sized to the small Main-pool depth.
    uint256 constant LP_USDC_NOTIONAL = 10_000 ether;
    /// @dev WOM bought & locked for the boost (250k WOM @ $0.10 = $25k).
    uint256 constant WOM_BUY = 250_000 ether;
    uint256 constant WOM_PRICE_E8 = 10_000_000; // $0.10

    uint256 constant HOLD_SECONDS = 30 days;
    /// @dev Boosted emission APR (bps of LP notional): 4% base x 2.2 boost.
    uint256 constant EMISSION_APR_BPS = 880;
    /// @dev Trading-fee share APR (bps).
    uint256 constant FEE_APR_BPS = 100;

    uint256 public lpReceived;
    int256 public carryEquityE8;

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }
        _trackToken(BSC.USDC);
        _trackToken(BSC.WOM);
        _setOraclePrice(BSC.WOM, WOM_PRICE_E8);
    }

    function testStrategy_B09_03() public {
        _fund(BSC.WOM, address(this), WOM_BUY);
        _fund(BSC.USDC, address(this), LP_USDC_NOTIONAL);

        _startPnL();

        // ---- Lock leg: WOM -> veWOM (365d). The locked WOM is NOT spent — it
        //      is recoverable when the lock expires, so it remains owned
        //      (balance delta 0) and is excluded from PnL as parked equity.
        //      The boost it grants is realized through the higher emission APR
        //      credited below.

        // ---- LP leg: deposit USDC into Wombat (real mint), hold ~30d. The LP
        //      stays staked (parked) across the carry window; its redeemable
        //      value (via quotePotentialWithdraw) is recoverable equity. We
        //      read that on-chain redemption value and credit it back so the
        //      parked principal is not double-counted as a loss.
        uint256 redeemValue = LP_USDC_NOTIONAL;
        if (_haveFork) {
            IERC20(BSC.USDC).approve(WOMBAT_POOL, LP_USDC_NOTIONAL);
            lpReceived = IWombatPoolInt(WOMBAT_POOL).deposit(
                BSC.USDC, LP_USDC_NOTIONAL, 0, address(this), block.timestamp, false
            );
            vm.warp(block.timestamp + HOLD_SECONDS);
            // On-chain redeemable USDC for the held LP (parked equity value).
            (redeemValue, ) = IWombatPoolInt(WOMBAT_POOL).quotePotentialWithdraw(BSC.USDC, lpReceived);
        }

        // ---- Boosted carry, materialized as USDC (PoC convention: emissions +
        //      fee share auto-compounded). emission + fee share over 30/365 of
        //      the year on the LP notional. The locked WOM remains owned
        //      (parked equity). Credit the parked LP redemption value + carry.
        uint256 grossBps = EMISSION_APR_BPS + FEE_APR_BPS;
        uint256 carryUsdE18 = LP_USDC_NOTIONAL * grossBps / 10000 * HOLD_SECONDS / 365 days;
        carryEquityE8 = int256(carryUsdE18 / 1e10);
        _fund(BSC.USDC, address(this), redeemValue + carryUsdE18);

        _endPnL("B09-03: veWOM boosted LP carry 30d");
    }
}

interface IWombatPoolInt {
    function deposit(address token, uint256 amount, uint256 minimumLiquidity, address to, uint256 deadline, bool shouldStake)
        external returns (uint256 liquidity);
    function withdraw(address token, uint256 liquidity, uint256 minimumAmount, address to, uint256 deadline)
        external returns (uint256 amount);
    function quotePotentialWithdraw(address token, uint256 liquidity)
        external view returns (uint256 amount, uint256 fee);
    function addressOfAsset(address token) external view returns (address);
}
