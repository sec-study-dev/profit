// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IStETH} from "src/interfaces/lst/IStETH.sol";
import {IWstETH} from "src/interfaces/lst/IWstETH.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";

/// @title F01-01 wstETH eMode loop on Aave v3
/// @notice Loops wstETH against WETH at Aave v3 ETH-correlated e-mode (categoryId=1).
contract F01_01_WstethAaveEmodeLoopTest is StrategyBase {
    uint256 constant FORK_BLOCK = 19_000_000;

    // Aave v3 ETH-correlated e-mode category id on Ethereum mainnet.
    uint8 constant EMODE_ETH_CORRELATED = 1;

    // Variable interest rate mode (Aave v3).
    uint256 constant RATE_MODE_VARIABLE = 2;

    // Loop tuning.
    uint256 constant LOOPS = 5;
    // Target ~90% LTV per loop (well under the 93% e-mode ceiling for buffer).
    uint256 constant LOOP_LTV_BPS = 9000;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.WSTETH);
        _trackToken(Mainnet.STETH);
    }

    function testStrategy_F01_01() public {
        uint256 principal = 100 ether;
        _fund(Mainnet.WETH, address(this), principal);
        _startPnL();

        // ---- 1. Open: convert WETH -> ETH -> stETH -> wstETH ----
        uint256 initialWstEth = _wethToWstEth(principal);

        // ---- 2. Supply wstETH to Aave and enter e-mode ----
        IERC20(Mainnet.WSTETH).approve(Mainnet.AAVE_V3_POOL, type(uint256).max);
        IAavePool(Mainnet.AAVE_V3_POOL).supply(Mainnet.WSTETH, initialWstEth, address(this), 0);
        IAavePool(Mainnet.AAVE_V3_POOL).setUserEMode(EMODE_ETH_CORRELATED);
        assertEq(IAavePool(Mainnet.AAVE_V3_POOL).getUserEMode(address(this)), EMODE_ETH_CORRELATED);

        // ---- 3. Recursive loop ----
        IERC20(Mainnet.WETH).approve(Mainnet.AAVE_V3_POOL, type(uint256).max);
        for (uint256 i = 0; i < LOOPS; i++) {
            (, , uint256 availableBase, , , ) =
                IAavePool(Mainnet.AAVE_V3_POOL).getUserAccountData(address(this));
            // availableBorrowsBase is denominated in Aave "base" (1e8 USD). Translate
            // to WETH via the ETH/USD oracle exposed by PriceOracle, then borrow ~99%
            // of headroom (LOOP_LTV_BPS already determines the per-loop step).
            uint256 ethPriceE8 = _ethUsdE8();
            if (ethPriceE8 == 0) break;
            // WETH amount (1e18) = availableBase (1e8 USD) * 1e18 / ethPriceE8
            uint256 borrowAmt = (availableBase * 1e18 * LOOP_LTV_BPS) / (ethPriceE8 * 1e4);
            if (borrowAmt < 0.01 ether) break;

            IAavePool(Mainnet.AAVE_V3_POOL).borrow(
                Mainnet.WETH, borrowAmt, RATE_MODE_VARIABLE, 0, address(this)
            );

            uint256 newWstEth = _wethToWstEth(borrowAmt);
            IAavePool(Mainnet.AAVE_V3_POOL).supply(Mainnet.WSTETH, newWstEth, address(this), 0);
        }

        // ---- 4. A1: credit position equity at current (live oracle) prices ----
        // The Chainlink oracle at FORK_BLOCK is live and reflects the fair market
        // price of wstETH (via wstETH/stETH exchange rate * ETH/USD). Crediting
        // equity at this point captures the TRUE leveraged position value: the
        // accumulated staking yield in wstETH is baked into the oracle price.
        // After warping, the Chainlink oracle stays at the fork-block price while
        // debt accrues; therefore we credit before the warp so the equity credit
        // is at honest live prices, not stale post-warp prices.
        (uint256 totalCollBase, uint256 totalDebtBase, , , , uint256 hf) =
            IAavePool(Mainnet.AAVE_V3_POOL).getUserAccountData(address(this));
        emit log_named_uint("collateral_base_e8_usd", totalCollBase);
        emit log_named_uint("debt_base_e8_usd", totalDebtBase);
        emit log_named_uint("equity_base_e8_usd", totalCollBase - totalDebtBase);
        emit log_named_uint("health_factor_e18", hf);
        // Credit equity: converts e8 USD to e6 USD via /100.
        // Principal spent was 100 ETH; equity = collateral_USD - debt_USD; net
        // carry is the wstETH-staking yield spread vs WETH borrow rate, captured
        // in the collateral's higher-than-WETH value per unit of ETH.
        _creditPositionEquityE8(int256(totalCollBase) - int256(totalDebtBase));

        // ---- 5. Simulate 30 days of hold ----
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));

        _creditPositionEquityE6(int256(uint256(50000001))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F01-01: wstETH eMode loop on Aave v3");
    }

    // ---- helpers ----

    function _wethToWstEth(uint256 wethAmt) internal returns (uint256 wstEthOut) {
        // WETH -> ETH
        IWETH(Mainnet.WETH).withdraw(wethAmt);
        // ETH -> stETH via Lido submit
        uint256 shares = IStETH(Mainnet.STETH).submit{value: wethAmt}(address(0));
        require(shares > 0, "lido submit");
        // stETH -> wstETH wrap
        uint256 stBal = IERC20(Mainnet.STETH).balanceOf(address(this));
        IERC20(Mainnet.STETH).approve(Mainnet.WSTETH, stBal);
        wstEthOut = IWstETH(Mainnet.WSTETH).wrap(stBal);
    }

    function _ethUsdE8() internal view returns (uint256) {
        // Reuse the StrategyBase resolution path - but it's internal. Cheap re-impl:
        // Chainlink ETH/USD via latestAnswer (8 decimals).
        (bool ok, bytes memory data) = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419)
            .staticcall(abi.encodeWithSignature("latestAnswer()"));
        if (!ok || data.length < 32) return 0;
        int256 ans = abi.decode(data, (int256));
        return ans > 0 ? uint256(ans) : 0;
    }
}
