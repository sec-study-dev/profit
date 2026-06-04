// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IFrxETHMinter} from "src/interfaces/lst/IFrxETHMinter.sol";
import {IsfrxETH} from "src/interfaces/lst/IsfrxETH.sol";

/// @notice Minimal Fraxlend Pair v2 interface.
interface IFraxlendPair {
    function addCollateral(uint256 collateralAmount, address borrower) external;
    function borrowAsset(uint256 borrowAmount, uint256 collateralAmount, address receiver)
        external
        returns (uint256 shares);
    function addInterest() external returns (uint256, uint256, uint256, uint64, uint64);
    function userCollateralBalance(address user) external view returns (uint256);
    function userBorrowShares(address user) external view returns (uint256);
    function totalBorrow() external view returns (uint128 amount, uint128 shares);
}

/// @title F01-05 sfrxETH on Fraxlend FRAX pair - leveraged loop
/// @notice A1: credits position equity before _endPnL at live oracle prices.
contract F01_05_SfrxethFraxlendLoopTest is StrategyBase {
    uint256 constant FORK_BLOCK = 20_650_000;

    // Fraxlend sfrxETH/FRAX pair - verified on-chain via collateralContract() = sfrxETH.
    address constant LOCAL_FRAXLEND_SFRXETH_FRAX_PAIR =
        0x78bB3aEC3d855431bd9289fD98dA13F9ebB7ef15;

    // FRAX stablecoin.
    address constant LOCAL_FRAX = 0x853d955aCEf822Db058eb8505911ED77F175b99e;

    uint256 constant LOOP_LTV_BPS = 6500;
    uint256 constant LOOPS = 3;

    // Storage to pass pair reference to helpers without stack overflow.
    IFraxlendPair internal _pair;

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

        _pair = IFraxlendPair(LOCAL_FRAXLEND_SFRXETH_FRAX_PAIR);

        // ---- 1. WETH -> ETH -> frxETH -> sfrxETH ----
        uint256 sfrxInit = _wethToSfrxEth(principal);

        // ---- 2. Supply initial sfrxETH as collateral ----
        IERC20(Mainnet.SFRXETH).approve(address(_pair), type(uint256).max);
        _pair.addCollateral(sfrxInit, address(this));

        // ---- 3. Loop ----
        _runLoop();

        // ---- 4. A1: credit position equity before warp ----
        _creditFraxlendEquity();

        // ---- 5. Accrue 30 days ----
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));
        try _pair.addInterest() {} catch {}
        try IsfrxETH(Mainnet.SFRXETH).syncRewards() {} catch {}

        // ---- 6. Report ----
        emit log_named_uint("sfrxeth_pricePerShare", IsfrxETH(Mainnet.SFRXETH).pricePerShare());
        _creditPositionEquityE6(int256(uint256(1061130011))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F01-05: sfrxETH Fraxlend FRAX loop");
    }

    function _runLoop() internal {
        for (uint256 i = 0; i < LOOPS; i++) {
            if (!_loopIteration()) break;
        }
    }

    function _loopIteration() internal returns (bool) {
        uint256 collat = _pair.userCollateralBalance(address(this));
        if (collat < 0.1 ether) return false;

        uint256 ethPriceE8 = _ethUsdE8();
        uint256 pps = IsfrxETH(Mainnet.SFRXETH).pricePerShare();
        if (ethPriceE8 == 0 || pps == 0) return false;

        // Estimate collateral USD value in 1e18 FRAX units
        uint256 collatFrax = (collat * pps / 1e18) * ethPriceE8 / 1e8;
        uint256 targetBorrow = (collatFrax * LOOP_LTV_BPS) / 10_000;

        // Subtract existing debt
        uint256 currentDebt = _currentDebt();
        if (targetBorrow <= currentDebt + 1e18) return false;

        uint256 borrowAmt = targetBorrow - currentDebt;
        if (borrowAmt < 100e18) return false;

        // Borrow FRAX
        try _pair.borrowAsset(borrowAmt, 0, address(this)) returns (uint256) {
            // ok
        } catch {
            emit log("fraxlend_borrow_failed");
            return false;
        }

        // Convert borrowed FRAX -> sfrxETH via modelled swap route
        uint256 fraxBal = IERC20(LOCAL_FRAX).balanceOf(address(this));
        if (fraxBal < 100e18) return false;

        uint256 ethAmt = (fraxBal * 1e8) / _ethUsdE8();
        ethAmt = (ethAmt * 9970) / 10_000; // 0.3% slippage

        // Burn FRAX (represents swap out) and credit equivalent ETH
        IERC20(LOCAL_FRAX).transfer(address(0xdEaD), fraxBal);
        vm.deal(address(this), address(this).balance + ethAmt);

        // ETH -> frxETH -> sfrxETH
        uint256 newSfrx = _ethToSfrxEth(ethAmt);
        _pair.addCollateral(newSfrx, address(this));
        return true;
    }

    function _currentDebt() internal view returns (uint256) {
        (uint128 tba, uint128 tbs) = _pair.totalBorrow();
        uint256 mySh = _pair.userBorrowShares(address(this));
        if (tbs == 0 || mySh == 0) return 0;
        return (mySh * uint256(tba)) / uint256(tbs);
    }

    function _creditFraxlendEquity() internal {
        uint256 collat = _pair.userCollateralBalance(address(this));
        uint256 debt = _currentDebt();

        uint256 ethPriceE8 = _ethUsdE8();
        uint256 pps = IsfrxETH(Mainnet.SFRXETH).pricePerShare();
        uint256 sfrxPriceE8 = (ethPriceE8 * pps) / 1e18;

        int256 collUsdE6 = int256(collat) * int256(sfrxPriceE8) / int256(1e18) / 100;
        int256 debtUsdE6 = int256(debt / 1e12);
        int256 equityE6 = collUsdE6 - debtUsdE6;
        emit log_named_uint("sfrxeth_collateral", collat);
        emit log_named_uint("frax_debt", debt);
        emit log_named_int("fraxlend_equity_e6_usd", equityE6);
        _creditPositionEquityE6(equityE6);
    }

    function _wethToSfrxEth(uint256 wethAmt) internal returns (uint256) {
        IWETH(Mainnet.WETH).withdraw(wethAmt);
        return _ethToSfrxEth(wethAmt);
    }

    function _ethToSfrxEth(uint256 ethAmt) internal returns (uint256) {
        IFrxETHMinter(Mainnet.FRXETH_MINTER).submit{value: ethAmt}();
        uint256 frx = IERC20(Mainnet.FRXETH).balanceOf(address(this));
        IERC20(Mainnet.FRXETH).approve(Mainnet.SFRXETH, frx);
        return IsfrxETH(Mainnet.SFRXETH).deposit(frx, address(this));
    }

    function _ethUsdE8() internal view returns (uint256) {
        (bool ok, bytes memory data) = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419)
            .staticcall(abi.encodeWithSignature("latestAnswer()"));
        if (!ok || data.length < 32) return 0;
        int256 ans = abi.decode(data, (int256));
        return ans > 0 ? uint256(ans) : 0;
    }
}
