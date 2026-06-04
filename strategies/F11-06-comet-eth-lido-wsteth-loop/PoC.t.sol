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
import {IBalancerVault} from "src/interfaces/amm/IBalancerVault.sol";

/// @title F11-06 Compound v3 ETH Comet + Lido wstETH leverage loop (with unwind)
/// @notice Loop wstETH collateral / WETH debt to harvest staking yield minus borrow-rate
///         spread. After a 30-day warp, unwind via Balancer flash to surface net carry
///         in tracked WETH.
contract F11_06_CometEthLidoWstethLoopTest is StrategyBase {
    // Block where wstETH staking yield (~3.5% APR) > Comet WETH borrow (~2.2% APR).
    // cWETHv3 launched Mar 2023; wstETH listed at deployment.
    uint256 internal constant FORK_BLOCK = 21_300_000;

    // Compound v3 ETH Comet (cWETHv3) mainnet.
    // verified at https://etherscan.io/address/0xA17581A9E3356d9A858b789D68B4d866e593aE94
    address internal constant LOCAL_COMET_WETH = 0xA17581A9E3356d9A858b789D68B4d866e593aE94;

    // Per-loop LTV target. Comet wstETH has a borrow-collateral-factor of 90%;
    // we leave a buffer.
    uint256 internal constant LOOP_LTV_BPS = 8200;
    uint256 internal constant LOOPS = 4;

    // Balancer Vault (0-fee flash loans).
    address internal constant BAL_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    // State for flash callback
    uint256 internal _flashDebt;

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
            uint256 ethEquiv = IWstETH(Mainnet.WSTETH).getStETHByWstETH(collat);
            uint256 currentDebt = comet.borrowBalanceOf(address(this));
            uint256 borrowable = (ethEquiv * LOOP_LTV_BPS) / 10_000;
            if (borrowable <= currentDebt) break;
            uint256 borrowAmt = borrowable - currentDebt;
            if (borrowAmt < 1e15) break;

            comet.withdraw(Mainnet.WETH, borrowAmt);

            // Convert borrowed WETH -> ETH -> stETH on Curve stETH pool.
            IWETH(Mainnet.WETH).withdraw(borrowAmt);
            uint256 stPre = IERC20(Mainnet.STETH).balanceOf(address(this));
            ICurveStableSwap(Mainnet.CURVE_STETH_POOL).exchange{value: borrowAmt}(
                int128(0), int128(1), borrowAmt, 0
            );
            uint256 stIn = IERC20(Mainnet.STETH).balanceOf(address(this)) - stPre;
            if (stIn == 0) break;
            uint256 wstIn = IWstETH(Mainnet.WSTETH).wrap(stIn);
            comet.supply(Mainnet.WSTETH, wstIn);
        }

        // ---- 3. Hold 90 days to accrue: wstETH staking yield - WETH borrow rate
        // 90 days at ~3.5% wstETH APR vs ~2.2% WETH borrow = ~1.3% net on levered notional
        vm.warp(block.timestamp + 90 days);
        vm.roll(block.number + (90 days / 12));
        comet.accrueAccount(address(this));

        // ---- 4. Diagnostics before unwind ----
        uint128 finalColl = comet.collateralBalanceOf(address(this), Mainnet.WSTETH);
        uint256 finalDebt = comet.borrowBalanceOf(address(this));
        emit log_named_uint("final_wsteth_collat_1e18", uint256(finalColl));
        emit log_named_uint("final_weth_debt_1e18", finalDebt);
        emit log_named_uint("comet_borrow_rate_persec_e18", comet.getBorrowRate(comet.getUtilization()));

        uint256 collEthEquiv = IWstETH(Mainnet.WSTETH).getStETHByWstETH(uint256(finalColl));
        int256 equityEth = int256(collEthEquiv) - int256(finalDebt);
        emit log_named_int("equity_eth_equiv_1e18", equityEth);

        assertGt(uint256(finalColl), wstOut, "loop did not increase collateral");
        assertGt(finalDebt, 0, "no debt opened");

        // ---- 5. Unwind via Balancer 0-fee flash loan ----
        // Flash borrow enough WETH to repay Comet debt, then withdraw wstETH
        // collateral, convert to WETH, repay flash. Net WETH retained = carry profit.
        _flashDebt = finalDebt;

        address[] memory tokens = new address[](1);
        tokens[0] = Mainnet.WETH;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = finalDebt + 1; // slight buffer for rounding

        IBalancerVault(BAL_VAULT).flashLoan(
            address(this),
            tokens,
            amounts,
            abi.encode(uint256(finalColl))
        );

        _endPnL("F11-06-comet-eth-lido-wsteth-loop");
    }

    /// @notice Balancer flash loan callback.
    function receiveFlashLoan(
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata userData
    ) external {
        require(msg.sender == BAL_VAULT, "only balancer");
        require(tokens[0] == Mainnet.WETH, "token mismatch");
        require(feeAmounts[0] == 0, "nonzero fee");

        uint256 flashAmt = amounts[0];
        uint256 collAmt = abi.decode(userData, (uint256));

        IComet comet = IComet(LOCAL_COMET_WETH);

        // Repay WETH debt in Comet.
        IERC20(Mainnet.WETH).approve(address(comet), type(uint256).max);
        comet.supply(Mainnet.WETH, flashAmt);

        // Withdraw all wstETH collateral.
        comet.withdraw(Mainnet.WSTETH, collAmt);

        // Convert wstETH -> stETH -> ETH -> WETH.
        uint256 wstBal = IERC20(Mainnet.WSTETH).balanceOf(address(this));
        // Unwrap wstETH -> stETH.
        uint256 stOut = IWstETH(Mainnet.WSTETH).unwrap(wstBal);
        // stETH -> ETH via Curve (idx 1 -> 0).
        IERC20(Mainnet.STETH).approve(Mainnet.CURVE_STETH_POOL, stOut);
        uint256 ethOut = ICurveStableSwap(Mainnet.CURVE_STETH_POOL).exchange(
            int128(1), int128(0), stOut, 0
        );
        // ETH -> WETH.
        IWETH(Mainnet.WETH).deposit{value: ethOut}();

        // Repay Balancer flash.
        IERC20(Mainnet.WETH).transfer(BAL_VAULT, flashAmt);
    }

}
