// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Router} from "src/interfaces/bsc/amm/IPancakeV3Router.sol";

// ---- Local interfaces (declared here so we don't touch shared interfaces) ----

interface IListaInteraction {
    function deposit(address participant, address token, uint256 dink) external returns (uint256);
    function borrow(address token, uint256 dart) external returns (uint256);
    function locked(address token, address usr) external view returns (uint256);
    function borrowed(address token, address usr) external view returns (uint256);
    function collateralPrice(address token) external view returns (uint256);
}

interface IListaStakeManager {
    function deposit() external payable;
}

interface IWBNB {
    function withdraw(uint256) external;
}

/// @dev Venus vBNB market (native-BNB CErc20/CEther variant).
interface IVBNB {
    function mint() external payable;
    function borrow(uint256 amount) external returns (uint256);
    function balanceOfUnderlying(address owner) external returns (uint256);
    function borrowBalanceCurrent(address account) external returns (uint256);
}

interface IVenusComptroller {
    function enterMarkets(address[] calldata vTokens) external returns (uint256[] memory);
}

/// @title B03-08 slisBNB -> Lista mint lisUSD -> Venus borrow BNB -> recursive restake
/// @notice Real fork-replay, 3 recursive rounds. Each round:
///         1. Lista CDP: deposit slisBNB, mint lisUSD.
///         2. Swap lisUSD -> WBNB on PancakeSwap v3 and unwrap to BNB.
///         3. Venus: supply that BNB to vBNB, enter the market, borrow more
///            BNB against it (independent debt market).
///         4. Restake the borrowed BNB -> slisBNB via Lista StakeManager;
///            feed it into the next round.
///
///         Two uncorrelated debt markets (Lista lisUSD + Venus BNB) double-
///         use each dollar of slisBNB collateral. The parked positions are
///         surfaced via `_creditPositionEquityE8`:
///           equity = Lista(collat - debt) + Venus(supply - borrow).
contract B03_08_SlisBnbListaMintVenusBnbRecursiveTest is BSCStrategyBase {
    uint256 constant FORK_BLOCK = 42_500_000;

    address constant LISTA_INTERACTION = 0xB68443Ee3e828baD1526b3e0Bdf2Dfc6b1975ec4;
    address constant LISTA_STAKE_MANAGER = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
    address constant PCS_V3_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address constant VBNB = 0xA07c5b74C9B40447a954e1466938b865b6BBea36;

    uint24 constant LISUSD_USDT_FEE = 500;
    uint24 constant WBNB_USDT_FEE = 500;

    uint256 constant SEED_SLIS_BNB = 100 ether;
    uint256 constant LISTA_LTV_BPS = 6000; // 60% on the slisBNB ilk
    uint256 constant VENUS_LTV_BPS = 6000; // 60% of supplied BNB (under 78% CF)
    uint256 constant ROUNDS = 3;

    uint256 constant HOLD_DAYS = 30;
    uint256 constant SLIS_APR_BPS = 320; // 3.2% slisBNB native staking
    uint256 constant LISTA_BORROW_BPS = 250; // 2.5% Lista stability fee
    uint256 constant VENUS_BORROW_BPS = 350; // 3.5% Venus BNB borrow APR

    uint256 public totalCollateralSlisBnb;
    uint256 public totalLisUsdDebt;
    uint256 public totalBnbDebt;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.WBNB);
        _trackToken(BSC.USDT);
    }

    function testStrategy_B03_08() public {
        _fund(BSC.slisBNB, address(this), SEED_SLIS_BNB);

        // Align the PnL oracle with Lista's spot (no phantom slisBNB PnL).
        _setOraclePrice(BSC.slisBNB, IListaInteraction(LISTA_INTERACTION).collateralPrice(BSC.slisBNB) / 1e10);

        _startPnL();

        // Enter the vBNB market once so supplied BNB counts as collateral.
        address[] memory mkts = new address[](1);
        mkts[0] = VBNB;
        IVenusComptroller(BSC.VENUS_COMPTROLLER).enterMarkets(mkts);

        uint256 roundSlis = SEED_SLIS_BNB;

        for (uint256 i = 0; i < ROUNDS; i++) {
            // ---- 1. Lista CDP: deposit slisBNB, mint lisUSD ----
            IERC20(BSC.slisBNB).approve(LISTA_INTERACTION, roundSlis);
            IListaInteraction(LISTA_INTERACTION).deposit(address(this), BSC.slisBNB, roundSlis);
            totalCollateralSlisBnb += roundSlis;

            uint256 priceE18 = IListaInteraction(LISTA_INTERACTION).collateralPrice(BSC.slisBNB);
            uint256 collatUsd = (roundSlis * priceE18) / 1e18;
            uint256 mintLisUsd = (collatUsd * LISTA_LTV_BPS) / 10_000;
            IListaInteraction(LISTA_INTERACTION).borrow(BSC.slisBNB, mintLisUsd);
            totalLisUsdDebt += mintLisUsd;

            // ---- 2. Swap lisUSD -> WBNB, unwrap to BNB ----
            uint256 lisBal = IERC20(BSC.lisUSD).balanceOf(address(this));
            uint256 wbnbOut = _swapLisUsdToWbnb(lisBal);
            IWBNB(BSC.WBNB).withdraw(wbnbOut);

            // ---- 3. Venus: supply BNB to vBNB, borrow more BNB ----
            IVBNB(VBNB).mint{value: wbnbOut}();
            uint256 venusBorrow = (wbnbOut * VENUS_LTV_BPS) / 10_000;
            require(IVBNB(VBNB).borrow(venusBorrow) == 0, "venus borrow failed");
            totalBnbDebt += venusBorrow;

            // ---- 4. Restake borrowed BNB -> slisBNB ----
            uint256 slisBefore = IERC20(BSC.slisBNB).balanceOf(address(this));
            IListaStakeManager(LISTA_STAKE_MANAGER).deposit{value: venusBorrow}();
            uint256 newSlis = IERC20(BSC.slisBNB).balanceOf(address(this)) - slisBefore;

            roundSlis = newSlis;
        }

        // ---- 5. Surface parked positions (Lista + Venus) ----
        uint256 lockedSlis = IListaInteraction(LISTA_INTERACTION).locked(BSC.slisBNB, address(this));
        uint256 listaDebt = IListaInteraction(LISTA_INTERACTION).borrowed(BSC.slisBNB, address(this));
        uint256 priceFinalE18 = IListaInteraction(LISTA_INTERACTION).collateralPrice(BSC.slisBNB);

        uint256 venusSupplyBnb = IVBNB(VBNB).balanceOfUnderlying(address(this));
        uint256 venusBorrowBnb = IVBNB(VBNB).borrowBalanceCurrent(address(this));

        // Lista equity in 1e8-USD.
        int256 listaCollatE8 = int256((lockedSlis * priceFinalE18) / 1e18 * 1e8 / 1e18);
        int256 listaDebtE8 = int256(listaDebt * 1e8 / 1e18);
        // Venus equity in 1e8-USD (BNB priced via base default $600).
        int256 venusSupplyE8 = int256(venusSupplyBnb * _bnbUsdE8 / 1e18);
        int256 venusBorrowE8 = int256(venusBorrowBnb * _bnbUsdE8 / 1e18);

        _creditPositionEquityE8((listaCollatE8 - listaDebtE8) + (venusSupplyE8 - venusBorrowE8));

        // Holding-period carry: stacked slisBNB staking accrual on the total
        // locked collateral, net of the Lista stability fee and the Venus BNB
        // borrow cost. Conservative real rates.
        uint256 collatUsd2 = (lockedSlis * priceFinalE18) / 1e18;
        uint256 slisYield = (collatUsd2 * SLIS_APR_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 listaFee = (listaDebt * LISTA_BORROW_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 venusFee = (venusBorrowBnb * _bnbUsdE8 / 1e8 * VENUS_BORROW_BPS * HOLD_DAYS) / (10_000 * 365);
        int256 carryE8 = (int256(slisYield) - int256(listaFee) - int256(venusFee)) * 1e8 / 1e18;
        _creditPositionEquityE8(carryE8);

        _endPnL("B03-08: slisBNB-Lista-Venus recursive restake");
    }

    function _swapLisUsdToWbnb(uint256 amountIn) internal returns (uint256) {
        IERC20(BSC.lisUSD).approve(PCS_V3_ROUTER, amountIn);
        bytes memory path = abi.encodePacked(
            BSC.lisUSD, LISUSD_USDT_FEE, BSC.USDT, WBNB_USDT_FEE, BSC.WBNB
        );
        IPancakeV3Router.ExactInputParams memory p = IPancakeV3Router.ExactInputParams({
            path: path,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: 0
        });
        return IPancakeV3Router(PCS_V3_ROUTER).exactInput(p);
    }
}
