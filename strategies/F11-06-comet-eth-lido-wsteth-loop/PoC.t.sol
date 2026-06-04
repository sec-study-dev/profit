// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IComet} from "src/interfaces/mm/IComet.sol";
import {IStETH} from "src/interfaces/lst/IStETH.sol";
import {IWstETH} from "src/interfaces/lst/IWstETH.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";

/// @title F11-06 Compound v3 ETH Comet + Lido wstETH leverage loop
/// @notice Compound v3's ETH-base market (cWETHv3) accepts wstETH as
///         collateral. Loop wstETH collateral / WETH debt to harvest the
///         wstETH-staking-yield minus WETH-borrow-rate spread.
contract F11_06_CometEthLidoWstethLoopTest is StrategyBase {
    // Block where Comet ETH market is live with depth and wstETH is listed.
    // cWETHv3 launched Mar 2023; wstETH listed at deployment.
    uint256 internal constant FORK_BLOCK = 21_300_000;

    // Compound v3 ETH Comet (cWETHv3) mainnet.
    // verified at
    // https://etherscan.io/address/0xA17581A9E3356d9A858b789D68B4d866e593aE94
    address internal constant LOCAL_COMET_WETH = 0xA17581A9E3356d9A858b789D68B4d866e593aE94;

    // Per-loop LTV target. Comet wstETH has a borrow-collateral-factor of 90%;
    // we leave a buffer.
    uint256 internal constant LOOP_LTV_BPS = 8200;
    uint256 internal constant LOOPS = 4;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.STETH);
        _trackToken(Mainnet.WSTETH);
    }

    function testStrategy_F11_06() public {
        uint256 principal = 100 ether;
        _fund(Mainnet.WETH, address(this), principal);
        _startPnL();

        IComet comet = IComet(LOCAL_COMET_WETH);
        // Sanity: this Comet's base asset is WETH.
        assertEq(comet.baseToken(), Mainnet.WETH, "comet base not WETH");

        // ---- 1. Convert WETH -> stETH -> wstETH ----
        IWETH(Mainnet.WETH).withdraw(principal);
        uint256 stShares = IStETH(Mainnet.STETH).submit{value: principal}(address(0));
        require(stShares > 0, "lido submit");
        uint256 stBal = IERC20(Mainnet.STETH).balanceOf(address(this));
        IERC20(Mainnet.STETH).approve(Mainnet.WSTETH, type(uint256).max);
        uint256 wstOut = IWstETH(Mainnet.WSTETH).wrap(stBal);
        emit log_named_uint("initial_wsteth_collat_1e18", wstOut);

        // ---- 2. Supply wstETH as collateral, leveraged loop ----
        IERC20(Mainnet.WSTETH).approve(address(comet), type(uint256).max);
        IERC20(Mainnet.WETH).approve(address(comet), type(uint256).max);
        comet.supply(Mainnet.WSTETH, wstOut);

        // Curve stETH pool used to convert borrowed ETH -> stETH -> wstETH.
        for (uint256 i = 0; i < LOOPS; i++) {
            uint256 collat = uint256(comet.collateralBalanceOf(address(this), Mainnet.WSTETH));
            if (collat == 0) break;
            // Comet's ETH market uses 1e18 price scale internally; price of
            // wstETH/ETH is recorded via the protocol's oracle. For PoC we
            // approximate the headroom using Lido's on-chain conversion rate.
            uint256 ethEquiv = IWstETH(Mainnet.WSTETH).getStETHByWstETH(collat);
            uint256 currentDebt = comet.borrowBalanceOf(address(this));
            // Borrowable headroom (in WETH-equivalent ETH wei) at our LTV target.
            uint256 borrowable = (ethEquiv * LOOP_LTV_BPS) / 10_000;
            if (borrowable <= currentDebt) break;
            uint256 borrowAmt = borrowable - currentDebt;
            if (borrowAmt < 1e15) break;

            // Comet's `withdraw` of the base asset borrows when net principal
            // is negative.
            comet.withdraw(Mainnet.WETH, borrowAmt);

            // Convert borrowed WETH -> ETH -> stETH on Curve stETH pool.
            IWETH(Mainnet.WETH).withdraw(borrowAmt);
            uint256 stPre = IERC20(Mainnet.STETH).balanceOf(address(this));
            // Curve stETH/ETH pool: idx 0=ETH, idx 1=stETH.
            ICurveStableSwap(Mainnet.CURVE_STETH_POOL).exchange{value: borrowAmt}(
                int128(0), int128(1), borrowAmt, 0
            );
            uint256 stIn = IERC20(Mainnet.STETH).balanceOf(address(this)) - stPre;
            if (stIn == 0) break;
            uint256 wstIn = IWstETH(Mainnet.WSTETH).wrap(stIn);
            comet.supply(Mainnet.WSTETH, wstIn);
        }

        // ---- 3. A1: credit Comet position equity BEFORE warp ----
        _creditCometWethEquity(comet);

        // ---- 4. Hold 30 days to accrue: wstETH staking yield - WETH borrow rate
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));
        comet.accrueAccount(address(this));

        // ---- 5. Report ----
        uint128 finalColl = comet.collateralBalanceOf(address(this), Mainnet.WSTETH);
        uint256 finalDebt = comet.borrowBalanceOf(address(this));
        emit log_named_uint("final_wsteth_collat_1e18", uint256(finalColl));
        emit log_named_uint("final_weth_debt_1e18", finalDebt);
        emit log_named_uint("comet_util_e18", comet.getUtilization());
        emit log_named_uint("comet_borrow_rate_persec_e18", comet.getBorrowRate(comet.getUtilization()));

        // Equity in stETH-equivalent units.
        uint256 collEthEquiv = IWstETH(Mainnet.WSTETH).getStETHByWstETH(uint256(finalColl));
        int256 equityEth = int256(collEthEquiv) - int256(finalDebt);
        emit log_named_int("equity_eth_equiv_1e18", equityEth);

        assertGt(uint256(finalColl), wstOut, "loop did not increase collateral");
        assertGt(finalDebt, 0, "no debt opened");

        _endPnL("F11-06-comet-eth-lido-wsteth-loop");
    }

    function _creditCometWethEquity(IComet comet) internal {
        uint128 collat = comet.collateralBalanceOf(address(this), Mainnet.WSTETH);
        uint256 debt = comet.borrowBalanceOf(address(this)); // WETH 18-dec
        // wstETH USD value: stEthPerWstETH * ETH_USD / 1e18.
        uint256 stEthPerWst = IWstETH(Mainnet.WSTETH).getStETHByWstETH(uint256(collat));
        (bool ok, bytes memory data) = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419)
            .staticcall(abi.encodeWithSignature("latestAnswer()"));
        uint256 ethUsdE8_ = 3000e8;
        if (ok && data.length >= 32) { int256 ans = abi.decode(data, (int256)); if (ans > 0) ethUsdE8_ = uint256(ans); }
        // collat value in USD e6: stEthPerWst [e18] * ethUsdE8 [e8] / 1e18 / 1e8 * 1e6 = / 1e20.
        int256 collUsdE6 = int256((stEthPerWst * ethUsdE8_) / 1e20);
        // debt [e18 WETH] * ethUsdE8 [e8] / 1e20 = USD e6.
        int256 debtUsdE6 = int256((debt * ethUsdE8_) / 1e20);
        emit log_named_int("comet_equity_pre_warp_e6", collUsdE6 - debtUsdE6);
        _creditPositionEquityE6(collUsdE6 - debtUsdE6);
    }
}
