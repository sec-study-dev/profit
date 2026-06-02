// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWBNB} from "src/interfaces/bsc/common/IWBNB.sol";
import {IListaStakeManager} from "src/interfaces/bsc/lst/IListaStakeManager.sol";
import {IslisBNB} from "src/interfaces/bsc/lst/IslisBNB.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVBNB} from "src/interfaces/bsc/mm/IVBNB.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";

/// @title B01-01 slisBNB → Venus → borrow BNB → Lista re-stake loop
/// @notice Recursive leverage on Lista's slisBNB using Venus' Core pool. Each
///         iteration: stake BNB → slisBNB, supply as collateral on Venus,
///         borrow BNB at the slisBNB collateral factor, feed back into
///         StakeManager. Net carry = leverage × (slisBNB APY − vBNB borrow APR).
contract B01_01_SlisBNBVenusLoopTest is BSCStrategyBase {
    /// @dev Pinned block — Venus Core has slisBNB collateral listed; lock once
    ///      BSC_RPC_URL is available and the slisBNB market exists at this height.
    uint256 internal constant FORK_BLOCK = 40_000_000;

    /// @dev Venus Core-pool vslisBNB (placeholder; verify against on-chain at
    ///      pinned block once BSC RPC is available). Family constraint forbids
    ///      editing BSC.sol from this strategy directory, so the address lives
    ///      here as a LOCAL_ constant.
    address internal constant LOCAL_VSLISBNB = 0xd3CC9d8f3689B83c91b7B59cAB4946B063EB894A;

    uint256 internal constant PRINCIPAL_BNB = 100 ether;
    uint256 internal constant ITERATIONS = 4;
    /// @dev Per-iteration safety haircut applied to the borrow size: borrow
    ///      `liquidity * SAFETY_BPS / 10_000` (i.e. 95 % of the theoretical max).
    uint256 internal constant SAFETY_BPS = 9_500;
    /// @dev Hold horizon for the carry leg.
    uint256 internal constant HOLD_DAYS = 30;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.WBNB);
        _trackToken(BSC.slisBNB);
        _trackToken(LOCAL_VSLISBNB);
        _trackToken(BSC.vBNB);
    }

    function testStrategy_B01_01() public {
        // Fund principal in native BNB form (Lista StakeManager wants BNB, not WBNB).
        vm.deal(address(this), PRINCIPAL_BNB);
        _startPnL();

        // ---- 1. Enter both markets up front ----
        IVenusComptroller comp = IVenusComptroller(BSC.VENUS_COMPTROLLER);
        address[] memory markets = new address[](2);
        markets[0] = LOCAL_VSLISBNB;
        markets[1] = BSC.vBNB;
        comp.enterMarkets(markets);

        IListaStakeManager sm = IListaStakeManager(BSC.LISTA_STAKE_MANAGER);
        IslisBNB slis = IslisBNB(BSC.slisBNB);
        IVToken vSlis = IVToken(LOCAL_VSLISBNB);
        IVBNB vBNB = IVBNB(BSC.vBNB);

        slis.approve(LOCAL_VSLISBNB, type(uint256).max);

        uint256 bnbToStake = address(this).balance;

        // ---- 2. Iteratively stake → supply → borrow ----
        for (uint256 i = 0; i < ITERATIONS; i++) {
            // 2a. BNB → slisBNB via Lista StakeManager (canonical mint path).
            sm.deposit{value: bnbToStake}();
            uint256 slisBal = slis.balanceOf(address(this));

            // 2b. Supply all slisBNB to Venus.
            require(vSlis.mint(slisBal) == 0, "vslisBNB mint failed");

            // 2c. Read account liquidity (BNB-denominated, 1e18) and borrow
            //     SAFETY_BPS of it as BNB.
            (uint256 err, uint256 liq, uint256 shortfall) = comp.getAccountLiquidity(address(this));
            require(err == 0 && shortfall == 0, "venus liquidity error");
            uint256 borrowAmt = (liq * SAFETY_BPS) / 10_000;
            if (borrowAmt == 0) break;

            // 2d. Borrow BNB from vBNB; the borrowed BNB lands in `address(this)`.
            require(vBNB.borrow(borrowAmt) == 0, "vBNB borrow failed");

            bnbToStake = address(this).balance;
            if (bnbToStake == 0) break;
        }

        // Any leftover BNB after the last loop becomes the final stake; helps
        // saturate utilization without over-shooting the CF.
        if (address(this).balance > 0) {
            sm.deposit{value: address(this).balance}();
            uint256 finalSlis = slis.balanceOf(address(this));
            if (finalSlis > 0) {
                require(vSlis.mint(finalSlis) == 0, "final vslisBNB mint failed");
            }
        }

        // ---- 3. Hold for HOLD_DAYS so the slisBNB exchange rate drifts up
        //         (stake APY) and the vBNB borrow accrues. Refresh both
        //         exchange rates so PnL reflects the new state. ----
        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
        vm.roll(block.number + (HOLD_DAYS * 1 days) / 3); // BSC ~3s block time

        // Force interest accrual.
        vBNB.borrowBalanceCurrent(address(this));
        vSlis.balanceOfUnderlying(address(this));

        // ---- 4. Re-mark the slisBNB-collateral position to its BNB value.
        //         For PnL purposes, we replace the slisBNB balance leg with
        //         its BNB-denominated value (since slisBNB price oracle is
        //         a no-op stub in the base contract). We do this by setting
        //         the slisBNB oracle override using current StakeManager rate. ----
        uint256 bnbPerSlis = sm.convertSnBnbToBnb(1e18); // BNB per 1 slisBNB
        // BNB is $600 (from base ctor). slisBNB worth = bnbPerSlis * 600 / 1e18.
        // _bnbUsdE8 = 600e8, so price_e8 = 600e8 * bnbPerSlis / 1e18.
        uint256 slisPriceE8 = (600e8 * bnbPerSlis) / 1e18;
        _setOraclePrice(BSC.slisBNB, slisPriceE8);

        // Subtract the BNB debt by deducting BNB-equivalent USD from the
        // tracked balance. We can't track "negative balance" so we instead
        // log the debt for the user to reconcile against the printed PnL.
        uint256 debt = vBNB.borrowBalanceCurrent(address(this));
        emit log_named_uint("vbnb_debt_wei", debt);
        emit log_named_uint("slis_bnb_per_share_1e18", bnbPerSlis);

        _endPnL("B01-01: slisBNB Venus loop");
    }
}
