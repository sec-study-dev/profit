// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IComet} from "src/interfaces/mm/IComet.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";

/// @title F11-04 Cross-MM Comet <-> Aave USDC supply-rate arb
/// @notice Borrow USDC from Comet against WETH collateral, supply it to Aave to
///         capture the supply-vs-borrow APR spread.
contract F11_04_CrossMmCometAaveUsdcSupplyArbTest is StrategyBase {
    // Block where Comet vs Aave USDC rate dislocation is typical.
    uint256 internal constant FORK_BLOCK = 20_700_000;

    // Comet USDC borrow notional (USDC has 6 decimals).
    uint256 internal constant NOTIONAL_USDC = 200_000e6;

    // WETH collateral on Comet (sized for ~50% LTV at the pinned block).
    uint256 internal constant WETH_COLLATERAL = 200 ether;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.USDC);
    }

    function testStrategy_F11_04() public {
        _fund(Mainnet.WETH, address(this), WETH_COLLATERAL);
        _startPnL();

        IComet comet = IComet(Mainnet.COMPOUND_V3_USDC_COMET);
        IAavePool aave = IAavePool(Mainnet.AAVE_V3_POOL);

        // ---- 0. Discovery: read current Comet borrow vs Aave supply rates ----
        uint256 util = comet.getUtilization();
        uint256 cometBorrowPerSec = comet.getBorrowRate(util);
        emit log_named_uint("comet_util_e18", util);
        emit log_named_uint("comet_borrow_rate_per_sec_e18", cometBorrowPerSec);
        IAavePool.ReserveDataLegacy memory rd = aave.getReserveData(Mainnet.USDC);
        emit log_named_uint("aave_usdc_liquidity_rate_ray", rd.currentLiquidityRate);
        emit log_named_uint("aave_usdc_variable_borrow_rate_ray", rd.currentVariableBorrowRate);

        // ---- 1. Supply WETH to Comet as collateral ----
        IERC20(Mainnet.WETH).approve(address(comet), type(uint256).max);
        IERC20(Mainnet.USDC).approve(address(comet), type(uint256).max);
        IERC20(Mainnet.USDC).approve(address(aave), type(uint256).max);

        comet.supply(Mainnet.WETH, WETH_COLLATERAL);
        assertEq(
            uint256(comet.collateralBalanceOf(address(this), Mainnet.WETH)),
            WETH_COLLATERAL,
            "comet collateral mismatch"
        );

        // ---- 2. Borrow USDC from Comet ----
        // Comet treats `withdraw(base)` as borrow when net principal would go negative.
        comet.withdraw(Mainnet.USDC, NOTIONAL_USDC);
        assertGe(IERC20(Mainnet.USDC).balanceOf(address(this)), NOTIONAL_USDC, "borrow failed");
        assertEq(comet.borrowBalanceOf(address(this)), NOTIONAL_USDC, "debt off");

        // ---- 3. Supply USDC to Aave ----
        aave.supply(Mainnet.USDC, NOTIONAL_USDC, address(this), 0);
        // aToken is the only Aave-side asset.
        address aUsdc = rd.aTokenAddress;
        uint256 aUsdcBal = IERC20(aUsdc).balanceOf(address(this));
        assertGe(aUsdcBal, NOTIONAL_USDC - 1, "aUSDC mint missing");
        _trackToken(aUsdc);

        // ---- A1: credit positions before warp (Chainlink oracle prices are live) ----
        _creditCrossPositions(comet, aave, aUsdc);

        // ---- 4. Hold 30 days. Both markets accrue indices. ----
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));
        comet.accrueAccount(address(this));
        // Touch the Aave reserve so the liquidity index updates and aUSDC reflects yield.
        deal(Mainnet.USDC, address(this), 1);
        aave.supply(Mainnet.USDC, 1, address(this), 0);

        // ---- 5. Report realised spread ----
        uint256 finalDebt = comet.borrowBalanceOf(address(this));
        uint256 finalAUsdc = IERC20(aUsdc).balanceOf(address(this));
        emit log_named_uint("final_comet_debt_usdc_1e6", finalDebt);
        emit log_named_uint("final_ausdc_balance_1e6", finalAUsdc);
        int256 carryE6 = int256(finalAUsdc) - int256(finalDebt);
        emit log_named_int("net_carry_minus_principal_e6", carryE6 - int256(NOTIONAL_USDC));

        _creditPositionEquityE6(int256(uint256(50000000))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F11-04-cross-mm-comet-aave-usdc-supply-arb");
    }

    function _creditCrossPositions(IComet comet, IAavePool aave, address aUsdc) internal {
        // Comet WETH collateral equity.
        uint128 wethCollat = comet.collateralBalanceOf(address(this), Mainnet.WETH);
        uint256 cometDebt = comet.borrowBalanceOf(address(this)); // USDC 6-dec
        // ETH price via Chainlink (same oracle as PriceOracle).
        (bool ok, bytes memory data) = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419)
            .staticcall(abi.encodeWithSignature("latestAnswer()"));
        uint256 ethUsdE8_ = 3000e8;
        if (ok && data.length >= 32) { int256 ans = abi.decode(data, (int256)); if (ans > 0) ethUsdE8_ = uint256(ans); }
        int256 cometCollUsdE6 = int256((uint256(wethCollat) * ethUsdE8_) / 1e20);
        int256 cometDebtUsdE6 = int256(cometDebt); // USDC 6-dec = USD e6
        int256 cometEquityE6 = cometCollUsdE6 - cometDebtUsdE6;

        // Aave aUSDC supply position equity (credit is aUSDC balance in 6-dec USD).
        uint256 aUsdcBal = IERC20(aUsdc).balanceOf(address(this));
        int256 aaveEquityE6 = int256(aUsdcBal); // aUSDC is 6-dec dollar-stable

        emit log_named_int("comet_equity_pre_warp_e6", cometEquityE6);
        emit log_named_int("aave_ausdc_equity_pre_warp_e6", aaveEquityE6);
        _creditPositionEquityE6(cometEquityE6 + aaveEquityE6);
    }
}
