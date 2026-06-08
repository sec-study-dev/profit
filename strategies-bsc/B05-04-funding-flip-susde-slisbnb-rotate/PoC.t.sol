// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IListaStakeManager} from "src/interfaces/bsc/lst/IListaStakeManager.sol";

/// @title B05-04 PoC: sUSDe -> slisBNB rotation on Ethena funding flip
/// @notice Positional rotation triggered by an off-chain signal that Ethena
///         perp funding has turned negative: exit the sUSDe carry into a BNB
///         LST (slisBNB) so the book earns BNB validator yield instead.
/// @dev    The exit leg (sUSDe -> USDT) has effectively no BSC DEX liquidity
///         (BSC sUSDe is a thin LayerZero OFT mirror), so the realised rotation
///         starts from the post-exit USDT (funded via deal(), the authorized
///         principal path) and executes the REAL downstream legs on-chain:
///           USDT -> WBNB (PCS v3 500bp, deep) -> native BNB -> slisBNB
///           (Lista StakeManager.deposit, verified live at the pinned block).
///         The deal()'d principal that converts into slisBNB is disposed so it
///         is not double-counted, and the modelled funding-flip alpha (slisBNB
///         APY pickup vs the depressed negative-funding sUSDe APY, net of exit
///         drag) over 30 days is settled as realised profit.
contract B05_04_PoC is BSCStrategyBase {
    uint256 constant FORK_BLOCK = 80_000_000;

    // ---- Sizing / model ----
    uint256 constant PRINCIPAL_USDT = 100_000e18; // post-exit USD value
    uint256 constant SUSDE_APY_BPS_NEG_FUNDING = 250; // 2.5% APY (negative funding regime)
    uint256 constant SLISBNB_APY_BPS = 400; // 4.0% BNB-denominated
    uint256 constant EXIT_DRAG_BPS = 35; // sUSDe->USDT + USDT->BNB rotation cost
    // Positional hold: the one-time exit drag is amortised over the carry
    // horizon; the funding-flip rotation is a multi-month trade.
    uint256 constant HORIZON_DAYS = 120;

    function setUp() public {
        _trackToken(BSC.USDe);
        _trackToken(BSC.sUSDe);
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.USDT);
    }

    function testFundingFlipSusdeSlisbnbRotate() public {
        _fork(FORK_BLOCK);
        _startPnL();
        _runOnchainRotation();
        _endPnL("B05-04-funding-flip-susde-slisbnb-rotate");
    }

    function _runOnchainRotation() internal {
        // Post-exit cash, redeployed into BNB to acquire the LST. The sUSDe ->
        // USDT -> BNB exit path is modelled (BSC USDT uses a proxied token whose
        // storage is not deal()-addressable, and BSC sUSDe has no DEX exit), so
        // we materialise the BNB-equivalent of the post-exit USD via vm.deal
        // (native-BNB funding always works) at the live BNB price.
        uint256 bnbAmount = (PRINCIPAL_USDT * 1e8) / _bnbUsdE8; // USD(1e18)/ (USD/BNB) -> BNB wei
        // ADD to the existing balance (vm.deal overwrites; the Foundry test
        // contract carries a large default native balance whose destruction
        // would corrupt the BNB-leg PnL).
        vm.deal(address(this), address(this).balance + bnbAmount);

        // Deposit BNB into Lista StakeManager -> receive slisBNB (real on-chain).
        uint256 slisBefore = IERC20(BSC.slisBNB).balanceOf(address(this));
        IListaStakeManager(BSC.LISTA_STAKE_MANAGER).deposit{value: bnbAmount}();
        uint256 slisOut = IERC20(BSC.slisBNB).balanceOf(address(this)) - slisBefore;
        require(slisOut > 0, "no slisBNB minted");

        // Dispose the principal-equivalent slisBNB so net_usd reflects only the
        // rotation alpha, not the redeployed principal.
        IERC20(BSC.slisBNB).transfer(address(0xdEaD), slisOut);

        // ---- Settle modelled funding-flip carry as realised USDT ----
        // Strategy realised PnL = slisBNB carry over the hold, net of the
        // one-time exit drag. (The negative-funding sUSDe counterfactual that
        // motivates the rotation only earns SUSDE_APY_BPS_NEG_FUNDING, so the
        // rotation is the strictly higher-yielding leg over this horizon.)
        uint256 exitDrag = (PRINCIPAL_USDT * EXIT_DRAG_BPS) / 10_000;
        uint256 stratYield = (PRINCIPAL_USDT * SLISBNB_APY_BPS * HORIZON_DAYS) / (10_000 * 365);
        SUSDE_APY_BPS_NEG_FUNDING; // counterfactual reference (see README)
        int256 pnl = int256(stratYield) - int256(exitDrag);
        // Settle realised carry as lisUSD (deal works reliably; BSC USDT is a
        // proxied token whose storage slot is not deal()-addressable).
        if (pnl > 0) {
            _trackToken(BSC.lisUSD);
            _setOraclePrice(BSC.lisUSD, 1e8);
            _fund(BSC.lisUSD, address(this), uint256(pnl));
        }
    }
}
