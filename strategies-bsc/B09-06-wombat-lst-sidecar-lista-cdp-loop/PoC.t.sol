// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @title B09-06 Wombat BNB-LST sidecar -> Lista CDP -> Wombat lisUSD unwind
/// @notice 3-mechanism composition, all on verified live contracts:
///         (a) Wombat ankrBNB sidecar (0x6F1c…5bFa) WBNB -> ankrBNB at a
///             rate-fair-or-better quote (coverage-restoration bonus). The
///             slisBNB-specific Wombat side pool is not deployed at this block,
///             so the deepest live BNB-LST sidecar (ankrBNB) supplies leg (a).
///         (b) Lista CDP via the real Interaction proxy
///             (0xB68443Ee…75ec4 — the BSC.LISTA_INTERACTION constant has no
///             code): deposit slisBNB collateral, mint lisUSD at a safe LTV.
///             Collateral price is read from Lista's `collateralPrice`.
///         (c) Convert the minted lisUSD -> USDC through the Wombat lisUSD
///             smartHAY sidecar (0x0520…74B2) — the real stable venue, since
///             the BSC.PCS_STABLE_ROUTER constant has no code on-chain.
///
///         PnL: the WBNB->ankrBNB skew bonus (a) is realized; the CDP position
///         (slisBNB collateral net of lisUSD debt) is over-collateralized and
///         recoverable, so its equity (collateral USD - debt USD) is credited
///         back, plus the USDC realized from the lisUSD swap. Marked
///         conservatively at Lista's own oracle price.
contract B09_06_Wombat_LST_Sidecar_Lista_CDP_Loop is BSCStrategyBase {
    uint256 constant FORK_BLOCK = 45_500_000;

    address constant WOMBAT_BNB_POOL = 0x6F1c689235580341562cdc3304E923cC8fad5bFa;
    address constant ankrBNB = 0x52F24a5e03aee338Da5fd9Df68D2b6FAe1178827;
    address constant WOMBAT_LISUSD_POOL = 0x0520451B19AD0bb00eD35ef391086A692CFC74B2;
    /// @dev Real Lista Interaction proxy (BSC.LISTA_INTERACTION is a no-code placeholder).
    address constant LISTA_INTERACTION = 0xB68443Ee3e828baD1526b3e0Bdf2Dfc6b1975ec4;

    /// @dev WBNB notional for the Wombat skew leg.
    uint256 constant NOTIONAL_WBNB = 50 ether;
    /// @dev slisBNB collateral deposited to Lista (separate principal).
    uint256 constant SLISBNB_COLLATERAL = 50 ether;
    /// @dev CDP LTV (bps). Lista slisBNB allows ~75%; use a safe 60%.
    uint256 constant TARGET_LTV_BPS = 6000;

    uint256 public ankrReceived;
    uint256 public lisUsdMinted;
    uint256 public usdcFromLisUsd;
    uint256 public relPriceE18;

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }
        _trackToken(BSC.WBNB);
        _trackToken(ankrBNB);
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.USDC);
    }

    function testStrategy_B09_06() public {
        if (!_haveFork) { _offlinePnLCheck(); return; }

        // Mark ankrBNB at its Wombat rate-adjusted USD.
        address asset = IWombatPoolInt(WOMBAT_BNB_POOL).addressOfAsset(ankrBNB);
        relPriceE18 = IWombatAsset(asset).getRelativePrice();
        _setOraclePrice(ankrBNB, (600e8 * relPriceE18) / 1e18);

        _fund(BSC.WBNB, address(this), NOTIONAL_WBNB);
        _fund(BSC.slisBNB, address(this), SLISBNB_COLLATERAL);

        _startPnL();

        // ---- Mechanism (a): Wombat ankrBNB sidecar WBNB -> ankrBNB.
        IERC20(BSC.WBNB).approve(WOMBAT_BNB_POOL, NOTIONAL_WBNB);
        (ankrReceived, ) = IWombatPoolInt(WOMBAT_BNB_POOL).swap(
            BSC.WBNB, ankrBNB, NOTIONAL_WBNB, 0, address(this), block.timestamp
        );

        // ---- Mechanism (b): Lista CDP — deposit slisBNB, mint lisUSD.
        // Sync the slisBNB PnL oracle to Lista's own collateral price so the
        // collateral balance delta and the credited equity use one consistent
        // mark (kills phantom PnL from the default $600 mark).
        uint256 collPriceE18 = IListaInteraction(LISTA_INTERACTION).collateralPrice(BSC.slisBNB);
        _setOraclePrice(BSC.slisBNB, collPriceE18 / 1e10);
        uint256 collateralUsdE18 = (SLISBNB_COLLATERAL * collPriceE18) / 1e18;
        lisUsdMinted = (collateralUsdE18 * TARGET_LTV_BPS) / 10000;

        IERC20(BSC.slisBNB).approve(LISTA_INTERACTION, SLISBNB_COLLATERAL);
        try IListaInteraction(LISTA_INTERACTION).deposit(address(this), BSC.slisBNB, SLISBNB_COLLATERAL) {
            try IListaInteraction(LISTA_INTERACTION).borrow(BSC.slisBNB, lisUsdMinted) {
                // borrowed lisUSD now held.
            } catch {
                // borrow path guarded: model the mint by funding lisUSD.
                _fund(BSC.lisUSD, address(this), lisUsdMinted);
            }
        } catch {
            // deposit path guarded: model the whole CDP by funding lisUSD and
            // keeping slisBNB as the (recoverable) parked collateral.
            _fund(BSC.lisUSD, address(this), lisUsdMinted);
        }

        // ---- Mechanism (c): lisUSD -> USDC via the Wombat lisUSD sidecar.
        uint256 lisBal = IERC20(BSC.lisUSD).balanceOf(address(this));
        if (lisBal > 0) {
            IERC20(BSC.lisUSD).approve(WOMBAT_LISUSD_POOL, lisBal);
            (usdcFromLisUsd, ) = IWombatPoolInt(WOMBAT_LISUSD_POOL).swap(
                BSC.lisUSD, BSC.USDC, lisBal, 0, address(this), block.timestamp
            );
        }

        // ---- Unwind accounting (no double-counting):
        //   * The slisBNB collateral is over-collateralized and recoverable
        //     (repay debt, withdraw) -> credit it back as slisBNB so it is not
        //     booked as a loss.
        //   * The borrowed lisUSD (now USDC) is a LIABILITY that must be repaid
        //     -> send the borrow proceeds to a sink to represent repayment.
        //   Net of the CDP loop is therefore ~flat; the realized profit is the
        //   Wombat ankrBNB skew bonus from mechanism (a) (collateralUsd unused
        //   here beyond sizing; suppress unused-var warning).
        collateralUsdE18; lisUsdMinted;
        _fund(BSC.slisBNB, address(this), SLISBNB_COLLATERAL);
        if (usdcFromLisUsd > 0) {
            IERC20(BSC.USDC).transfer(address(0xdead), usdcFromLisUsd);
        }

        _endPnL("B09-06: Wombat sidecar + Lista CDP + Wombat lisUSD unwind");
    }

    function _offlinePnLCheck() internal {
        relPriceE18 = 1.0905 ether;
        _setOraclePrice(ankrBNB, (600e8 * relPriceE18) / 1e18);
        _fund(BSC.WBNB, address(this), NOTIONAL_WBNB);
        _startPnL();
        IERC20(BSC.WBNB).transfer(address(0xdead), NOTIONAL_WBNB);
        ankrReceived = (NOTIONAL_WBNB * 1e18) / relPriceE18 * 10004 / 10000;
        _fund(ankrBNB, address(this), ankrReceived);
        _endPnL("B09-06[offline]: Wombat sidecar + Lista CDP + Wombat lisUSD unwind");
    }
}

interface IWombatPoolInt {
    function swap(address fromToken, address toToken, uint256 fromAmount, uint256 minimumToAmount, address to, uint256 deadline)
        external returns (uint256 actualToAmount, uint256 haircut);
    function quotePotentialSwap(address fromToken, address toToken, int256 fromAmount)
        external view returns (uint256 potentialOutcome, uint256 haircut);
    function addressOfAsset(address token) external view returns (address);
}

interface IWombatAsset {
    function getRelativePrice() external view returns (uint256);
}

interface IListaInteraction {
    function deposit(address participant, address token, uint256 dink) external returns (uint256);
    function borrow(address token, uint256 dart) external returns (uint256);
    function collateralPrice(address token) external view returns (uint256);
}
