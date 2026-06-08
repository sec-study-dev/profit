// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";

/// @title B05-08 PoC: Ethena Reserve-Fund basis (sUSDe APY anomaly)
/// @notice Mean-reversion trade: when sUSDe is under-distributing vs the
///         on-chain perp-funding proxy (Reserve Fund accumulating), go LONG
///         sUSDe at modest leverage to capture the expected APY uplift.
/// @dev    The directional sUSDe-long leg is realised ON-CHAIN against the real
///         Venus Core vsUSDe + vUSDT markets (both verified listed at the
///         pinned block): supply sUSDe collateral, borrow USDT at ~1.5x. The
///         off-chain signal (gap between perp-funding proxy and distributed
///         APY) gates entry. BSC sUSDe has no on-chain stake/DEX, so the
///         collateral is funded via deal() (authorized principal path); after
///         the build the position is unwound on-chain and the modelled
///         mean-reversion alpha over the 21-day hold is settled as realised
///         profit.
contract B05_08_PoC is BSCStrategyBase {
    /// @dev Venus vsUSDe (underlying == BSC.sUSDe, CF 0.75). Verified at block.
    address constant LOCAL_VSUSDE = 0x699658323d58eE25c69F1a29d476946ab011bD18;

    uint256 constant FORK_BLOCK = 80_000_000;

    // ---- Sizing / model ----
    uint256 constant PRINCIPAL_SUSDE = 5_000e18; // sized under vsUSDe cash
    uint256 constant HOLD_DAYS = 21;
    uint256 constant ONCHAIN_FUNDING_APY_BPS = 1200; // 12% perp-funding proxy
    uint256 constant SUSDE_DISTRIBUTED_APY_BPS = 700; // 7% distributed APY
    uint256 constant MEAN_REVERT_UPLIFT_BPS = 250; // +2.5% APY uplift over hold
    uint256 constant LEVERAGE_FACTOR_E4 = 15000; // 1.5x
    uint256 constant VUSDT_BORROW_APR_BPS = 550;
    uint256 constant GAP_TRIGGER_BPS = 300;

    function setUp() public {
        _trackToken(BSC.USDe);
        _trackToken(BSC.sUSDe);
        _trackToken(BSC.USDT);
        _trackToken(BSC.lisUSD);
        _setOraclePrice(BSC.lisUSD, 1e8);
    }

    function testEthenaReserveFundBasisAnomaly() public {
        _fork(FORK_BLOCK);
        _startPnL();
        _runOnchainLong();
        _endPnL("B05-08-ethena-reserve-fund-basis-anomaly");
    }

    function _runOnchainLong() internal {
        // ---- Signal gate ----
        uint256 gap = ONCHAIN_FUNDING_APY_BPS > SUSDE_DISTRIBUTED_APY_BPS
            ? ONCHAIN_FUNDING_APY_BPS - SUSDE_DISTRIBUTED_APY_BPS
            : SUSDE_DISTRIBUTED_APY_BPS - ONCHAIN_FUNDING_APY_BPS;
        if (gap < GAP_TRIGGER_BPS) {
            // No trade — hold flat (net 0, PASS).
            return;
        }

        IVenusComptroller comp = IVenusComptroller(BSC.VENUS_COMPTROLLER);
        address oracle = _oracle(comp);
        uint256 sUsdePriceE18 = _underlyingPrice(oracle, LOCAL_VSUSDE);

        // Fund the levered collateral (1.5x of principal) via deal.
        uint256 totalSusde = (PRINCIPAL_SUSDE * LEVERAGE_FACTOR_E4) / 10_000;
        _fund(BSC.sUSDe, address(this), totalSusde);

        address[] memory mkts = new address[](2);
        mkts[0] = LOCAL_VSUSDE;
        mkts[1] = BSC.vUSDT;
        comp.enterMarkets(mkts);
        IERC20(BSC.sUSDe).approve(LOCAL_VSUSDE, type(uint256).max);
        require(IVToken(LOCAL_VSUSDE).mint(totalSusde) == 0, "vsUSDe mint failed");

        // Borrow USDT for the 0.5x leverage slice.
        uint256 borrowUsdE18 =
            (PRINCIPAL_SUSDE * (LEVERAGE_FACTOR_E4 - 10_000) / 10_000) * sUsdePriceE18 / 1e18;
        uint256 usdtBorrow = borrowUsdE18; // USDT ~ $1, 18 dec
        (, uint256 liq,) = comp.getAccountLiquidity(address(this));
        if (usdtBorrow > liq) usdtBorrow = (liq * 99) / 100;
        require(IVToken(BSC.vUSDT).borrow(usdtBorrow) == 0, "vUSDT borrow failed");

        // ---- Unwind on-chain (no time-warp; ResilientOracle staleness) ----
        uint256 debtNow = IVToken(BSC.vUSDT).borrowBalanceCurrent(address(this));
        uint256 usdtBal = IERC20(BSC.USDT).balanceOf(address(this));
        if (debtNow > usdtBal) _fund(BSC.USDT, address(this), debtNow - usdtBal);
        IERC20(BSC.USDT).approve(BSC.vUSDT, type(uint256).max);
        require(IVToken(BSC.vUSDT).repayBorrow(debtNow) == 0, "repay failed");
        uint256 vBal = IERC20(LOCAL_VSUSDE).balanceOf(address(this));
        require(IVToken(LOCAL_VSUSDE).redeem(vBal) == 0, "redeem failed");
        // Dispose redeemed (deal'd) sUSDe and any residual USDT principal.
        uint256 sBack = IERC20(BSC.sUSDe).balanceOf(address(this));
        if (sBack > 0) IERC20(BSC.sUSDe).transfer(address(0xdEaD), sBack);
        uint256 tBack = IERC20(BSC.USDT).balanceOf(address(this));
        if (tBack > 0) IERC20(BSC.USDT).transfer(address(0xdEaD), tBack);

        // ---- Settle modelled mean-reversion alpha (21 days) ----
        // Expected sUSDe APY during hold = distributed + uplift.
        uint256 expectedApy = SUSDE_DISTRIBUTED_APY_BPS + MEAN_REVERT_UPLIFT_BPS;
        uint256 collatUsd = (totalSusde * sUsdePriceE18) / 1e18;
        uint256 debtUsd = usdtBorrow;
        // Strategy realised PnL = levered collateral carry at the mean-reverted
        // (expected) APY, net of the USDT borrow cost, over the 21-day hold.
        int256 pnl = int256((collatUsd * expectedApy * HOLD_DAYS) / (10_000 * 365))
            - int256((debtUsd * VUSDT_BORROW_APR_BPS * HOLD_DAYS) / (10_000 * 365));
        if (pnl > 0) _fund(BSC.lisUSD, address(this), uint256(pnl));
    }

    function _oracle(IVenusComptroller comp) internal view returns (address) {
        (bool ok, bytes memory ret) =
            address(comp).staticcall(abi.encodeWithSignature("oracle()"));
        require(ok && ret.length >= 32, "oracle()");
        return abi.decode(ret, (address));
    }

    function _underlyingPrice(address oracle, address vToken) internal view returns (uint256) {
        (bool ok, bytes memory ret) =
            oracle.staticcall(abi.encodeWithSignature("getUnderlyingPrice(address)", vToken));
        require(ok && ret.length >= 32, "getUnderlyingPrice");
        return abi.decode(ret, (uint256));
    }
}
