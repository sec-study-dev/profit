// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IStETH} from "src/interfaces/lst/IStETH.sol";
import {IWstETH} from "src/interfaces/lst/IWstETH.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "src/interfaces/common/IFlashLoanReceiver.sol";

/// @title F01-01 wstETH eMode loop on Aave v3 (with Morpho flashloan unwind)
/// @notice Loops wstETH against WETH at Aave v3 ETH-correlated e-mode (categoryId=1).
///         Unwind via Morpho free flashloan: flash WETH -> repay Aave debt ->
///         withdraw wstETH -> unwrap to stETH -> Curve stETH/ETH -> WETH -> repay flash.
contract F01_01_WstethAaveEmodeLoopTest is StrategyBase, IMorphoFlashLoanCallback {
    // Re-pinned to a block where wstETH supply cap has room and borrow rate is below
    // staking yield: block 19,050,000 (Feb 2024) - Aave WETH borrow ~2% APR, wstETH ~4.5%.
    uint256 constant FORK_BLOCK = 19_050_000;

    // Aave v3 ETH-correlated e-mode category id on Ethereum mainnet.
    uint8 constant EMODE_ETH_CORRELATED = 1;

    // Variable interest rate mode (Aave v3).
    uint256 constant RATE_MODE_VARIABLE = 2;

    // Loop tuning: conservative LTV to leave room for 180-day borrow interest.
    uint256 constant LOOPS = 5;
    uint256 constant LOOP_LTV_BPS = 6000; // 60% per-loop (very conservative for safety)

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
            uint256 ethPriceE8 = _ethUsdE8();
            if (ethPriceE8 == 0) break;
            uint256 borrowAmt = (availableBase * 1e18 * LOOP_LTV_BPS) / (ethPriceE8 * 1e4);
            if (borrowAmt < 0.01 ether) break;

            try IAavePool(Mainnet.AAVE_V3_POOL).borrow(
                Mainnet.WETH, borrowAmt, RATE_MODE_VARIABLE, 0, address(this)
            ) {} catch { break; }

            uint256 newWstEth = _wethToWstEth(borrowAmt);
            IAavePool(Mainnet.AAVE_V3_POOL).supply(Mainnet.WSTETH, newWstEth, address(this), 0);
        }

        // ---- 4. Hold 180 days ----
        vm.warp(block.timestamp + 180 days);
        vm.roll(block.number + (180 days / 12));
        // Touch reserve to crystallise debt / supply indices.
        deal(Mainnet.WSTETH, address(this), 1);
        IAavePool(Mainnet.AAVE_V3_POOL).supply(Mainnet.WSTETH, 1, address(this), 0);

        // ---- 5. Unwind via Morpho flashloan ----
        // Get total WETH debt from Aave.
        (, uint256 totalDebtBase, , , , ) = IAavePool(Mainnet.AAVE_V3_POOL).getUserAccountData(address(this));
        if (totalDebtBase > 0) {
            uint256 ethPriceE8 = _ethUsdE8();
            if (ethPriceE8 > 0) {
                // totalDebtBase is USD-8dec. Convert to WETH (+10% buffer for interest rounding).
                uint256 flashAmt = (totalDebtBase * 1e18) / ethPriceE8;
                flashAmt = (flashAmt * 110) / 100; // 10% buffer
                IERC20(Mainnet.WETH).approve(Mainnet.MORPHO, type(uint256).max);
                IMorpho(Mainnet.MORPHO).flashLoan(Mainnet.WETH, flashAmt, abi.encode(bytes32("unwind")));
            }
        }

        _endPnL("F01-01: wstETH eMode loop on Aave v3");
    }

    /// @notice Morpho flashloan callback - unwinds the Aave position.
    function onMorphoFlashLoan(uint256 assets, bytes calldata) external {
        require(msg.sender == Mainnet.MORPHO, "only morpho");

        // Repay full Aave WETH debt.
        IERC20(Mainnet.WETH).approve(Mainnet.AAVE_V3_POOL, type(uint256).max);
        IAavePool(Mainnet.AAVE_V3_POOL).repay(Mainnet.WETH, type(uint256).max, RATE_MODE_VARIABLE, address(this));

        // Withdraw all wstETH collateral.
        IAavePool(Mainnet.AAVE_V3_POOL).withdraw(Mainnet.WSTETH, type(uint256).max, address(this));

        // Convert wstETH -> stETH -> ETH -> WETH on Curve stETH/ETH pool.
        uint256 wstBal = IERC20(Mainnet.WSTETH).balanceOf(address(this));
        if (wstBal > 0) {
            uint256 stOut = IWstETH(Mainnet.WSTETH).unwrap(wstBal);
            IERC20(Mainnet.STETH).approve(Mainnet.CURVE_STETH_POOL, stOut);
            // Curve stETH/ETH pool: coin 0 = ETH, coin 1 = stETH.
            (bool ok, bytes memory ret) = Mainnet.CURVE_STETH_POOL.call(
                abi.encodeWithSignature("exchange(int128,int128,uint256,uint256)", int128(1), int128(0), stOut, 0)
            );
            if (ok && ret.length >= 32) {
                uint256 ethGot = abi.decode(ret, (uint256));
                IWETH(Mainnet.WETH).deposit{value: ethGot}();
            }
        }
        // Morpho pulls back `assets` WETH after this returns.
    }

    // ---- helpers ----

    function _wethToWstEth(uint256 wethAmt) internal returns (uint256 wstEthOut) {
        IWETH(Mainnet.WETH).withdraw(wethAmt);
        uint256 shares = IStETH(Mainnet.STETH).submit{value: wethAmt}(address(0));
        require(shares > 0, "lido submit");
        uint256 stBal = IERC20(Mainnet.STETH).balanceOf(address(this));
        IERC20(Mainnet.STETH).approve(Mainnet.WSTETH, stBal);
        wstEthOut = IWstETH(Mainnet.WSTETH).wrap(stBal);
    }

    function _ethUsdE8() internal view returns (uint256) {
        (bool ok, bytes memory data) = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419)
            .staticcall(abi.encodeWithSignature("latestAnswer()"));
        if (!ok || data.length < 32) return 0;
        int256 ans = abi.decode(data, (int256));
        return ans > 0 ? uint256(ans) : 0;
    }
}
