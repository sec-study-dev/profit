// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IListaStakeManager} from "src/interfaces/bsc/lst/IListaStakeManager.sol";
import {IslisBNB} from "src/interfaces/bsc/lst/IslisBNB.sol";
import {IBNBx} from "src/interfaces/bsc/lst/IBNBx.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVBNB} from "src/interfaces/bsc/mm/IVBNB.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";

interface IStaderStakeManager {
    function deposit() external payable;
    function getExchangeRate() external view returns (uint256);
}

/// @title B01-04 50/50 slisBNB + BNBx basket on Venus -> borrow BNB -> split re-stake
/// @notice Multi-LST collateral basket sharing one BNB debt leg. The borrow is
///         split evenly between Lista and Stader each iteration to keep the
///         basket weighting stable as the loop runs.
contract B01_04_MultiLSTVenusBasketTest is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 40_000_000;

    /// @dev See B01-01 / B01-02 for these placeholders.
    address internal constant LOCAL_VSLISBNB = 0xd3CC9d8f3689B83c91b7B59cAB4946B063EB894A;
    address internal constant LOCAL_VBNBX = 0x5C12d6F03b1f4d14ED0834eb58AEF4e2Fb75D18F;
    address internal constant LOCAL_STADER_STAKE_MANAGER = 0x7276241a669489E4BBB76f63d2A43Bfe63080F2F;
    /// @dev Stader BNBx ERC20. Mirrors BSC.BNBx; inlined here to dodge
    ///      the EIP-55 checksum issue in BSC.sol (cannot edit per constraints).
    address internal constant LOCAL_BNBX = 0x1BDD3CF7F79cFB8edbb955F20aD99211044f6AE4;

    uint256 internal constant PRINCIPAL_BNB = 100 ether;
    uint256 internal constant ITERATIONS = 4;
    uint256 internal constant SAFETY_BPS = 9_500;
    uint256 internal constant HOLD_DAYS = 30;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.WBNB);
        _trackToken(BSC.slisBNB);
        _trackToken(LOCAL_BNBX);
        _trackToken(LOCAL_VSLISBNB);
        _trackToken(LOCAL_VBNBX);
        _trackToken(BSC.vBNB);
    }

    function testStrategy_B01_04() public {
        vm.deal(address(this), PRINCIPAL_BNB);
        _startPnL();

        IVenusComptroller comp = IVenusComptroller(BSC.VENUS_COMPTROLLER);
        address[] memory markets = new address[](3);
        markets[0] = LOCAL_VSLISBNB;
        markets[1] = LOCAL_VBNBX;
        markets[2] = BSC.vBNB;
        comp.enterMarkets(markets);

        IListaStakeManager lista = IListaStakeManager(BSC.LISTA_STAKE_MANAGER);
        IStaderStakeManager stader = IStaderStakeManager(LOCAL_STADER_STAKE_MANAGER);
        IslisBNB slis = IslisBNB(BSC.slisBNB);
        IBNBx bnbx = IBNBx(LOCAL_BNBX);
        IVToken vSlis = IVToken(LOCAL_VSLISBNB);
        IVToken vBNBx = IVToken(LOCAL_VBNBX);
        IVBNB vBNB = IVBNB(BSC.vBNB);

        slis.approve(LOCAL_VSLISBNB, type(uint256).max);
        bnbx.approve(LOCAL_VBNBX, type(uint256).max);

        // ---- Initial 50/50 split of principal ----
        uint256 half = PRINCIPAL_BNB / 2;
        lista.deposit{value: half}();
        stader.deposit{value: PRINCIPAL_BNB - half}();

        require(vSlis.mint(slis.balanceOf(address(this))) == 0, "vslisBNB mint init failed");
        require(vBNBx.mint(bnbx.balanceOf(address(this))) == 0, "vBNBx mint init failed");

        // ---- Loop: shared borrow, split re-stake ----
        for (uint256 i = 0; i < ITERATIONS; i++) {
            (uint256 err, uint256 liq, uint256 shortfall) = comp.getAccountLiquidity(address(this));
            require(err == 0 && shortfall == 0, "venus liquidity error");
            uint256 borrowAmt = (liq * SAFETY_BPS) / 10_000;
            if (borrowAmt == 0) break;

            require(vBNB.borrow(borrowAmt) == 0, "vBNB borrow failed");
            uint256 bal = address(this).balance;
            if (bal == 0) break;

            uint256 toLista = bal / 2;
            uint256 toStader = bal - toLista;
            lista.deposit{value: toLista}();
            stader.deposit{value: toStader}();

            uint256 slisBal = slis.balanceOf(address(this));
            uint256 bnbxBal = bnbx.balanceOf(address(this));
            if (slisBal > 0) require(vSlis.mint(slisBal) == 0, "vslisBNB mint loop failed");
            if (bnbxBal > 0) require(vBNBx.mint(bnbxBal) == 0, "vBNBx mint loop failed");
        }

        // Hold 30 days, accrue everything.
        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
        vm.roll(block.number + (HOLD_DAYS * 1 days) / 3);

        vBNB.borrowBalanceCurrent(address(this));
        vSlis.balanceOfUnderlying(address(this));
        vBNBx.balanceOfUnderlying(address(this));

        // Re-mark prices using on-chain exchange rates so PnL reflects drift.
        uint256 bnbPerSlis = lista.convertSnBnbToBnb(1e18);
        uint256 bnbPerBnbx = bnbx.getExchangeRate();
        _setOraclePrice(BSC.slisBNB, (600e8 * bnbPerSlis) / 1e18);
        _setOraclePrice(LOCAL_BNBX, (600e8 * bnbPerBnbx) / 1e18);

        uint256 debt = vBNB.borrowBalanceCurrent(address(this));
        emit log_named_uint("vbnb_debt_wei", debt);
        emit log_named_uint("slis_rate_1e18", bnbPerSlis);
        emit log_named_uint("bnbx_rate_1e18", bnbPerBnbx);

        _endPnL("B01-04: multi-LST Venus basket");
    }
}
