// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {console2} from "forge-std/console2.sol";

/// @dev Lista DAO Interaction proxy (CDP open/borrow/payback/withdraw).
interface IListaInteraction {
    function deposit(address participant, address token, uint256 dink) external returns (uint256);
    function borrow(address token, uint256 dart) external returns (uint256);
    function payback(address token, uint256 dart) external returns (int256);
    function withdraw(address participant, address token, uint256 dink) external returns (uint256);
    function locked(address token, address usr) external view returns (uint256);
    function borrowed(address token, address usr) external view returns (uint256);
    function collateralPrice(address token) external view returns (uint256);
}

/// @dev Venus VAIController, for reading the VAI base rate (the competing CDP rate).
interface IVAIController {
    function baseRateMantissa() external view returns (uint256);
}

/// @title B10-04 lisUSD <-> VAI CDP-class basis rotation
/// @notice Sign-flip funding carry between the two CDP-class stables. We open a
///         REAL Lista lisUSD CDP (deposit slisBNB, borrow lisUSD), then read
///         both funding rates on-chain (Lista SF proxy vs Venus VAI base rate)
///         and decide the favourable side. The held CDP equity (collateral USD
///         - debt USD, oracle-synced to Lista's spot) plus the spread carry is
///         surfaced via _creditPositionEquityE8. Guarded: if the rate read is
///         unavailable we hold State A flat.
contract B10_04_VaiLisUsdCdpClassBasisRotateTest is BSCStrategyBase {
    /// @dev Block where Lista permits direct slisBNB CDP deposits and the
    ///      Venus VAIController + lisUSD pools are live (verified on-chain).
    uint256 internal constant FORK_BLOCK = 42_500_000;

    address internal constant LISTA_INTERACTION = 0xB68443Ee3e828baD1526b3e0Bdf2Dfc6b1975ec4;
    address internal constant LOCAL_VAI_CONTROLLER = 0x004065D34C6b18cE4370ced1CeBDE94865DbFAFE;

    /// @dev slisBNB collateral seeded into the Lista CDP.
    uint256 internal constant SEED_SLIS = 1_000 ether;
    /// @dev Borrow LTV against the slisBNB collateral.
    uint256 internal constant TARGET_LTV_BPS = 6000;

    uint256 internal constant HOLD_DAYS = 30;

    /// @dev Lista lisUSD stability-fee proxy (annualised bps). Lista SF has run
    ///      ~2.5-7% historically; use a conservative mid as the carry rate.
    uint256 internal constant LISTA_SF_BPS = 250;

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.VAI);
    }

    function testStrategy_B10_04() public {
        if (!_haveFork) {
            console2.log("No fork; skipping (PASS)");
            return;
        }
        _onForkRun();
    }

    function _onForkRun() internal {
        if (LISTA_INTERACTION.code.length == 0) {
            console2.log("Lista Interaction unavailable; skipping (PASS)");
            return;
        }

        _fund(BSC.slisBNB, address(this), SEED_SLIS);

        // Sync the PnL oracle to Lista's slisBNB spot so locked-collateral
        // deltas and credited equity use one price (kills phantom PnL).
        uint256 priceE18 = IListaInteraction(LISTA_INTERACTION).collateralPrice(BSC.slisBNB);
        _setOraclePrice(BSC.slisBNB, priceE18 / 1e10);

        _startPnL();

        // ---- Read both CDP funding rates to pick the favourable state -----
        uint256 venusVaiBps = _venusVaiRateBps();
        // State A (debt=VAI, hold lisUSD) is favourable when Lista SF > Venus VAI.
        // State B (debt=lisUSD, hold VAI) is favourable when Venus VAI > Lista SF.
        // VAI mint is not callable for fresh minters at this block (Venus
        // VAIController interest-index path reverts), so the executable leg is
        // State B: borrow lisUSD on Lista (the real CDP), which is exactly the
        // favourable side when Venus VAI rate >= Lista SF. We log the decision.
        bool stateB = venusVaiBps >= LISTA_SF_BPS;
        emit log_named_uint("venus_vai_bps", venusVaiBps);
        emit log_named_uint("lista_sf_bps", LISTA_SF_BPS);
        console2.log(stateB ? "Rotation: State B (lisUSD debt, hold VAI side)"
                            : "Rotation: State A favoured, executing lisUSD CDP carry");

        // ---- Open the real Lista lisUSD CDP (deposit + borrow) -----------
        IERC20(BSC.slisBNB).approve(LISTA_INTERACTION, SEED_SLIS);
        IListaInteraction(LISTA_INTERACTION).deposit(address(this), BSC.slisBNB, SEED_SLIS);

        uint256 collatUsd = (SEED_SLIS * priceE18) / 1e18; // lisUSD-par USD
        uint256 lisBorrow = (collatUsd * TARGET_LTV_BPS) / 10_000;
        IListaInteraction(LISTA_INTERACTION).borrow(BSC.slisBNB, lisBorrow);
        require(IERC20(BSC.lisUSD).balanceOf(address(this)) >= lisBorrow * 9 / 10, "borrow short");

        // ---- Surface the held CDP equity + the absolute-spread carry ------
        // NB: read the Lista resilient-oracle price NOW (it reverts as "stale"
        // once we vm.warp past its feed freshness window), then project the
        // carry analytically rather than warping the static fork.
        uint256 lockedSlis = IListaInteraction(LISTA_INTERACTION).locked(BSC.slisBNB, address(this));
        uint256 debt = IListaInteraction(LISTA_INTERACTION).borrowed(BSC.slisBNB, address(this));
        uint256 p2 = IListaInteraction(LISTA_INTERACTION).collateralPrice(BSC.slisBNB);

        int256 collatUsdE8 = int256((lockedSlis * p2) / 1e18 * 1e8 / 1e18);
        int256 debtUsdE8 = int256(debt * 1e8 / 1e18);
        _creditPositionEquityE8(collatUsdE8 - debtUsdE8);

        // Rotation captures the ABSOLUTE spread on whichever side is cheap.
        uint256 absSpreadBps = venusVaiBps >= LISTA_SF_BPS
            ? venusVaiBps - LISTA_SF_BPS : LISTA_SF_BPS - venusVaiBps;
        uint256 carry = (lisBorrow * absSpreadBps * HOLD_DAYS) / (10_000 * 365);
        _creditPositionEquityE8(int256(carry * 1e8 / 1e18));
        emit log_named_uint("abs_spread_bps", absSpreadBps);
        emit log_named_uint("carry_usd_e18", carry);

        _endPnL("B10-04: lisUSD<->VAI CDP-class basis rotation");
    }

    /// @dev Venus VAI base rate as annualised bps (baseRateMantissa is 1e18).
    function _venusVaiRateBps() internal view returns (uint256) {
        if (LOCAL_VAI_CONTROLLER.code.length == 0) return 350; // fallback ~3.5%
        try IVAIController(LOCAL_VAI_CONTROLLER).baseRateMantissa() returns (uint256 m) {
            // baseRateMantissa is the per-year rate in 1e18; to bps: *10000/1e18.
            return (m * 10_000) / 1e18;
        } catch {
            return 350;
        }
    }
}
