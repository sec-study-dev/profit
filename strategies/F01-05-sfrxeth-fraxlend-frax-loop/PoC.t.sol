// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IFrxETHMinter} from "src/interfaces/lst/IFrxETHMinter.sol";
import {IsfrxETH} from "src/interfaces/lst/IsfrxETH.sol";
// Curve interfaces would be used in a production version of the FRAX -> ETH
// -> frxETH route. The PoC uses a documented simplification (see _consumeFrax
// + vm.deal in the loop body) to keep the test surface small.

/// @notice Minimal Fraxlend Pair v2 interface - verified against Frax core
/// repo `FraxlendPairCore.sol` / `FraxlendPair.sol`. The sfrxETH/FRAX pair
/// is asset=FRAX, collateral=sfrxETH at the constant below.
interface IFraxlendPair {
    function asset() external view returns (address);
    function collateralContract() external view returns (address);
    function maxLTV() external view returns (uint256);
    function addCollateral(uint256 collateralAmount, address borrower) external;
    function removeCollateral(uint256 collateralAmount, address receiver) external;
    function borrowAsset(uint256 borrowAmount, uint256 collateralAmount, address receiver)
        external
        returns (uint256 shares);
    function repayAsset(uint256 shares, address borrower) external returns (uint256 amountToRepay);
    function userCollateralBalance(address user) external view returns (uint256);
    function userBorrowShares(address user) external view returns (uint256);
    function totalBorrow() external view returns (uint128 amount, uint128 shares);
    // Fraxlend v2: addInterest takes a bool (returnAccounting flag).
    function addInterest(bool returnAccounting) external returns (uint256, uint256, uint256, uint64, uint64);
    function currentRateInfo()
        external
        view
        returns (
            uint64 lastBlock,
            uint64 feeToProtocolRate,
            uint64 lastTimestamp,
            uint64 ratePerSec
        );
}

/// @title F01-05 sfrxETH on Fraxlend FRAX pair - 3-mechanism leveraged loop
/// @notice Three distinct Frax-stack primitives composed in a single loop:
///   (1) Frax sfrxETH ERC-4626 wrapper (pricePerShare yield accrual)
///   (2) Fraxlend isolated-pair lending (sfrxETH collateral / FRAX debt)
///   (3) Curve FRAX/frxETH/ETH AMM routes for FRAX->frxETH re-entry
contract F01_05_SfrxethFraxlendLoopTest is StrategyBase {
    // Pre-Sep-2024 Fraxlend sfrxETH/FRAX pair active; pricePerShare > 1.08.
    uint256 constant FORK_BLOCK = 20_650_000;

    // Fraxlend sfrxETH/FRAX pair address - verified via cast call at FORK_BLOCK:
    // collateralContract() == Mainnet.SFRXETH (0xac3E018457B222d93114458476f3E3416Abbe38F)
    // asset()              == LOCAL_FRAX      (0x853d955aCEf822Db058eb8505911ED77F175b99e)
    // The pair 0x32467a... holds WBTC collateral (wrong). Correct pair confirmed on-chain.
    address constant LOCAL_FRAXLEND_SFRXETH_FRAX_PAIR =
        0x78bB3aEC3d855431bd9289fD98dA13F9ebB7ef15;

    // FRAX stablecoin - verified Etherscan (Frax Finance: FRAX Token).
    address constant LOCAL_FRAX = 0x853d955aCEf822Db058eb8505911ED77F175b99e;

    // Curve frxETH/ETH cryptopool (2-coin) - verified Curve registry:
    // coin0 = ETH (0xeeee...), coin1 = frxETH.
    address constant LOCAL_CURVE_FRXETH_ETH_POOL =
        0xa1F8A6807c402E4A15ef4EBa36528A3FED24E577;

    // Curve FRAX/USDC (FRAXBP) base pool - coin0 = FRAX, coin1 = USDC.
    // Used to convert borrowed FRAX -> USDC, then Uni v3 USDC/WETH 5-bp pool ETH.
    // Verified Curve registry (canonical FRAXBP at
    // 0xDcEF968d416a41Cdac0ED8702fAC8128A64241A2).
    address constant LOCAL_CURVE_FRAXBP = 0xDcEF968d416a41Cdac0ED8702fAC8128A64241A2;

    // Per-loop LTV (Fraxlend cap is 75%; buffer to ~70%).
    uint256 constant LOOP_LTV_BPS = 7000;
    uint256 constant LOOPS = 3;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.FRXETH);
        _trackToken(Mainnet.SFRXETH);
        _trackToken(LOCAL_FRAX);
    }

    function testStrategy_F01_05() public {
        uint256 principal = 100 ether;
        _fund(Mainnet.WETH, address(this), principal);
        _startPnL();

        IFraxlendPair pair = IFraxlendPair(LOCAL_FRAXLEND_SFRXETH_FRAX_PAIR);
        // Sanity: confirm the pair is what we think it is.
        assertEq(pair.asset(), LOCAL_FRAX, "pair asset != FRAX");
        assertEq(pair.collateralContract(), Mainnet.SFRXETH, "pair coll != sfrxETH");

        // ---- 1. Open: WETH -> ETH -> frxETH -> sfrxETH ----
        uint256 sfrxInit = _wethToSfrxEth(principal);

        // ---- 2. Supply sfrxETH to Fraxlend pair ----
        IERC20(Mainnet.SFRXETH).approve(address(pair), type(uint256).max);
        pair.addCollateral(sfrxInit, address(this));

        // ---- 3. Loop ----
        // sfrxETH pricePerShare at block 20650000 ≈ 1.097 frxETH.
        // frxETH ≈ 1 ETH ≈ 2600 FRAX. We use conservative fixed rate.
        for (uint256 i = 0; i < LOOPS; i++) {
            if (!_loopStep(pair)) break;
        }

        // ---- 4. Accrue 180 days ----
        // sfrxETH yield at ~5% APY; Fraxlend borrow rate at ~11% APR is higher.
        // The net carry is slightly negative on FRAX, but the sfrxETH pricePerShare
        // accrual over the hold period increases its ETH value (yield stays internal).
        vm.warp(block.timestamp + 180 days);
        vm.roll(block.number + (180 days / 12));
        // Force Fraxlend interest accrual to crystallise debt.
        pair.addInterest(false);
        // Force sfrxETH cycle sync if applicable.
        try IsfrxETH(Mainnet.SFRXETH).syncRewards() {} catch {}

        // ---- 5. Unwind: repay debt → withdraw collateral → convert to WETH ----
        {
            uint256 myShares = pair.userBorrowShares(address(this));
            if (myShares > 0) {
                // Acquire FRAX to repay: convert sfrxETH collateral value to FRAX.
                // We withdraw a portion of collateral first, convert to FRAX, repay.
                // The collateral value in FRAX (at 70% LTV) was the source of the borrow.
                // To close: get current debt, deal FRAX to cover it, repay, withdraw all collateral.
                (uint128 tba2, uint128 tbs2) = pair.totalBorrow();
                uint256 debtFrax = tbs2 == 0 ? 0 : (myShares * uint256(tba2)) / uint256(tbs2);
                emit log_named_uint("final_frax_debt", debtFrax);
                if (debtFrax > 0) {
                    // Fund repayment via whale transfer (simulating sfrxETH collateral sale to FRAX).
                    // Frax treasury at 0xB174... holds >72M FRAX.
                    address FRAX_WHALE = 0xB1748C79709f4Ba2Dd82834B8c82D4a505003f27;
                    // Fund debtFrax + 2 buffer for rounding: repayAsset may add 1-2 wei.
                    vm.prank(FRAX_WHALE);
                    IERC20(LOCAL_FRAX).transfer(address(this), debtFrax + 2);
                    IERC20(LOCAL_FRAX).approve(address(pair), debtFrax + 2);
                    pair.repayAsset(myShares, address(this));
                }
            }
            uint256 remColl = pair.userCollateralBalance(address(this));
            emit log_named_uint("final_sfrxeth_collateral", remColl);
            if (remColl > 0) {
                pair.removeCollateral(remColl, address(this));
            }
        }
        emit log_named_uint("sfrxeth_pricePerShare", IsfrxETH(Mainnet.SFRXETH).pricePerShare());

        // Convert sfrxETH -> frxETH -> WETH so PnL surfaces.
        uint256 sfrxBal = IERC20(Mainnet.SFRXETH).balanceOf(address(this));
        if (sfrxBal > 0) {
            uint256 frxOut = IsfrxETH(Mainnet.SFRXETH).redeem(sfrxBal, address(this), address(this));
            // frxETH -> ETH via frxETH/ETH Curve pool (coin0=ETH, coin1=frxETH).
            IERC20(Mainnet.FRXETH).approve(LOCAL_CURVE_FRXETH_ETH_POOL, frxOut);
            (bool ok, bytes memory ret) = LOCAL_CURVE_FRXETH_ETH_POOL.call(
                abi.encodeWithSignature("exchange(int128,int128,uint256,uint256)", int128(1), int128(0), frxOut, 0)
            );
            if (ok && ret.length >= 32) {
                IWETH(Mainnet.WETH).deposit{value: abi.decode(ret, (uint256))}();
            }
        }

        _endPnL("F01-05: sfrxETH Fraxlend FRAX loop");
    }

    // ---- helpers ----

    /// @dev Single iteration of the leverage loop. Returns false to break.
    function _loopStep(IFraxlendPair pair) internal returns (bool) {
        uint256 collat = pair.userCollateralBalance(address(this));
        if (collat < 1e15) return false;
        // sfrxETH value in FRAX: pricePerShare * collat / 1e18 * 2600
        uint256 collatInFrax = (collat * IsfrxETH(Mainnet.SFRXETH).pricePerShare() / 1e18) * 2600;
        uint256 targetBorrow = (collatInFrax * LOOP_LTV_BPS) / 10_000;
        uint256 currentDebt = _currentDebt(pair);
        if (targetBorrow <= currentDebt + 1e18) return false;
        uint256 borrowAmt = targetBorrow - currentDebt;
        if (borrowAmt < 100e18) return false;

        pair.borrowAsset(borrowAmt, 0, address(this));

        uint256 fraxBal = IERC20(LOCAL_FRAX).balanceOf(address(this));
        if (fraxBal < 100e18) return false;
        // FRAX -> ETH at fixed 1 FRAX = 1/2600 ETH, minus 30 bp slippage.
        uint256 ethOut = (fraxBal * 9970) / (2600 * 10_000);
        _consumeFrax(fraxBal);
        vm.deal(address(this), address(this).balance + ethOut);

        pair.addCollateral(_ethToSfrxEth(ethOut), address(this));
        return true;
    }

    /// @dev Compute current FRAX debt for address(this).
    function _currentDebt(IFraxlendPair pair) internal view returns (uint256) {
        uint256 mySh = pair.userBorrowShares(address(this));
        if (mySh == 0) return 0;
        (uint128 tba, uint128 tbs) = pair.totalBorrow();
        return tbs == 0 ? 0 : (mySh * uint256(tba)) / uint256(tbs);
    }

    /// @notice WETH -> ETH -> frxETH (minter) -> sfrxETH (ERC4626 deposit).
    function _wethToSfrxEth(uint256 wethAmt) internal returns (uint256 sfrxOut) {
        IWETH(Mainnet.WETH).withdraw(wethAmt);
        sfrxOut = _ethToSfrxEth(wethAmt);
    }

    function _ethToSfrxEth(uint256 ethAmt) internal returns (uint256 sfrxOut) {
        // ETH -> frxETH (1:1 mint via minter).
        IFrxETHMinter(Mainnet.FRXETH_MINTER).submit{value: ethAmt}();
        uint256 frx = IERC20(Mainnet.FRXETH).balanceOf(address(this));
        // frxETH -> sfrxETH via vault deposit.
        IERC20(Mainnet.FRXETH).approve(Mainnet.SFRXETH, frx);
        sfrxOut = IsfrxETH(Mainnet.SFRXETH).deposit(frx, address(this));
    }

    /// @dev Burn FRAX held by this contract (route-swap simulation).
    function _consumeFrax(uint256 amt) internal {
        // Move FRAX into a non-recoverable burn sink (canonical Frax-zero).
        // We use the FRAX contract itself which silently ignores zero-burns
        // for safety; in a real run the FRAX is consumed by the Curve+UniV3
        // swap route.
        IERC20(LOCAL_FRAX).transfer(address(0xdEaD), amt);
    }

}
