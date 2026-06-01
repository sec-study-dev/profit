// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVBNB} from "src/interfaces/bsc/mm/IVBNB.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {IListaStakeManager} from "src/interfaces/bsc/lst/IListaStakeManager.sol";
import {IslisBNB} from "src/interfaces/bsc/lst/IslisBNB.sol";

/// @title B06-03 Venus LST isolated pool — slisBNB high-LTV loop
/// @notice Same recursive shape as B01-01, but routed through the LST
///         isolated-pool Comptroller (higher CF for slisBNB → higher
///         effective leverage → wider stake-vs-borrow spread). Differential
///         payoff vs B01-01 is the family edge.
contract B06_03_VenusLSTPoolSlisBNBLoopTest is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 42_500_000;

    // ---- Inlined LST-pool addresses ----
    address internal constant LOCAL_LST_COMPTROLLER = 0x596B11acAACF03217287939f88d63b51d3771704;
    /// @notice LST-pool vslisBNB. TODO verify at pinned block.
    address internal constant LOCAL_VSLISBNB_LST = 0xd3CC9d8f3689B83c91b7B59cAB4946B063EB894A;
    /// @notice LST-pool vBNB. TODO verify at pinned block.
    address internal constant LOCAL_VBNB_LST = 0x0F0E3C29e7AE3f0F9B8c2e1F0E3C29E7ae3F0f9b;

    uint256 internal constant PRINCIPAL_BNB = 100 ether;
    uint256 internal constant ITERATIONS = 4;
    uint256 internal constant SAFETY_BPS = 9_500;
    uint256 internal constant HOLD_DAYS = 30;
    uint256 internal constant SECS_PER_BLOCK = 3;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.WBNB);
        _trackToken(LOCAL_VSLISBNB_LST);
        _trackToken(LOCAL_VBNB_LST);
    }

    function testStrategy_B06_03() public {
        vm.deal(address(this), PRINCIPAL_BNB);
        _startPnL();

        // ---- 1. Enter both LST-pool markets ----
        IVenusComptroller comp = IVenusComptroller(LOCAL_LST_COMPTROLLER);
        address[] memory mk = new address[](2);
        mk[0] = LOCAL_VSLISBNB_LST;
        mk[1] = LOCAL_VBNB_LST;
        comp.enterMarkets(mk);

        IListaStakeManager sm = IListaStakeManager(BSC.LISTA_STAKE_MANAGER);
        IslisBNB slis = IslisBNB(BSC.slisBNB);
        IVToken vSlis = IVToken(LOCAL_VSLISBNB_LST);
        IVBNB vBNB = IVBNB(LOCAL_VBNB_LST);

        slis.approve(LOCAL_VSLISBNB_LST, type(uint256).max);

        uint256 bnbToStake = address(this).balance;

        // ---- 2. Iteratively stake → supply → borrow ----
        for (uint256 i = 0; i < ITERATIONS; i++) {
            // 2a. BNB → slisBNB.
            sm.deposit{value: bnbToStake}();
            uint256 slisBal = slis.balanceOf(address(this));

            // 2b. Supply to LST-pool vslisBNB.
            require(vSlis.mint(slisBal) == 0, "vslis_lst mint failed");

            // 2c. Borrow from LST-pool vBNB up to SAFETY_BPS of liquidity.
            (uint256 err, uint256 liq, uint256 shortfall) = comp.getAccountLiquidity(address(this));
            require(err == 0 && shortfall == 0, "lst liquidity err");
            uint256 borrowAmt = (liq * SAFETY_BPS) / 10_000;
            if (borrowAmt == 0) break;

            // Clamp to available cash so the borrow doesn't revert in a
            // shallow market.
            uint256 cash = vBNB.getCash();
            if (borrowAmt > cash) borrowAmt = (cash * 90) / 100;
            if (borrowAmt == 0) break;

            require(vBNB.borrow(borrowAmt) == 0, "vbnb_lst borrow failed");

            bnbToStake = address(this).balance;
            if (bnbToStake == 0) break;
        }

        // Final dust → slisBNB → supply (saturate but don't borrow).
        if (address(this).balance > 0) {
            sm.deposit{value: address(this).balance}();
            uint256 finalSlis = slis.balanceOf(address(this));
            if (finalSlis > 0) {
                require(vSlis.mint(finalSlis) == 0, "final vslis_lst mint failed");
            }
        }

        // ---- 3. Hold 30 days ----
        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
        vm.roll(block.number + (HOLD_DAYS * 1 days) / SECS_PER_BLOCK);

        // Force accrual on both sides.
        vBNB.borrowBalanceCurrent(address(this));
        vSlis.balanceOfUnderlying(address(this));

        // ---- 4. Mark slisBNB to BNB-denominated USD using StakeManager ----
        uint256 bnbPerSlis = sm.convertSnBnbToBnb(1e18);
        uint256 slisPriceE8 = (600e8 * bnbPerSlis) / 1e18;
        _setOraclePrice(BSC.slisBNB, slisPriceE8);

        uint256 debt = vBNB.borrowBalanceCurrent(address(this));
        emit log_named_uint("vbnb_lst_debt_wei", debt);
        emit log_named_uint("slis_bnb_per_share_1e18", bnbPerSlis);

        _endPnL("B06-03: Venus LST pool slisBNB high-LTV loop");
    }
}
