// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IBNBx} from "src/interfaces/bsc/lst/IBNBx.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVBNB} from "src/interfaces/bsc/mm/IVBNB.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";

/// @notice Minimal Stader StakeManager surface for the BNB -> BNBx mint path.
///         Stader's manager accepts native BNB via `deposit()` payable, mints
///         BNBx at the current exchange rate, and credits the depositor.
interface IStaderStakeManager {
    function deposit() external payable;
    function getExchangeRate() external view returns (uint256);
}

/// @title B01-02 BNBx -> Venus isolated pool -> borrow BNB -> Stader re-stake loop
/// @notice Same recursive shape as B01-01 but on Stader BNBx in a Venus V4
///         isolated pool. Discriminator: cheaper borrow cost from the
///         isolated-pool IRM.
contract B01_02_BNBxVenusStaderLoopTest is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 40_500_000;

    /// @dev Stader BNB X StakeManager (V2). Inline placeholder - verify on-chain.
    address internal constant LOCAL_STADER_STAKE_MANAGER = 0x7276241a669489E4BBB76f63d2A43Bfe63080F2F;

    /// @dev Stader BNBx ERC20. Mirrors BSC.BNBx but inlined here because the
    ///      BSC.sol constant currently fails EIP-55 checksum validation
    ///      (BSC.sol is owned by the BSC-address-book maintainer; this PoC
    ///      cannot edit it per family constraints).
    address internal constant LOCAL_BNBX = 0x1BDD3CF7F79cFB8edbb955F20aD99211044f6AE4;

    /// @dev Venus V4 isolated-pool Comptroller for the BNBx-collateral market.
    ///      Placeholder; refine once isolated-pool address book is published.
    address internal constant LOCAL_VBNBX_COMPTROLLER = 0x3344417c9360b963ca93A4e8305361AEde340Ab9;

    /// @dev Venus vBNBx market token (Compound v2 fork interface).
    address internal constant LOCAL_VBNBX = 0x5C12d6F03b1f4d14ED0834eb58AEF4e2Fb75D18F;

    uint256 internal constant PRINCIPAL_BNB = 100 ether;
    uint256 internal constant ITERATIONS = 4;
    uint256 internal constant SAFETY_BPS = 9_500;
    uint256 internal constant HOLD_DAYS = 30;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.WBNB);
        _trackToken(LOCAL_BNBX);
        _trackToken(LOCAL_VBNBX);
        _trackToken(BSC.vBNB);
    }

    function testStrategy_B01_02() public {
        vm.deal(address(this), PRINCIPAL_BNB);
        _startPnL();

        IVenusComptroller comp = IVenusComptroller(LOCAL_VBNBX_COMPTROLLER);
        address[] memory markets = new address[](2);
        markets[0] = LOCAL_VBNBX;
        markets[1] = BSC.vBNB; // borrow asset; same vBNB shared across pools at this block
        comp.enterMarkets(markets);

        IStaderStakeManager stader = IStaderStakeManager(LOCAL_STADER_STAKE_MANAGER);
        IBNBx bnbx = IBNBx(LOCAL_BNBX);
        IVToken vBNBx = IVToken(LOCAL_VBNBX);
        IVBNB vBNB = IVBNB(BSC.vBNB);

        bnbx.approve(LOCAL_VBNBX, type(uint256).max);

        uint256 bnbToStake = address(this).balance;

        for (uint256 i = 0; i < ITERATIONS; i++) {
            // 1. BNB -> BNBx via Stader mint path.
            stader.deposit{value: bnbToStake}();
            uint256 bnbxBal = bnbx.balanceOf(address(this));

            // 2. Supply BNBx as collateral.
            require(vBNBx.mint(bnbxBal) == 0, "vBNBx mint failed");

            // 3. Borrow BNB at SAFETY_BPS of available liquidity.
            (uint256 err, uint256 liq, uint256 shortfall) = comp.getAccountLiquidity(address(this));
            require(err == 0 && shortfall == 0, "venus liquidity error");
            uint256 borrowAmt = (liq * SAFETY_BPS) / 10_000;
            if (borrowAmt == 0) break;

            require(vBNB.borrow(borrowAmt) == 0, "vBNB borrow failed");
            bnbToStake = address(this).balance;
            if (bnbToStake == 0) break;
        }

        if (address(this).balance > 0) {
            stader.deposit{value: address(this).balance}();
            uint256 finalBnbx = bnbx.balanceOf(address(this));
            if (finalBnbx > 0) {
                require(vBNBx.mint(finalBnbx) == 0, "final vBNBx mint failed");
            }
        }

        // Hold 30 days, accrue both legs.
        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
        vm.roll(block.number + (HOLD_DAYS * 1 days) / 3);

        vBNB.borrowBalanceCurrent(address(this));
        vBNBx.balanceOfUnderlying(address(this));

        // Re-mark BNBx price using Stader's exchange rate so PnL captures the
        // stake-rate drift over the hold.
        uint256 bnbPerBnbx = bnbx.getExchangeRate(); // BNB per 1 BNBx, 1e18 scaled
        uint256 bnbxPriceE8 = (600e8 * bnbPerBnbx) / 1e18;
        _setOraclePrice(LOCAL_BNBX, bnbxPriceE8);

        uint256 debt = vBNB.borrowBalanceCurrent(address(this));
        emit log_named_uint("vbnb_debt_wei", debt);
        emit log_named_uint("bnbx_rate_1e18", bnbPerBnbx);

        _endPnL("B01-02: BNBx Venus iso loop");
    }
}
