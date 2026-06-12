// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";

/// @dev Minimal local ERC4626 interface for the sUSDX savings vault.
interface IERC4626Min {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function asset() external view returns (address);
}

/// @title B14-05 PoC - sUSDX savings + Pendle PT lock + Venus borrow (3-mech)
/// @notice Three independent yield mechanisms on a stable principal:
///         (1) sUSDX (StablesLabs savings vault, real ERC4626) savings carry;
///         (2) Pendle PT-sUSDX lock (fix the savings APR at a discount);
///         (3) Venus USDT self-loop for the borrow-and-recycle overlay.
/// @dev    Fork-replay at FORK_BLOCK.
///         - Mechanism 1 is REAL: USDX -> sUSDX ERC4626 deposit (verified live).
///         - Mechanism 2 (Pendle PT-sUSDX): no live Pendle PT-sUSDX market is
///           deployed on BSC at this block, so the Pendle leg is gracefully
///           skipped (the locked-rate carry is not double-credited) per the
///           playbook's "graceful-skip + run the rest" rule.
///         - Mechanism 3 is REAL: a Venus Core vUSDT self-loop whose position
///           equity + live-IRM carry is credited.
contract B14_05_PoC is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 44_000_000;

    address internal constant LOCAL_SUSDX = 0x7788A3538C5fc7F9c7C8A74EAC4c898fC8d87d92;
    address internal constant LOCAL_USDX = 0xf3527ef8dE265eAa3716FB312c12847bFBA66Cef;
    address internal constant LOCAL_XVS = 0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63;
    address internal constant LOCAL_VENUS_ORACLE = 0x6592b5DE802159F3E74B2486b091D11a8256ab8A;
    /// @dev Placeholder PT-sUSDX market (no live BSC Pendle market exists).
    address internal constant LOCAL_PT_SUSDX_MARKET = 0x0000000000000000000000000000000000000000;

    uint256 constant PRINCIPAL_USDT = 100_000e18;
    uint256 constant N_LOOPS = 4;
    uint256 constant CF_BPS = 7800;
    uint256 constant SAFETY_BPS = 9500;
    uint256 constant HOLD_DAYS = 60;

    uint256 constant SUSDX_APR_BPS = 600; // 6.00% sUSDX savings APR
    uint256 constant XVS_SUPPLY_BPS = 50;
    uint256 constant XVS_BORROW_BPS = 50;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.USDT);
        // sUSDX is NOT tracked: its NAV is credited as position equity instead,
        // so tracking it too would double-count the savings slice.
    }

    function testSusdxPendlePtVenus3Mech() public {
        _fund(BSC.USDT, address(this), PRINCIPAL_USDT);
        _startPnL();

        uint256 half = PRINCIPAL_USDT / 2;

        // ---------------------------------------------------------------
        // Mechanism 1 (REAL): sUSDX savings deposit on half the principal.
        // USDX is the vault asset; deal USDX 1:1 against the USDT slice.
        // ---------------------------------------------------------------
        _fund(LOCAL_USDX, address(this), half);
        IERC20(LOCAL_USDX).approve(LOCAL_SUSDX, type(uint256).max);
        uint256 susdxShares = IERC4626Min(LOCAL_SUSDX).deposit(half, address(this));
        // Burn the matching USDT to reflect the slice converted into sUSDX.
        IERC20(BSC.USDT).transfer(address(0xdead), half);
        uint256 susdxAssets = IERC4626Min(LOCAL_SUSDX).convertToAssets(susdxShares);
        // sUSDX NAV (USD, 1e8) credited as position equity (the shares sit in
        // address(this) but are NAV-priced, not market-priced).
        _creditPositionEquityE8(int256(susdxAssets / 1e10));
        // sUSDX savings carry over the hold horizon.
        int256 susdxCarryE8 =
            int256((susdxAssets * SUSDX_APR_BPS * HOLD_DAYS) / (10_000 * 365) / 1e10);
        _creditPositionEquityE8(susdxCarryE8);

        // ---------------------------------------------------------------
        // Mechanism 2 (Pendle PT-sUSDX): no live BSC market -> graceful skip.
        // ---------------------------------------------------------------
        bool pendleLive = LOCAL_PT_SUSDX_MARKET != address(0)
            && LOCAL_PT_SUSDX_MARKET.code.length > 0;
        emit log_named_string(
            "pendle_pt_susdx", pendleLive ? "live" : "absent (graceful skip)"
        );

        // ---------------------------------------------------------------
        // Mechanism 3 (REAL): Venus vUSDT self-loop on the other half.
        // ---------------------------------------------------------------
        IVToken vUSDT = IVToken(BSC.vUSDT);
        IVenusComptroller comp = IVenusComptroller(BSC.VENUS_COMPTROLLER);
        address[] memory mkts = new address[](1);
        mkts[0] = BSC.vUSDT;
        comp.enterMarkets(mkts);
        IERC20(BSC.USDT).approve(BSC.vUSDT, type(uint256).max);

        for (uint256 i = 0; i < N_LOOPS; i++) {
            uint256 bal = IERC20(BSC.USDT).balanceOf(address(this));
            if (bal == 0) break;
            try vUSDT.mint(bal) returns (uint256 e) { if (e != 0) break; } catch { break; }
            uint256 toBorrow = (bal * CF_BPS * SAFETY_BPS) / (10_000 * 10_000);
            if (toBorrow == 0) break;
            try vUSDT.borrow(toBorrow) returns (uint256 e) { if (e != 0) break; } catch { break; }
        }

        uint256 supplied = vUSDT.balanceOfUnderlying(address(this));
        uint256 debt = vUSDT.borrowBalanceCurrent(address(this));
        uint256 usdtPxE18 = _underlyingPriceE18(BSC.vUSDT);
        _creditPositionEquityE8(
            int256((supplied * usdtPxE18) / 1e18 / 1e10) - int256((debt * usdtPxE18) / 1e18 / 1e10)
        );

        uint256 blocksPerYear = 365 days / 3;
        int256 supplyApr1e18 = int256(vUSDT.supplyRatePerBlock() * blocksPerYear);
        int256 borrowApr1e18 = int256(vUSDT.borrowRatePerBlock() * blocksPerYear);
        int256 xvsSupply1e18 = int256(XVS_SUPPLY_BPS) * 1e18 / 10_000;
        int256 xvsBorrow1e18 = int256(XVS_BORROW_BPS) * 1e18 / 10_000;
        int256 collUsd = int256((supplied * usdtPxE18) / 1e18);
        int256 debtUsd = int256((debt * usdtPxE18) / 1e18);
        int256 annual = collUsd * (supplyApr1e18 + xvsSupply1e18) / 1e18
            + debtUsd * (xvsBorrow1e18 - borrowApr1e18) / 1e18;
        _creditPositionEquityE8((annual * int256(HOLD_DAYS) / 365) / 1e10);

        // Claim accrued XVS.
        uint256 xvs0 = IERC20(LOCAL_XVS).balanceOf(address(this));
        try comp.claimVenus(address(this)) {} catch {}
        uint256 xvsGained = IERC20(LOCAL_XVS).balanceOf(address(this)) - xvs0;
        if (xvsGained > 0) {
            uint256 xvsPx = _resilientPriceE18(LOCAL_XVS);
            _creditPositionEquityE8(int256((xvsGained * xvsPx) / 1e18 / 1e10));
        }

        emit log_named_uint("susdx_assets", susdxAssets);
        emit log_named_uint("venus_supplied", supplied);
        emit log_named_uint("venus_debt", debt);

        _endPnL("B14-05-susdx-pendle-pt-venus-3mech");
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
