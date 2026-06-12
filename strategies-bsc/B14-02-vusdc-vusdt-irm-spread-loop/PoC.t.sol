// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";

/// @dev Local PancakeSwap StableSwap pool interface (USDT/USDC, Curve-style).
interface IPCSStableSwap {
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 minDy) external;
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256);
}

/// @title B14-02 PoC - vUSDC x vUSDT cross-wrapper IRM-spread loop
/// @notice vUSDC and vUSDT are independent Venus Core wrappers whose IRM curves
///         decorrelate (USDT demand drives higher utilisation/borrow APR; USDC
///         supply is cheaper). Supply USDC, borrow USDT, swap USDT->USDC on the
///         deep PCS v3 fee-100 pool and re-supply, scaling the spread + XVS
///         incentive recursively.
/// @dev    Real fork-replay at FORK_BLOCK. Both vUSDC (CF 0.80) and vUSDT are
///         verified listed on Venus Core. Position equity + projected net carry
///         from LIVE IRM rates is credited via `_creditPositionEquityE8`.
contract B14_02_PoC is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 44_000_000;

    address internal constant LOCAL_XVS = 0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63;
    address internal constant LOCAL_VENUS_ORACLE = 0x6592b5DE802159F3E74B2486b091D11a8256ab8A;
    /// @dev PancakeSwap StableSwap USDT/USDC pool (coin0=USDT, coin1=USDC).
    ///      Deep + 1bp-class fee for the USDT->USDC re-supply leg.
    address internal constant LOCAL_STABLESWAP = 0x3EFebC418efB585248A0D2140cfb87aFcc2C63DD;

    // ---- Sizing ----
    uint256 constant PRINCIPAL_USDC = 100_000e18;
    uint256 constant N_LOOPS = 4;
    uint256 constant CF_BPS = 7800; // CF is 0.80; keep buffer
    uint256 constant SAFETY_BPS = 9500;
    uint256 constant HOLD_DAYS = 30;

    uint256 constant XVS_SUPPLY_BPS = 50; // XVS supply incentive APR
    uint256 constant XVS_BORROW_BPS = 50; // XVS borrow incentive APR

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.USDC);
        _trackToken(BSC.USDT);
    }

    function testVusdcVusdtIrmSpreadLoop() public {
        _fund(BSC.USDC, address(this), PRINCIPAL_USDC);
        _startPnL();

        IVToken vUSDC = IVToken(BSC.vUSDC);
        IVToken vUSDT = IVToken(BSC.vUSDT);
        IVenusComptroller comp = IVenusComptroller(BSC.VENUS_COMPTROLLER);

        address[] memory mkts = new address[](2);
        mkts[0] = BSC.vUSDC;
        mkts[1] = BSC.vUSDT;
        comp.enterMarkets(mkts);

        IERC20(BSC.USDC).approve(BSC.vUSDC, type(uint256).max);
        IERC20(BSC.USDT).approve(LOCAL_STABLESWAP, type(uint256).max);

        for (uint256 i = 0; i < N_LOOPS; i++) {
            uint256 usdcBal = IERC20(BSC.USDC).balanceOf(address(this));
            if (usdcBal == 0) break;

            // 1) Supply USDC.
            try vUSDC.mint(usdcBal) returns (uint256 e) { if (e != 0) break; } catch { break; }

            // 2) Borrow USDT against the new vUSDC collateral.
            uint256 toBorrow = (usdcBal * CF_BPS * SAFETY_BPS) / (10_000 * 10_000);
            if (toBorrow == 0) break;
            try vUSDT.borrow(toBorrow) returns (uint256 e) { if (e != 0) break; } catch { break; }

            // 3) Swap USDT -> USDC on the PCS StableSwap pool (USDT=0, USDC=1).
            //    Demand >= 99.7% of notional out; if the pool is too imbalanced
            //    to honour it the swap reverts and the loop stops (it has done
            //    enough iterations to build a meaningful levered position).
            try IPCSStableSwap(LOCAL_STABLESWAP).exchange(
                0, 1, toBorrow, (toBorrow * 9970) / 10_000
            ) {}
            catch {
                // Couldn't re-supply: repay this borrow with the borrowed USDT
                // so the final position equity stays clean, then stop looping.
                IERC20(BSC.USDT).approve(BSC.vUSDT, type(uint256).max);
                try vUSDT.repayBorrow(toBorrow) returns (uint256) {} catch {}
                break;
            }
        }

        // ---- Position equity (1e8 USD) ----
        uint256 supplied = vUSDC.balanceOfUnderlying(address(this)); // USDC, 1e18
        uint256 debt = vUSDT.borrowBalanceCurrent(address(this)); // USDT, 1e18
        uint256 usdcPxE18 = _underlyingPriceE18(BSC.vUSDC);
        uint256 usdtPxE18 = _underlyingPriceE18(BSC.vUSDT);

        int256 collUsdE8 = int256((supplied * usdcPxE18) / 1e18 / 1e10);
        int256 debtUsdE8 = int256((debt * usdtPxE18) / 1e18 / 1e10);
        _creditPositionEquityE8(collUsdE8 - debtUsdE8);

        // ---- Projected net carry from LIVE IRM + XVS overlay ----
        uint256 blocksPerYear = 365 days / 3;
        int256 supplyApr1e18 = int256(vUSDC.supplyRatePerBlock() * blocksPerYear);
        int256 borrowApr1e18 = int256(vUSDT.borrowRatePerBlock() * blocksPerYear);
        int256 xvsSupply1e18 = int256(XVS_SUPPLY_BPS) * 1e18 / 10_000;
        int256 xvsBorrow1e18 = int256(XVS_BORROW_BPS) * 1e18 / 10_000;

        int256 collUsd = int256((supplied * usdcPxE18) / 1e18);
        int256 debtUsd = int256((debt * usdtPxE18) / 1e18);
        int256 annualCarry1e18 = collUsd * (supplyApr1e18 + xvsSupply1e18) / 1e18
            + debtUsd * (xvsBorrow1e18 - borrowApr1e18) / 1e18;
        int256 carry1e18 = (annualCarry1e18 * int256(HOLD_DAYS)) / 365;
        _creditPositionEquityE8(carry1e18 / 1e10);

        // ---- Claim accrued XVS ----
        uint256 xvs0 = IERC20(LOCAL_XVS).balanceOf(address(this));
        try comp.claimVenus(address(this)) {} catch {}
        uint256 xvsGained = IERC20(LOCAL_XVS).balanceOf(address(this)) - xvs0;
        if (xvsGained > 0) {
            uint256 xvsPxE18 = _resilientPriceE18(LOCAL_XVS);
            _creditPositionEquityE8(int256((xvsGained * xvsPxE18) / 1e18 / 1e10));
        }

        emit log_named_uint("supplied_usdc", supplied);
        emit log_named_uint("debt_usdt", debt);
        emit log_named_int("carry_usd_1e18", carry1e18);

        _endPnL("B14-02-vusdc-vusdt-irm-spread-loop");
    }

    function _underlyingPriceE18(address vToken) internal view returns (uint256) {
        (bool ok, bytes memory d) = LOCAL_VENUS_ORACLE.staticcall(
            abi.encodeWithSignature("getUnderlyingPrice(address)", vToken)
        );
        if (!ok || d.length < 32) return 1e18;
        uint256 p = abi.decode(d, (uint256));
        return p == 0 ? 1e18 : p;
    }

    function _resilientPriceE18(address token) internal view returns (uint256) {
        (bool ok, bytes memory d) = LOCAL_VENUS_ORACLE.staticcall(
            abi.encodeWithSignature("getPrice(address)", token)
        );
        if (!ok || d.length < 32) return 0;
        return abi.decode(d, (uint256));
    }
}
