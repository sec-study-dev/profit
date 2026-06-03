// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IStETH} from "src/interfaces/lst/IStETH.sol";
import {IWstETH} from "src/interfaces/lst/IWstETH.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IBalancerVault} from "src/interfaces/amm/IBalancerVault.sol";
import {IUniswapV3Pool} from "src/interfaces/amm/IUniswapV3Pool.sol";
import {IUniswapV3FlashCallback} from "src/interfaces/common/IFlashLoanReceiver.sol";

/// @title F03-04 Multi-LST triangular arb: Curve stETH -> wstETH wrap -> Balancer
/// @notice Flash WETH from UniV3 1bp pool (avoids Balancer vault reentrancy guard),
///         buy stETH cheap on Curve, wrap to wstETH, sell on Balancer, repay flash.
contract F03_04_TriangularLSTTest is StrategyBase, IUniswapV3FlashCallback {
    /// @dev Same pin as F03-01: post-Shanghai mild stETH discount on Curve.
    uint256 constant FORK_BLOCK = 17_560_000;

    /// @dev Balancer wstETH/wETH MetaStable pool.
    ///      Pool id (mainnet): wstETH/wETH MetaStable v3.
    bytes32 constant BAL_WSTETH_WETH_POOL_ID =
        0x32296969ef14eb0c6d29669c550d4a0449130230000200000000000000000080;

    /// @dev UniV3 wstETH/WETH 0.01% (fee tier 100) pool. token0=wstETH, token1=WETH.
    ///      Used as WETH flash source to avoid Balancer vault reentrancy.
    ///      Correct address verified via factory.getPool(wstETH, WETH, 100).
    address constant UNIV3_WSTETH_WETH_100 = 0x109830a1AAaD605BbF02a9dFA7B0B92EC2FB7dAa;

    uint256 constant FLASH_NOTIONAL = 500 ether;
    /// @dev WETH buffer to cover flash repayment shortfall (negative PnL is OK).
    uint256 constant REPAY_BUFFER = 2 ether;

    bool internal _flashActive;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.STETH);
        _trackToken(Mainnet.WSTETH);
    }

    function testStrategy_F03_04() public {
        // Pre-fund WETH buffer to cover any repayment shortfall (negative PnL is OK).
        _fund(Mainnet.WETH, address(this), REPAY_BUFFER);
        _startPnL();

        _flashActive = true;
        // Borrow token1 (WETH) from UniV3 1bp pool.
        IUniswapV3Pool(UNIV3_WSTETH_WETH_100).flash(address(this), 0, FLASH_NOTIONAL, "");
        _flashActive = false;

        _endPnL("F03-04: Triangular Curve stETH x wstETH wrap x Balancer");
    }

    function uniswapV3FlashCallback(
        uint256 /* fee0 */,
        uint256 fee1,
        bytes calldata /* data */
    ) external override {
        require(_flashActive, "callback: not active");
        require(msg.sender == UNIV3_WSTETH_WETH_100, "callback: wrong pool");

        // ---- 1. Unwrap WETH -> ETH ----
        IWETH(Mainnet.WETH).withdraw(FLASH_NOTIONAL);

        // ---- 2. Curve stETH/ETH: ETH (i=0) -> stETH (j=1) ----
        uint256 expectedStEth = ICurveStableSwap(Mainnet.CURVE_STETH_POOL).get_dy(
            0, 1, FLASH_NOTIONAL
        );
        uint256 minStEth = (expectedStEth * 999) / 1000;
        uint256 stEthOut = ICurveStableSwap(Mainnet.CURVE_STETH_POOL).exchange{value: FLASH_NOTIONAL}(
            int128(0), int128(1), FLASH_NOTIONAL, minStEth
        );
        // stETH is rebasing; use live balance to avoid rounding traps.
        uint256 stEthBal = IStETH(Mainnet.STETH).balanceOf(address(this));
        require(stEthBal + 2 >= stEthOut, "stETH: rebasing rounding");

        // ---- 3. Wrap stETH -> wstETH ----
        IStETH(Mainnet.STETH).approve(Mainnet.WSTETH, type(uint256).max);
        uint256 wstEthOut = IWstETH(Mainnet.WSTETH).wrap(stEthBal);
        require(wstEthOut > 0, "wstETH: wrap zero");

        // ---- 4. Balancer wstETH -> WETH ----
        IERC20(Mainnet.WSTETH).approve(Mainnet.BAL_VAULT, type(uint256).max);
        IBalancerVault.SingleSwap memory s = IBalancerVault.SingleSwap({
            poolId: BAL_WSTETH_WETH_POOL_ID,
            kind: IBalancerVault.SwapKind.GIVEN_IN,
            assetIn: Mainnet.WSTETH,
            assetOut: Mainnet.WETH,
            amount: wstEthOut,
            userData: ""
        });
        IBalancerVault.FundManagement memory fm = IBalancerVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });
        // Conservative lower bound - allow up to 10% adverse; triangle may be under-water.
        uint256 wethBack = IBalancerVault(Mainnet.BAL_VAULT).swap(
            s, fm, (FLASH_NOTIONAL * 90) / 100, block.timestamp
        );
        require(wethBack > 0, "balancer: zero out");

        // ---- 5. Repay UniV3 flash ----
        IERC20(Mainnet.WETH).transfer(UNIV3_WSTETH_WETH_100, FLASH_NOTIONAL + fee1);
    }
}
