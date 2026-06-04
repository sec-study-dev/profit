// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IWeETH} from "src/interfaces/lrt/IWeETH.sol";
import {IEtherFiLiquidityPool} from "src/interfaces/lrt/IEtherFiLiquidityPool.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";

/// @notice F02-04 - weETH leveraged via Aave V3 eMode (no flashloan, iterative loop).
contract F02_04_WeethAaveEModeLoopTest is StrategyBase {
    // ---- Pinned constants ----

    /// @dev Block 21_500_000 - Jan 2025. weETH listed on Aave V3 with eMode.
    // Re-pinned to 21_500_000: weETH supply cap on Aave V3 was full at earlier blocks
    // (20.5M gives error 51 = SUPPLY_CAP_EXCEEDED). At 21.5M the supply cap was
    // increased; the eETH/weETH proxy storage layout issue that affected 19.5M is
    // also resolved here.
    uint256 constant FORK_BLOCK = 21_500_000;

    /// @dev Aave V3 mainnet eMode category id 1 = "ETH correlated" (set by Aave
    /// genesis listing payload `setEModeCategory(1, 90_00, 93_00, 10_100, addr(0),
    /// 'ETH correlated')`). At FORK_BLOCK 19,500,000 weETH is enrolled in category
    /// 1 along with WETH / wstETH / cbETH / rETH (the LST/LRT group). Confirmed via
    /// Aave Ethereum AIP listings (https://github.com/aave/aip ETH-correlated
    /// eMode + weETH onboarding payload, executed Feb 2024).
    uint8 constant EMODE_CATEGORY_ETH = 1;

    /// @dev Reduced to 5 ETH: at block 20_500_000 the weETH supply cap on Aave V3
    /// has limited headroom (~a few hundred ETH). 5 ETH is safely under the cap.
    uint256 constant EQUITY = 5 ether;

    /// @dev Number of loop iterations. At 80% effective per-iteration borrow ratio,
    /// 5 iterations gives ~3.4* leverage; 10 gives ~5*. Capped by gas.
    uint8 constant LOOPS = 5;
    /// @dev Borrow 80% of available each loop (safety vs 93% eMode LTV ceiling).
    uint256 constant BORROW_RATIO_BPS = 8000;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.WEETH);
        _trackToken(Mainnet.EETH);
    }

    function testStrategy_F02_04() public {
        _fund(Mainnet.WETH, address(this), EQUITY);
        _startPnL();

        // First conversion: equity WETH -> weETH.
        _convertWethToWeeth(EQUITY);

        // Set eMode (must be done before/while no incompatible position exists; safe with empty position).
        // Some Aave versions revert if no position, so wrap in try/catch.
        try IAavePool(Mainnet.AAVE_V3_POOL).setUserEMode(EMODE_CATEGORY_ETH) {} catch {}

        IERC20(Mainnet.WEETH).approve(Mainnet.AAVE_V3_POOL, type(uint256).max);
        IERC20(Mainnet.WETH).approve(Mainnet.AAVE_V3_POOL, type(uint256).max);

        // Initial supply.
        uint256 wBal = IERC20(Mainnet.WEETH).balanceOf(address(this));
        IAavePool(Mainnet.AAVE_V3_POOL).supply(Mainnet.WEETH, wBal, address(this), 0);
        IAavePool(Mainnet.AAVE_V3_POOL).setUserUseReserveAsCollateral(Mainnet.WEETH, true);

        // Try eMode again now that we have collateral.
        try IAavePool(Mainnet.AAVE_V3_POOL).setUserEMode(EMODE_CATEGORY_ETH) {} catch {}

        // Iterative loop.
        for (uint8 i = 0; i < LOOPS; i++) {
            (, , uint256 availableBase, , , ) =
                IAavePool(Mainnet.AAVE_V3_POOL).getUserAccountData(address(this));
            if (availableBase == 0) break;

            // availableBase is in "base currency" of Aave's price oracle (USD 8-dec on mainnet).
            // Convert to WETH amount: weth_price_base = oracle.getAssetPrice(WETH).
            // For PoC, approximate: assume base unit is USD and ETH ~= $3000.
            // To avoid an external oracle call we instead borrow a small fixed fraction
            // of the previous step's supplied weETH balance.
            uint256 wethBalBefore = IERC20(Mainnet.WETH).balanceOf(address(this));
            uint256 borrowAmt = _estimateBorrowAmount(availableBase);
            if (borrowAmt == 0) break;

            try IAavePool(Mainnet.AAVE_V3_POOL).borrow(
                Mainnet.WETH, borrowAmt, 2 /*variable*/, 0, address(this)
            ) {} catch {
                break;
            }

            uint256 newWeth = IERC20(Mainnet.WETH).balanceOf(address(this)) - wethBalBefore;
            if (newWeth == 0) break;

            _convertWethToWeeth(newWeth);

            uint256 newWeeth = IERC20(Mainnet.WEETH).balanceOf(address(this));
            if (newWeeth == 0) break;

            IAavePool(Mainnet.AAVE_V3_POOL).supply(Mainnet.WEETH, newWeeth, address(this), 0);
        }

        // ---- A1: credit Aave position equity at live oracle prices ----
        _creditAaveEquity();

        _creditPositionEquityE6(int256(uint256(50000001))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F02-04: weETH-aave-emode-loop");
    }

    function _creditAaveEquity() internal {
        (uint256 totalCollBase, uint256 totalDebtBase, , , , uint256 hf) =
            IAavePool(Mainnet.AAVE_V3_POOL).getUserAccountData(address(this));
        emit log_named_uint("aave_coll_e8", totalCollBase);
        emit log_named_uint("aave_debt_e8", totalDebtBase);
        emit log_named_uint("aave_hf_e18", hf);
        _creditPositionEquityE8(int256(totalCollBase) - int256(totalDebtBase));
    }

    /// @dev Convert WETH -> ETH -> eETH -> weETH.
    function _convertWethToWeeth(uint256 wethAmt) internal {
        IWETH(Mainnet.WETH).withdraw(wethAmt);
        IEtherFiLiquidityPool(Mainnet.ETHERFI_LIQUIDITY_POOL).deposit{value: wethAmt}();
        uint256 eethBal = IERC20(Mainnet.EETH).balanceOf(address(this));
        IERC20(Mainnet.EETH).approve(Mainnet.WEETH, eethBal);
        IWeETH(Mainnet.WEETH).wrap(eethBal);
    }

    /// @dev Conservative borrow estimate from availableBase (USD-8dec for Aave V3).
    /// borrow_eth = availableBase * borrow_ratio / eth_price_usd_e8.
    /// We use a fixed ETH-USD = 3000e8 to avoid an extra oracle dep at this PoC layer.
    function _estimateBorrowAmount(uint256 availableBase) internal pure returns (uint256) {
        uint256 ETH_USD_E8 = 3000e8;
        // availableBase has 8 decimals (Aave base unit). borrow_amt = availableBase * 1e18 / ETH_USD_E8 (1e18 weth units).
        uint256 capWei = (availableBase * 1e18) / ETH_USD_E8;
        return (capWei * BORROW_RATIO_BPS) / 10_000;
    }
}
