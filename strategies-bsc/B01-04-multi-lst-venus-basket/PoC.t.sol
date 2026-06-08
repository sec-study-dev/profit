// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWBNB} from "src/interfaces/bsc/common/IWBNB.sol";
import {IListaStakeManager} from "src/interfaces/bsc/lst/IListaStakeManager.sol";
import {IslisBNB} from "src/interfaces/bsc/lst/IslisBNB.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";

interface IStaderStakeManager {
    function deposit() external payable;
    function convertBnbXToBnb(uint256 amount) external view returns (uint256);
}

/// @title B01-04 50/50 slisBNB + BNBx basket on Venus iso pool -> borrow WBNB -> split re-stake
/// @notice Multi-LST collateral basket sharing one WBNB debt leg in the Venus
///         "Liquid Staked BNB" isolated pool. Borrow is split 50/50 between
///         Lista and Stader each iteration to keep the basket weighting stable.
/// @dev    Both LSTs live in the same isolated pool (Comptroller 0xd9339...).
///         Borrows are WBNB (not native vBNB). At 40M both LST stake managers
///         accept deposits and both vToken markets allow minting. BSC.BNBx
///         constant has no code on-chain; real BNBx pinned as LOCAL_BNBX.
contract B01_04_MultiLSTVenusBasketTest is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 40_000_000;

    address internal constant LOCAL_LSB_COMPTROLLER = 0xd933909A4a2b7A4638903028f44D1d38ce27c352;
    address internal constant LOCAL_VSLISBNB = 0xd3CC9d8f3689B83c91b7B59cAB4946B063EB894A;
    address internal constant LOCAL_VBNBX = 0x5E21bF67a6af41c74C1773E4b473ca5ce8fd3791;
    address internal constant LOCAL_VWBNB = 0xe10E80B7FD3a29fE46E16C30CC8F4dd938B742e2;
    address internal constant LOCAL_STADER_STAKE_MANAGER = 0x7276241a669489E4BBB76f63d2A43Bfe63080F2F;
    address internal constant LOCAL_BNBX = 0x1bdd3Cf7F79cfB8EdbB955f20ad99211551BA275;

    uint256 internal constant PRINCIPAL_BNB = 10 ether;
    uint256 internal constant ITERATIONS = 4;
    uint256 internal constant SAFETY_BPS = 8_000;
    uint256 internal constant HOLD_DAYS = 30;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.WBNB);
        _trackToken(BSC.slisBNB);
        _trackToken(LOCAL_BNBX);
    }

    function testStrategy_B01_04() public {
        vm.deal(address(this), PRINCIPAL_BNB);
        _startPnL();

        IVenusComptroller comp = IVenusComptroller(LOCAL_LSB_COMPTROLLER);
        address[] memory markets = new address[](3);
        markets[0] = LOCAL_VSLISBNB;
        markets[1] = LOCAL_VBNBX;
        markets[2] = LOCAL_VWBNB;
        comp.enterMarkets(markets);

        IListaStakeManager lista = IListaStakeManager(BSC.LISTA_STAKE_MANAGER);
        IStaderStakeManager stader = IStaderStakeManager(LOCAL_STADER_STAKE_MANAGER);
        IslisBNB slis = IslisBNB(BSC.slisBNB);
        IERC20 bnbx = IERC20(LOCAL_BNBX);
        IVToken vSlis = IVToken(LOCAL_VSLISBNB);
        IVToken vBNBx = IVToken(LOCAL_VBNBX);
        IVToken vWBNB = IVToken(LOCAL_VWBNB);
        IWBNB wbnb = IWBNB(BSC.WBNB);

        slis.approve(LOCAL_VSLISBNB, type(uint256).max);
        bnbx.approve(LOCAL_VBNBX, type(uint256).max);

        // ---- Initial 50/50 split of principal ----
        uint256 half = PRINCIPAL_BNB / 2;
        lista.deposit{value: half}();
        stader.deposit{value: PRINCIPAL_BNB - half}();
        require(vSlis.mint(slis.balanceOf(address(this))) == 0, "vslisBNB mint init failed");
        require(vBNBx.mint(bnbx.balanceOf(address(this))) == 0, "vBNBx mint init failed");

        // ---- Loop: shared WBNB borrow, split re-stake ----
        for (uint256 i = 0; i < ITERATIONS; i++) {
            (uint256 err, uint256 liq, uint256 shortfall) = comp.getAccountLiquidity(address(this));
            require(err == 0 && shortfall == 0, "venus liquidity error");
            if (liq == 0) break;

            uint256 wbnbPriceE18 = _poolBnbPriceE18();
            uint256 borrowAmt = (liq * SAFETY_BPS) / 10_000;
            if (wbnbPriceE18 > 0) borrowAmt = (borrowAmt * 1e18) / wbnbPriceE18;
            uint256 cash = vWBNB.getCash();
            if (borrowAmt > (cash * 9) / 10) borrowAmt = (cash * 9) / 10;
            if (borrowAmt == 0) break;

            require(vWBNB.borrow(borrowAmt) == 0, "vWBNB borrow failed");
            wbnb.withdraw(wbnb.balanceOf(address(this)));
            uint256 bal = address(this).balance;
            if (bal == 0) break;

            uint256 toLista = bal / 2;
            lista.deposit{value: toLista}();
            stader.deposit{value: bal - toLista}();

            uint256 slisBal = slis.balanceOf(address(this));
            uint256 bnbxBal = bnbx.balanceOf(address(this));
            if (slisBal > 0) require(vSlis.mint(slisBal) == 0, "vslisBNB mint loop failed");
            if (bnbxBal > 0) require(vBNBx.mint(bnbxBal) == 0, "vBNBx mint loop failed");
        }

        // ---- Position equity at entry (1e8 USD). ----
        uint256 debtWei = vWBNB.borrowBalanceCurrent(address(this));
        uint256 collSlis = vSlis.balanceOfUnderlying(address(this));
        uint256 collBnbx = vBNBx.balanceOfUnderlying(address(this));
        uint256 slisBnbWei = lista.convertSnBnbToBnb(collSlis);
        uint256 bnbxBnbWei = stader.convertBnbXToBnb(collBnbx);
        uint256 collBnbWei = slisBnbWei + bnbxBnbWei;

        uint256 bnbUsdE8 = 600e8;
        int256 collUsdE8 = int256((collBnbWei * bnbUsdE8) / 1e18);
        int256 debtUsdE8 = int256((debtWei * bnbUsdE8) / 1e18);
        _creditPositionEquityE8(collUsdE8 - debtUsdE8);

        // Projected 30-day carry: basket stake yield on collateral minus WBNB
        // borrow APR on debt (live IRM rate). Blended stake APY ~3.9%.
        uint256 blocksPerYear = 365 days / 3;
        uint256 borrowApr1e18 = vWBNB.borrowRatePerBlock() * blocksPerYear;
        uint256 stakeApr1e18 = 39e15;
        int256 annualCarryBnb =
            int256((collBnbWei * stakeApr1e18) / 1e18) - int256((debtWei * borrowApr1e18) / 1e18);
        int256 carryBnb = (annualCarryBnb * int256(HOLD_DAYS)) / 365;
        _creditPositionEquityE8((carryBnb * int256(bnbUsdE8)) / 1e18);

        emit log_named_uint("coll_bnb_wei", collBnbWei);
        emit log_named_uint("wbnb_debt_wei", debtWei);
        emit log_named_int("carry_bnb_wei_30d", carryBnb);

        _endPnL("B01-04: multi-LST Venus basket");
    }

    function _poolBnbPriceE18() internal view returns (uint256) {
        (bool ok, bytes memory data) =
            LOCAL_LSB_COMPTROLLER.staticcall(abi.encodeWithSignature("oracle()"));
        if (!ok || data.length < 32) return 600e18;
        address oracle = abi.decode(data, (address));
        (bool ok2, bytes memory d2) =
            oracle.staticcall(abi.encodeWithSignature("getUnderlyingPrice(address)", LOCAL_VWBNB));
        if (!ok2 || d2.length < 32) return 600e18;
        uint256 p = abi.decode(d2, (uint256));
        return p == 0 ? 600e18 : p;
    }
}
