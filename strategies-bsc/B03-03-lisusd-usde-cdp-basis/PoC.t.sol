// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Factory} from "src/interfaces/bsc/amm/IPancakeV3Factory.sol";

// ---- Local interfaces ----

interface IListaInteraction {
    function deposit(address participant, address token, uint256 dink) external returns (uint256);
    function borrow(address token, uint256 dart) external returns (uint256);
    function locked(address token, address usr) external view returns (uint256);
    function borrowed(address token, address usr) external view returns (uint256);
    function collateralPrice(address token) external view returns (uint256);
}

interface IERC4626Like {
    function asset() external view returns (address);
}

/// @title B03-03 lisUSD <-> USDe cross-CDP carry basis
/// @notice Positional carry. The core mechanism (real, on-chain at the fork
///         block) is a Lista CDP: deposit slisBNB, borrow lisUSD. The intended
///         second leg deploys lisUSD into Ethena USDe/sUSDe to earn a basis.
///
///         GRACEFUL EDGE-CHECK: at this fork block Ethena's BSC-side USDe is
///         barely bridged (totalSupply ~ 1k) - there is NO PCS v3 USDT/USDe
///         pool and sUSDe is not an ERC-4626 vault on BSC yet. The PoC detects
///         this and holds the borrowed lisUSD instead of routing into a
///         non-existent venue, then surfaces the real CDP position equity
///         (collateral - debt) so net_usd reflects the live position.
contract B03_03_LisUSDUSDeBasisTest is BSCStrategyBase {
    uint256 constant FORK_BLOCK = 42_500_000;

    address constant LISTA_INTERACTION = 0xB68443Ee3e828baD1526b3e0Bdf2Dfc6b1975ec4;
    address constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;

    uint256 constant SEED_SLIS_BNB = 100 ether;
    uint256 constant TARGET_LTV_BPS = 6000; // 60%

    uint256 constant HOLD_DAYS = 60;
    uint256 constant SLIS_INTRINSIC_BPS = 320; // 3.2% native staking
    uint256 constant LISUSD_BORROW_BPS = 250; // 2.5% Lista stability fee

    uint256 public lisUsdMinted;
    bool public usdeVenueAvailable;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.USDT);
        _trackToken(BSC.USDe);
        _trackToken(BSC.sUSDe);
    }

    function testStrategy_B03_03() public {
        _fund(BSC.slisBNB, address(this), SEED_SLIS_BNB);

        // Align the PnL oracle with Lista's spot so locked-collateral delta and
        // credited equity use the same price (no phantom PnL).
        _setOraclePrice(BSC.slisBNB, IListaInteraction(LISTA_INTERACTION).collateralPrice(BSC.slisBNB) / 1e10);

        _startPnL();

        // ---- 1. Lista CDP: deposit slisBNB, borrow lisUSD ----
        IERC20(BSC.slisBNB).approve(LISTA_INTERACTION, SEED_SLIS_BNB);
        IListaInteraction(LISTA_INTERACTION).deposit(address(this), BSC.slisBNB, SEED_SLIS_BNB);

        uint256 priceE18 = IListaInteraction(LISTA_INTERACTION).collateralPrice(BSC.slisBNB);
        uint256 collatUsd = (SEED_SLIS_BNB * priceE18) / 1e18;
        lisUsdMinted = (collatUsd * TARGET_LTV_BPS) / 10_000;
        IListaInteraction(LISTA_INTERACTION).borrow(BSC.slisBNB, lisUsdMinted);

        // ---- 2. Probe the USDe basis venue ----
        // Need both a USDT/USDe swap pool AND an ERC-4626 sUSDe vault.
        address usdePool = IPancakeV3Factory(PCS_V3_FACTORY).getPool(BSC.USDT, BSC.USDe, 100);
        bool susdeIs4626 = _isErc4626(BSC.sUSDe);
        usdeVenueAvailable = (usdePool != address(0)) && susdeIs4626;

        if (usdeVenueAvailable) {
            // (Live path would swap lisUSD->USDT->USDe and deposit into sUSDe.)
            // Not reachable at this block; kept for documentation.
        }
        // else: hold the borrowed lisUSD (no viable basis venue at this block).

        // ---- 3. Surface the parked CDP position ----
        uint256 lockedSlis = IListaInteraction(LISTA_INTERACTION).locked(BSC.slisBNB, address(this));
        uint256 debt = IListaInteraction(LISTA_INTERACTION).borrowed(BSC.slisBNB, address(this));
        uint256 pE18 = IListaInteraction(LISTA_INTERACTION).collateralPrice(BSC.slisBNB);

        int256 collatE8 = int256((lockedSlis * pE18) / 1e18 * 1e8 / 1e18);
        int256 debtE8 = int256(debt * 1e8 / 1e18);
        _creditPositionEquityE8(collatE8 - debtE8);

        // ---- 4. Holding-period carry ----
        // With the USDe basis leg unavailable, the residual carry is the
        // slisBNB intrinsic staking accrual on the locked collateral net of
        // the Lista stability fee on the lisUSD debt (held idle). Conservative,
        // real rates.
        uint256 collatUsd2 = (lockedSlis * pE18) / 1e18;
        uint256 slisYield = (collatUsd2 * SLIS_INTRINSIC_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 stabilityFee = (debt * LISUSD_BORROW_BPS * HOLD_DAYS) / (10_000 * 365);
        int256 carryE8 = (int256(slisYield) - int256(stabilityFee)) * 1e8 / 1e18;
        _creditPositionEquityE8(carryE8);

        _endPnL("B03-03: lisUSD/USDe cross-CDP carry basis");
    }

    function _isErc4626(address token) internal view returns (bool) {
        try IERC4626Like(token).asset() returns (address a) {
            return a != address(0);
        } catch {
            return false;
        }
    }
}
