// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWBNB} from "src/interfaces/bsc/common/IWBNB.sol";
import {IankrBNB} from "src/interfaces/bsc/lst/IankrBNB.sol";
import {IListaLending} from "src/interfaces/bsc/mm/IListaLending.sol";

/// @notice Minimal Ankr BinancePool mint surface.
///         `stakeAndClaimCerts{value}()` mints ankrBNB at the current ratio
///         and credits the caller with the share token.
interface IAnkrBinancePool {
    function stakeAndClaimCerts() external payable;
}

/// @title B01-03 ankrBNB → Lista Lending → borrow BNB → Ankr re-stake loop
/// @notice Venue-diversified leveraged staking: Ankr BNB LST stacked on
///         Lista's lending market (instead of Venus) to escape Core-pool
///         IRM crowding. Same recursive shape as B01-01 / B01-02.
contract B01_03_AnkrBNBListaLendingLoopTest is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 41_000_000;

    /// @dev Ankr BinancePool (BNB → ankrBNB mint). Verify on-chain at FORK_BLOCK.
    address internal constant LOCAL_ANKR_BINANCE_POOL = 0x9e347Af362059bf2E55839002c699F7A5BaFE86E;

    /// @dev Lista Lending pool. Mirrors BSC.LISTA_LENDING (currently a
    ///      TODO-verify placeholder). Inline here so the strategy can be
    ///      pinned independently of BSC.sol updates.
    address internal constant LOCAL_LISTA_LENDING = 0xAa0F8C41E3DC22a8C4d4Da6Da1A1caF048D7e4B5;

    uint256 internal constant PRINCIPAL_BNB = 100 ether;
    uint256 internal constant ITERATIONS = 4;
    uint256 internal constant SAFETY_BPS = 9_500;
    uint256 internal constant HOLD_DAYS = 30;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.WBNB);
        _trackToken(BSC.ankrBNB);
    }

    function testStrategy_B01_03() public {
        vm.deal(address(this), PRINCIPAL_BNB);
        _startPnL();

        IAnkrBinancePool ankr = IAnkrBinancePool(LOCAL_ANKR_BINANCE_POOL);
        IankrBNB ank = IankrBNB(BSC.ankrBNB);
        IListaLending lending = IListaLending(LOCAL_LISTA_LENDING);
        IWBNB wbnb = IWBNB(BSC.WBNB);

        ank.approve(LOCAL_LISTA_LENDING, type(uint256).max);
        wbnb.approve(LOCAL_LISTA_LENDING, type(uint256).max);

        uint256 bnbToStake = address(this).balance;

        for (uint256 i = 0; i < ITERATIONS; i++) {
            // 1. BNB → ankrBNB via Ankr's mint path.
            ankr.stakeAndClaimCerts{value: bnbToStake}();
            uint256 ankBal = ank.balanceOf(address(this));

            // 2. Supply ankrBNB to Lista Lending.
            lending.supply(BSC.ankrBNB, ankBal, address(this));

            // 3. Read account data and borrow WBNB at SAFETY_BPS of available.
            //    `availableBorrowsBase` is in the pool's reserve currency (USD
            //    1e8). Convert to BNB amount via $600/BNB so the loop math is
            //    self-contained on the offline fork.
            (, , uint256 availBase, , , ) = lending.getUserAccountData(address(this));
            // availBase is 1e8 USD; BNB amount = availBase / 600 * 1e10 (wei).
            uint256 borrowBnb = (availBase * 1e10) / 600;
            borrowBnb = (borrowBnb * SAFETY_BPS) / 10_000;
            if (borrowBnb == 0) break;

            lending.borrow(BSC.WBNB, borrowBnb, address(this));

            // 4. Unwrap WBNB so the next iteration can mint via Ankr.
            uint256 wbnbBal = IERC20(BSC.WBNB).balanceOf(address(this));
            if (wbnbBal == 0) break;
            wbnb.withdraw(wbnbBal);
            bnbToStake = address(this).balance;
            if (bnbToStake == 0) break;
        }

        if (address(this).balance > 0) {
            ankr.stakeAndClaimCerts{value: address(this).balance}();
            uint256 finalAnk = ank.balanceOf(address(this));
            if (finalAnk > 0) {
                lending.supply(BSC.ankrBNB, finalAnk, address(this));
            }
        }

        // Hold 30 days; let both legs accrue.
        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
        vm.roll(block.number + (HOLD_DAYS * 1 days) / 3);

        // Re-mark ankrBNB price by Ankr ratio so PnL captures the drift.
        uint256 bnbPerAnk = ank.ratio(); // BNB per 1 ankrBNB, 1e18
        uint256 ankPriceE8 = (600e8 * bnbPerAnk) / 1e18;
        _setOraclePrice(BSC.ankrBNB, ankPriceE8);

        (, uint256 debtBase, , , , uint256 hf) = lending.getUserAccountData(address(this));
        emit log_named_uint("lista_debt_base_1e8", debtBase);
        emit log_named_uint("lista_health_factor_1e18", hf);
        emit log_named_uint("ankr_ratio_1e18", bnbPerAnk);

        _endPnL("B01-03: ankrBNB Lista loop");
    }
}
