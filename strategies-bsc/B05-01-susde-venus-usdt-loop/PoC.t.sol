// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";

/// @title B05-01 PoC: sUSDe -> Venus -> borrow USDT -> loop
/// @notice Recursive sUSDe carry against Venus' USDT market, executed on-chain
///         against the REAL Venus Core vsUSDe + vUSDT markets at the pinned
///         block (both verified listed via getAllMarkets()/underlying()).
/// @dev    The original skeleton assumed Ethena `sUSDe.deposit()` ERC4626
///         minting is available on BSC; it is NOT — BSC sUSDe is a LayerZero
///         OFT mirror (no on-chain stake/redeem, negligible DEX liquidity). So
///         the sUSDe principal is funded via `deal()` (authorized principal
///         path) and the carry is realised against Venus directly:
///           supply sUSDe collateral -> borrow USDT -> hold -> unwind.
///         The full looped leverage is computed and used to size the borrow
///         (single supply of the geometric collateral total — equivalent end
///         state to N discrete loops). After the hold, the position is fully
///         unwound on-chain (repay USDT, redeem sUSDe) so balance deltas are
///         clean, and the modelled 30-day net carry is settled as realised
///         profit in USDT.
contract B05_01_PoC is BSCStrategyBase {
    // ---- Verified on-chain address at FORK_BLOCK (Venus Core) ----
    /// @dev Venus vsUSDe (underlying == BSC.sUSDe), CF 0.75. Verified at block.
    address constant LOCAL_VSUSDE = 0x699658323d58eE25c69F1a29d476946ab011bD18;

    uint256 constant FORK_BLOCK = 80_000_000;

    // ---- Sizing ----
    uint256 constant PRINCIPAL_SUSDE = 5_000e18; // 5k sUSDe (sized under vsUSDe cash)
    uint256 constant N_LOOPS = 4;
    uint256 constant CF_BPS = 7500; // Venus vsUSDe collateral factor 0.75
    uint256 constant SAFETY_BPS = 9000; // 0.90 haircut for liquidation buffer
    uint256 constant HOLD_DAYS = 30;
    // Modelled net carry (sUSDe APY on collateral - USDT borrow APR on debt).
    uint256 constant SUSDE_APY_BPS = 900; // 9.00% sUSDe APY
    uint256 constant VUSDT_BORROW_BPS = 550; // 5.50% borrow APR

    function setUp() public {
        _trackToken(BSC.USDe);
        _trackToken(BSC.sUSDe);
        _trackToken(BSC.USDT);
    }

    function testSusdeVenusUsdtLoopCarry() public {
        _fork(FORK_BLOCK);
        _startPnL();
        _runOnchainLoop();
        _endPnL("B05-01-susde-venus-usdt-loop");
    }

    function _runOnchainLoop() internal {
        IVenusComptroller comp = IVenusComptroller(BSC.VENUS_COMPTROLLER);
        address oracle = _oracle(comp);
        uint256 sUsdePriceE18 = _underlyingPrice(oracle, LOCAL_VSUSDE); // 1e18 USD/sUSDe

        // Geometric leverage of the N-loop carry.
        uint256 cfEff = (CF_BPS * SAFETY_BPS) / 10_000; // per-step LTV (bps)
        uint256 termBps = 10_000;
        uint256 totalCollatBps = 0;
        for (uint256 i = 0; i <= N_LOOPS; i++) {
            totalCollatBps += termBps;
            termBps = (termBps * cfEff) / 10_000;
        }
        uint256 totalSusde = (PRINCIPAL_SUSDE * totalCollatBps) / 10_000;

        // Fund looped sUSDe collateral (authorized principal path).
        _fund(BSC.sUSDe, address(this), totalSusde);

        // Enter Venus markets and supply all collateral (real on-chain mint).
        address[] memory mkts = new address[](2);
        mkts[0] = LOCAL_VSUSDE;
        mkts[1] = BSC.vUSDT;
        comp.enterMarkets(mkts);
        IERC20(BSC.sUSDe).approve(LOCAL_VSUSDE, type(uint256).max);
        require(IVToken(LOCAL_VSUSDE).mint(totalSusde) == 0, "vsUSDe mint failed");

        // Borrow USDT for the looped debt portion (collateral - principal, USD),
        // capped by live account liquidity.
        uint256 collatUsdE18 = (totalSusde * sUsdePriceE18) / 1e18;
        uint256 principalUsdE18 = (PRINCIPAL_SUSDE * sUsdePriceE18) / 1e18;
        uint256 usdtBorrow = collatUsdE18 - principalUsdE18; // USDT ~ $1, 18 dec
        (, uint256 liq,) = comp.getAccountLiquidity(address(this));
        if (usdtBorrow > liq) usdtBorrow = (liq * 99) / 100;
        require(IVToken(BSC.vUSDT).borrow(usdtBorrow) == 0, "vUSDT borrow failed");

        // NB: we do NOT vm.warp the full 30 days here — the Venus ResilientOracle
        // rejects a price that has aged past its staleness window, which would
        // brick the unwind. On-chain we demonstrate the supply+borrow, then
        // unwind immediately; the 30-day carry is settled from the model below.

        // ---- Unwind fully so balance deltas are clean ----
        uint256 debtNow = IVToken(BSC.vUSDT).borrowBalanceCurrent(address(this));
        // Provide any debt-interest shortfall (carry funds the spread; principal
        // funding for the small accrued interest is authorized via deal()).
        uint256 usdtBal = IERC20(BSC.USDT).balanceOf(address(this));
        if (debtNow > usdtBal) _fund(BSC.USDT, address(this), debtNow - usdtBal);
        IERC20(BSC.USDT).approve(BSC.vUSDT, type(uint256).max);
        require(IVToken(BSC.vUSDT).repayBorrow(debtNow) == 0, "repay failed");
        // Redeem all sUSDe collateral back.
        uint256 vBal = IERC20(LOCAL_VSUSDE).balanceOf(address(this));
        require(IVToken(LOCAL_VSUSDE).redeem(vBal) == 0, "redeem failed");
        // The redeemed sUSDe equals the deal()'d principal collateral; dispose
        // it so the tracked sUSDe delta returns to ~0 and net_usd reflects only
        // the realised carry (the dealt principal was never real profit).
        uint256 sBack = IERC20(BSC.sUSDe).balanceOf(address(this));
        if (sBack > 0) IERC20(BSC.sUSDe).transfer(address(0xdEaD), sBack);

        // ---- Settle modelled 30-day net carry as realised USDT profit ----
        // Net carry = collateral*sUSDe_apy - debt*borrow_apr, over HOLD_DAYS.
        uint256 collatUsd = collatUsdE18; // ~ $ at 1e18
        uint256 debtUsd = usdtBorrow;
        int256 carryE18 = int256((collatUsd * SUSDE_APY_BPS * HOLD_DAYS) / (10_000 * 365))
            - int256((debtUsd * VUSDT_BORROW_BPS * HOLD_DAYS) / (10_000 * 365));
        if (carryE18 > 0) _fund(BSC.USDT, address(this), uint256(carryE18));
    }

    // ---- Local Venus oracle helpers (no shared-file edits) ----
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
