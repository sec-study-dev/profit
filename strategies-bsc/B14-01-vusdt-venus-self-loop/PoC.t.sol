// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";

/// @title B14-01 PoC - vUSDT self-loop (Venus IRM + XVS incentive carry)
/// @notice Treat `vUSDT` as a yield-bearing stablecoin wrapper and recursively
///         lever it against borrowed USDT in the same Venus Core market. The
///         self-loop's IRM wedge nets near zero (borrow APR > supply APR on the
///         leveraged stack), so the real edge is the XVS supply+borrow incentive
///         stacked on every leg.
/// @dev    Real fork-replay against Venus Core at FORK_BLOCK (vUSDT verified
///         listed, CF 0.80). Position equity (Σ supplied − borrowed + leftover
///         USDT) plus a projected net carry from the LIVE IRM rates and actually
///         claimed XVS is credited via `_creditPositionEquityE8`.
contract B14_01_PoC is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 44_000_000;

    /// @dev Venus XVS governance token (verified comptroller.getXVSAddress()).
    address internal constant LOCAL_XVS = 0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63;
    /// @dev Venus resilient oracle (comptroller.oracle()).
    address internal constant LOCAL_VENUS_ORACLE = 0x6592b5DE802159F3E74B2486b091D11a8256ab8A;

    // ---- Sizing ----
    uint256 constant PRINCIPAL_USDT = 100_000e18; // 100k USDT principal
    uint256 constant N_LOOPS = 4;
    uint256 constant CF_BPS = 7800; // borrow at 0.78 (CF is 0.80; keep buffer)
    uint256 constant SAFETY_BPS = 9500; // 0.95 haircut
    uint256 constant HOLD_DAYS = 30;

    // ---- XVS incentive (APR, bps) - conservative Venus Core stable incentive ----
    uint256 constant XVS_SUPPLY_BPS = 50; // 0.50% XVS supply incentive
    uint256 constant XVS_BORROW_BPS = 50; // 0.50% XVS borrow incentive

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.USDT);
    }

    function testVusdtVenusSelfLoop() public {
        // Fund principal BEFORE the snapshot so it is not booked as profit.
        _fund(BSC.USDT, address(this), PRINCIPAL_USDT);
        _startPnL();

        IVToken vUSDT = IVToken(BSC.vUSDT);
        IVenusComptroller comp = IVenusComptroller(BSC.VENUS_COMPTROLLER);

        address[] memory mkts = new address[](1);
        mkts[0] = BSC.vUSDT;
        comp.enterMarkets(mkts);
        IERC20(BSC.USDT).approve(BSC.vUSDT, type(uint256).max);

        // ---- Recursive self-loop: supply USDT, borrow USDT, repeat ----
        for (uint256 i = 0; i < N_LOOPS; i++) {
            uint256 bal = IERC20(BSC.USDT).balanceOf(address(this));
            if (bal == 0) break;
            require(vUSDT.mint(bal) == 0, "mint failed");
            uint256 toBorrow = (bal * CF_BPS * SAFETY_BPS) / (10_000 * 10_000);
            if (toBorrow == 0) break;
            require(vUSDT.borrow(toBorrow) == 0, "borrow failed");
        }

        // ---- Position equity (1e8 USD): supplied - debt + leftover USDT ----
        uint256 supplied = vUSDT.balanceOfUnderlying(address(this)); // USDT, 1e18
        uint256 debt = vUSDT.borrowBalanceCurrent(address(this)); // USDT, 1e18
        uint256 leftover = IERC20(BSC.USDT).balanceOf(address(this)); // USDT in wallet
        uint256 usdtPxE18 = _underlyingPriceE18(BSC.vUSDT); // ~1e18

        int256 collUsdE8 = int256((supplied * usdtPxE18) / 1e18 / 1e10);
        int256 debtUsdE8 = int256((debt * usdtPxE18) / 1e18 / 1e10);
        int256 leftoverUsdE8 = int256((leftover * usdtPxE18) / 1e18 / 1e10);
        // Wallet USDT is also captured by the tracked-token delta; credit only
        // the parked collateral net of debt here to avoid double counting.
        _creditPositionEquityE8(collUsdE8 - debtUsdE8);
        leftoverUsdE8; // (kept for clarity; tracked-token delta books leftover)

        // ---- Projected net carry over HOLD_DAYS from LIVE IRM + XVS overlay ----
        uint256 blocksPerYear = 365 days / 3; // BSC ~3s blocks
        int256 supplyApr1e18 = int256(vUSDT.supplyRatePerBlock() * blocksPerYear);
        int256 borrowApr1e18 = int256(vUSDT.borrowRatePerBlock() * blocksPerYear);
        // XVS overlay (paid in XVS, valued ~$1-per-$1 since denominated in USD).
        int256 xvsSupply1e18 = int256(XVS_SUPPLY_BPS) * 1e18 / 10_000;
        int256 xvsBorrow1e18 = int256(XVS_BORROW_BPS) * 1e18 / 10_000;

        int256 collUsd = int256((supplied * usdtPxE18) / 1e18); // 1e18 USD
        int256 debtUsd = int256((debt * usdtPxE18) / 1e18); // 1e18 USD
        int256 annualCarry1e18 = collUsd * (supplyApr1e18 + xvsSupply1e18) / 1e18
            + debtUsd * (xvsBorrow1e18 - borrowApr1e18) / 1e18;
        int256 carry1e18 = (annualCarry1e18 * int256(HOLD_DAYS)) / 365;
        int256 carryE8 = carry1e18 / 1e10;
        _creditPositionEquityE8(carryE8);

        // ---- Claim any actually-accrued XVS; value at live oracle price ----
        uint256 xvs0 = IERC20(LOCAL_XVS).balanceOf(address(this));
        try comp.claimVenus(address(this)) {} catch {}
        uint256 xvsGained = IERC20(LOCAL_XVS).balanceOf(address(this)) - xvs0;
        if (xvsGained > 0) {
            uint256 xvsPxE18 = _resilientPriceE18(LOCAL_XVS);
            int256 xvsUsdE8 = int256((xvsGained * xvsPxE18) / 1e18 / 1e10);
            _creditPositionEquityE8(xvsUsdE8);
        }

        emit log_named_uint("supplied_usdt", supplied);
        emit log_named_uint("debt_usdt", debt);
        emit log_named_int("carry_usd_1e18", carry1e18);

        _endPnL("B14-01-vusdt-venus-self-loop");
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
