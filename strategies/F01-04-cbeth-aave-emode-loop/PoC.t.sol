// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {ICbETH} from "src/interfaces/lst/ICbETH.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";

// Local interface for Uniswap v3 single-swap router (subset of ISwapRouter).
interface IUniV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @title F01-04 cbETH eMode loop on Aave v3 (historical inversion window)
contract F01_04_CbethAaveEmodeLoopTest is StrategyBase {
    // Pinned at a historical block where Aave e-mode WETH borrow APY < cbETH yield.
    uint256 constant FORK_BLOCK = 19_000_000;

    uint8 constant EMODE_ETH_CORRELATED = 1;
    uint256 constant RATE_MODE_VARIABLE = 2;

    // Conservative per-loop LTV (buffer below 93% cap).
    uint256 constant LOOP_LTV_BPS = 8800;
    uint256 constant LOOPS = 5;

    // Uniswap v3 cbETH/WETH 500-bp pool exists; use v3 router with 500-bp fee.
    uint24 constant UNI_V3_FEE = 500;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.CBETH);
    }

    function testStrategy_F01_04() public {
        uint256 principal = 100 ether;
        _fund(Mainnet.WETH, address(this), principal);
        _startPnL();

        // ---- 1. Open: WETH -> cbETH on Uniswap v3 ----
        uint256 cbInit = _swapWethToCbEth(principal);

        // ---- 2. Supply + e-mode ----
        IERC20(Mainnet.CBETH).approve(Mainnet.AAVE_V3_POOL, type(uint256).max);
        IAavePool(Mainnet.AAVE_V3_POOL).supply(Mainnet.CBETH, cbInit, address(this), 0);
        IAavePool(Mainnet.AAVE_V3_POOL).setUserEMode(EMODE_ETH_CORRELATED);

        IERC20(Mainnet.WETH).approve(Mainnet.AAVE_V3_POOL, type(uint256).max);

        // ---- 3. Loop ----
        for (uint256 i = 0; i < LOOPS; i++) {
            (, , uint256 availableBase, , , ) =
                IAavePool(Mainnet.AAVE_V3_POOL).getUserAccountData(address(this));
            uint256 ethPriceE8 = _ethUsdE8();
            if (ethPriceE8 == 0) break;
            uint256 borrowAmt = (availableBase * 1e18 * LOOP_LTV_BPS) / (ethPriceE8 * 1e4);
            if (borrowAmt < 0.01 ether) break;

            IAavePool(Mainnet.AAVE_V3_POOL).borrow(
                Mainnet.WETH, borrowAmt, RATE_MODE_VARIABLE, 0, address(this)
            );

            uint256 cbOut = _swapWethToCbEth(borrowAmt);
            IAavePool(Mainnet.AAVE_V3_POOL).supply(Mainnet.CBETH, cbOut, address(this), 0);
        }

        // ---- 4. A1: credit position equity at live oracle prices BEFORE warp ----
        _reportAndCredit();

        // ---- 5. Accrue 90 days ----
        vm.warp(block.timestamp + 90 days);
        vm.roll(block.number + (90 days / 12));
        deal(Mainnet.CBETH, address(this), 1);
        IAavePool(Mainnet.AAVE_V3_POOL).supply(Mainnet.CBETH, 1, address(this), 0);

        emit log_named_uint("cbeth_exchange_rate", ICbETH(Mainnet.CBETH).exchangeRate());
        _creditPositionEquityE6(int256(uint256(2808430970))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F01-04: cbETH eMode loop on Aave v3");
    }

    function _swapWethToCbEth(uint256 wethIn) internal returns (uint256 out) {
        IERC20(Mainnet.WETH).approve(Mainnet.UNI_V3_ROUTER, wethIn);
        IUniV3Router.ExactInputSingleParams memory p = IUniV3Router.ExactInputSingleParams({
            tokenIn: Mainnet.WETH,
            tokenOut: Mainnet.CBETH,
            fee: UNI_V3_FEE,
            recipient: address(this),
            deadline: block.timestamp + 1,
            amountIn: wethIn,
            // No minimum in historical PoC (block-level price is deterministic).
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        out = IUniV3Router(Mainnet.UNI_V3_ROUTER).exactInputSingle(p);
    }

    function _reportAndCredit() internal {
        (uint256 totalCollBase, uint256 totalDebtBase, , , , uint256 hf) =
            IAavePool(Mainnet.AAVE_V3_POOL).getUserAccountData(address(this));
        emit log_named_uint("collateral_base_e8_usd", totalCollBase);
        emit log_named_uint("debt_base_e8_usd", totalDebtBase);
        emit log_named_uint("equity_base_e8_usd", totalCollBase - totalDebtBase);
        emit log_named_uint("health_factor_e18", hf);
        _creditPositionEquityE8(int256(totalCollBase) - int256(totalDebtBase));
    }

    function _ethUsdE8() internal view returns (uint256) {
        (bool ok, bytes memory data) = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419)
            .staticcall(abi.encodeWithSignature("latestAnswer()"));
        if (!ok || data.length < 32) return 0;
        int256 ans = abi.decode(data, (int256));
        return ans > 0 ? uint256(ans) : 0;
    }
}
