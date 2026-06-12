// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Router} from "src/interfaces/bsc/amm/IPancakeV3Router.sol";

// ---- Local interfaces (declared here so we don't touch shared interfaces) ----

/// @dev Lista DAO Interaction proxy (CDP open/borrow/payback/withdraw).
///      Verified live at the fork block.
interface IListaInteraction {
    function deposit(address participant, address token, uint256 dink) external returns (uint256);
    function borrow(address token, uint256 dart) external returns (uint256);
    function payback(address token, uint256 dart) external returns (int256);
    function withdraw(address participant, address token, uint256 dink) external returns (uint256);
    function locked(address token, address usr) external view returns (uint256);
    function borrowed(address token, address usr) external view returns (uint256);
    /// @notice Collateral price, 1e18-USD scaled.
    function collateralPrice(address token) external view returns (uint256);
}

/// @dev Lista slisBNB StakeManager (native BNB -> slisBNB at canonical rate).
interface IListaStakeManager {
    function deposit() external payable;
    function convertBnbToSnBnb(uint256 amount) external view returns (uint256);
    function convertSnBnbToBnb(uint256 amount) external view returns (uint256);
}

interface IWBNB {
    function withdraw(uint256) external;
}

/// @title B03-02 slisBNB . Lista CDP recursive leverage loop
/// @notice Real fork-replay. Each round:
///         1. Deposit slisBNB into the Lista CDP (Interaction.deposit).
///         2. Borrow lisUSD against it at TARGET_LTV (Interaction.borrow).
///         3. Swap lisUSD -> WBNB on PancakeSwap v3.
///         4. Unwrap WBNB and stake BNB -> slisBNB via Lista StakeManager
///            (canonical rate, no AMM slippage on the mint).
///         5. Re-deposit the freshly minted slisBNB next round.
///
///         Geometric leverage ~ 1/(1-LTV). The collateral ends up parked
///         inside the Lista vault, so we surface the position via
///         `_creditPositionEquityE8` = locked collateral USD - lisUSD debt.
contract B03_02_SlisBnbListaCdpLeverageLoopTest is BSCStrategyBase {
    /// @dev Late-2024 block - slisBNB / Lista vault live (verified).
    uint256 constant FORK_BLOCK = 42_500_000;

    address constant LISTA_INTERACTION = 0xB68443Ee3e828baD1526b3e0Bdf2Dfc6b1975ec4;
    address constant LISTA_STAKE_MANAGER = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
    address constant PCS_V3_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;

    /// @dev lisUSD -> USDT -> WBNB hops.
    uint24 constant LISUSD_USDT_FEE = 500;
    uint24 constant WBNB_USDT_FEE = 500;

    /// @dev Conservative LTV per round (well under Lista's liquidation ratio).
    uint256 constant TARGET_LTV_BPS = 6000;
    uint256 constant ROUNDS = 3;
    uint256 constant SEED_SLIS_BNB = 100 ether;

    uint256 constant HOLD_DAYS = 30;
    uint256 constant SLIS_INTRINSIC_BPS = 320; // 3.2% native staking APR
    uint256 constant LISUSD_BORROW_BPS = 250; // 2.5% Lista stability fee

    uint256 public totalCollateralFinal;
    uint256 public totalDebtFinal;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.WBNB);
    }

    function testStrategy_B03_02() public {
        _fund(BSC.slisBNB, address(this), SEED_SLIS_BNB);

        // Align the PnL oracle with Lista's spot so locked-collateral balance
        // deltas and credited equity use the same price (no phantom PnL).
        _setOraclePrice(BSC.slisBNB, IListaInteraction(LISTA_INTERACTION).collateralPrice(BSC.slisBNB) / 1e10);

        _startPnL();

        uint256 roundCollat = SEED_SLIS_BNB;

        for (uint256 i = 0; i < ROUNDS; i++) {
            // ---- 1. Deposit slisBNB into the Lista vault ----
            IERC20(BSC.slisBNB).approve(LISTA_INTERACTION, roundCollat);
            IListaInteraction(LISTA_INTERACTION).deposit(address(this), BSC.slisBNB, roundCollat);

            // ---- 2. Borrow lisUSD at target LTV ----
            uint256 collatPriceE18 = IListaInteraction(LISTA_INTERACTION).collateralPrice(BSC.slisBNB);
            uint256 collatUsd = (roundCollat * collatPriceE18) / 1e18; // lisUSD (18 dec) par
            uint256 lisUsdMint = (collatUsd * TARGET_LTV_BPS) / 10_000;
            IListaInteraction(LISTA_INTERACTION).borrow(BSC.slisBNB, lisUsdMint);

            // ---- 3. Swap lisUSD -> USDT -> WBNB on PCS v3 ----
            uint256 lisBal = IERC20(BSC.lisUSD).balanceOf(address(this));
            uint256 wbnbOut = _swapLisUsdToWbnb(lisBal);

            // ---- 4. Unwrap and re-stake BNB -> slisBNB (canonical rate) ----
            IWBNB(BSC.WBNB).withdraw(wbnbOut);
            uint256 slisBefore = IERC20(BSC.slisBNB).balanceOf(address(this));
            IListaStakeManager(LISTA_STAKE_MANAGER).deposit{value: wbnbOut}();
            uint256 newSlis = IERC20(BSC.slisBNB).balanceOf(address(this)) - slisBefore;

            roundCollat = newSlis;
        }

        // ---- 5. Surface the parked CDP position ----
        uint256 lockedSlis = IListaInteraction(LISTA_INTERACTION).locked(BSC.slisBNB, address(this));
        uint256 debt = IListaInteraction(LISTA_INTERACTION).borrowed(BSC.slisBNB, address(this));
        uint256 priceE18 = IListaInteraction(LISTA_INTERACTION).collateralPrice(BSC.slisBNB);

        totalCollateralFinal = lockedSlis;
        totalDebtFinal = debt;

        // Equity in 1e8-USD: collateral USD - debt USD (lisUSD ~ $1).
        int256 collatUsdE8 = int256((lockedSlis * priceE18) / 1e18 * 1e8 / 1e18);
        int256 debtUsdE8 = int256(debt * 1e8 / 1e18);
        _creditPositionEquityE8(collatUsdE8 - debtUsdE8);

        // Holding-period carry: the leveraged slisBNB staking accrual on the
        // (now ~2.5x) collateral net of the Lista stability fee on the debt.
        uint256 collatUsd2 = (lockedSlis * priceE18) / 1e18;
        uint256 slisYield = (collatUsd2 * SLIS_INTRINSIC_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 stabilityFee = (debt * LISUSD_BORROW_BPS * HOLD_DAYS) / (10_000 * 365);
        int256 carryE8 = (int256(slisYield) - int256(stabilityFee)) * 1e8 / 1e18;
        _creditPositionEquityE8(carryE8);

        _endPnL("B03-02: slisBNB Lista CDP leverage loop");
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
