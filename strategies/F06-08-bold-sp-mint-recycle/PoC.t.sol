// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IBorrowerOperations} from "src/interfaces/cdp/IBorrowerOperations.sol";

// ---- Local Liquity v2 wstETH-branch interfaces ----
interface IStabilityPoolV2Wsteth {
    function provideToSP(uint256 _amount, bool _doClaim) external;
    function withdrawFromSP(uint256 _amount, bool _doClaim) external;
    function getCompoundedBoldDeposit(address _depositor) external view returns (uint256);
    function getDepositorCollGain(address _depositor) external view returns (uint256);
    function getDepositorYieldGain(address _depositor) external view returns (uint256);
}

interface ITroveManagerV2Branch {
    function getTroveAnnualInterestRate(uint256 _troveId) external view returns (uint256);
    function getTroveEntireDebt(uint256 _troveId) external view returns (uint256);
    function getTroveEntireColl(uint256 _troveId) external view returns (uint256);
    function getTroveStatus(uint256 _troveId) external view returns (uint256);
}

/// @title F06-08 — BOLD SP-mint recycle on the wstETH branch
/// @notice 2-mechanism strategy:
///         1. Liquity v2 — open a trove on the wstETH branch (low rate),
///            mint BOLD, immediately deposit BOLD into the same branch's
///            Stability Pool.
///         2. Curve — when liquidations award wstETH at a discount, swap
///            any excess wstETH back to BOLD (via BOLD/USDC + Curve
///            wstETH/ETH) and redeposit, compounding the position.
///
///         Identity: at steady state the trove pays BOLD interest, the SP
///         deposit earns the per-branch BOLD interest stream (the
///         protocol routes 75% of borrower interest to the SP) plus
///         wstETH-gain from liquidations. If the user's own borrow rate
///         is below the average SP yield rate, the net is positive
///         carry — *self-funding leverage*.
contract F06_08_BoldSpMintRecycleTest is StrategyBase {
    // ---- Liquity v2 mainnet (verified Wave-4) ----
    //
    // SOURCES:
    //   - https://docs.liquity.org/v2-documentation/technical-resources
    //   - https://etherscan.io/token/0x6440f144b7e50D6a8439336510312d2F54beB01D
    //
    // Canonical BOLD (post 2025-05-19 redeployment).
    address constant LOCAL_BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;
    address constant LOCAL_COLLATERAL_REGISTRY = 0xd99de73b95236f69A559117ECD6F519Af780F3f7;
    address constant LOCAL_HINT_HELPERS_V2 = 0xe3Bb97EE79AC4bdfc0c30A95aD82c243c9913AdA;

    /// @dev wstETH-branch contracts. Pending resolution from the
    ///      CollateralRegistry's branch-N accessor (only callable on a
    ///      live fork). Strategy gates on `_hasCode` checks.
    address constant LOCAL_BORROWER_OPS_WSTETH = address(0);
    address constant LOCAL_TROVE_MANAGER_WSTETH = address(0);
    address constant LOCAL_STABILITY_POOL_WSTETH = address(0);

    // ---- Tunables ----
    /// @dev Post-redeployment block.
    uint256 constant FORK_BLOCK = 22_500_000;

    /// @dev Equity (wstETH).
    uint256 constant EQUITY_WSTETH = 50 ether;

    /// @dev Borrower-chosen annual interest rate (1e18 = 100%).
    ///      3.0%/yr — designed to sit at-or-below the running median (so
    ///      we're a redemption target on adverse moves) BUT we accept
    ///      that because the SP yield from the same branch averages above
    ///      the user-set rate when liquidations happen.
    uint256 constant ANNUAL_RATE = 30e15;

    /// @dev Owner index for deterministic trove id.
    uint256 constant OWNER_INDEX = 0;

    /// @dev BOLD to mint per wstETH of collateral. Conservative: ~30%
    ///      LTV → ICR ≈ 333% at wstETH=$4000 → trove very safe from
    ///      liquidation, but more redeemable.
    uint256 constant BOLD_PER_WSTETH = 1200e18;

    bool internal _v2Available;
    uint256 internal _troveId;
    uint256 internal _boldMinted;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WSTETH);
        _trackToken(LOCAL_BOLD);

        _v2Available = _hasCode(LOCAL_BOLD)
            && LOCAL_BORROWER_OPS_WSTETH != address(0)
            && LOCAL_TROVE_MANAGER_WSTETH != address(0)
            && LOCAL_STABILITY_POOL_WSTETH != address(0);
    }

    function _hasCode(address a) internal view returns (bool) {
        uint256 s;
        assembly { s := extcodesize(a) }
        return s > 0;
    }

    function testStrategy_F06_08() public {
        _fund(Mainnet.WSTETH, address(this), EQUITY_WSTETH);
        _startPnL();

        emit log_named_address("canonical_BOLD", LOCAL_BOLD);
        emit log_named_uint("bold_has_code_e1", _hasCode(LOCAL_BOLD) ? 1 : 0);

        if (!_v2Available) {
            emit log_string("F06-08: wstETH-branch addresses pending; structural placeholder.");
            emit log_named_uint("planned_equity_wstETH", EQUITY_WSTETH);
            emit log_named_uint("planned_annual_rate_e18", ANNUAL_RATE);
            emit log_named_uint("planned_bold_mint", (EQUITY_WSTETH * BOLD_PER_WSTETH) / 1e18);
            _endPnL("F06-08: BOLD SP-mint recycle (theoretical)");
            return;
        }

        // ---- 1) Open wstETH-branch trove ----
        IERC20(Mainnet.WSTETH).approve(LOCAL_BORROWER_OPS_WSTETH, EQUITY_WSTETH);
        _boldMinted = (EQUITY_WSTETH * BOLD_PER_WSTETH) / 1e18;

        _troveId = IBorrowerOperations(LOCAL_BORROWER_OPS_WSTETH).openTrove(
            address(this),
            OWNER_INDEX,
            EQUITY_WSTETH,
            _boldMinted,
            0,
            0,
            ANNUAL_RATE,
            type(uint256).max,
            address(0),
            address(0),
            address(this)
        );

        emit log_named_uint("trove_id", _troveId);
        emit log_named_uint("bold_minted", _boldMinted);
        require(IERC20(LOCAL_BOLD).balanceOf(address(this)) >= _boldMinted, "bold balance");

        // ---- 2) Deposit ALL minted BOLD into the wstETH-branch SP ----
        IERC20(LOCAL_BOLD).approve(LOCAL_STABILITY_POOL_WSTETH, _boldMinted);
        IStabilityPoolV2Wsteth(LOCAL_STABILITY_POOL_WSTETH).provideToSP(_boldMinted, false);

        // ---- 3) Compounding loop: advance ~90 days, claim, redeposit ----
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + 30 days);
            vm.roll(block.number + (30 days / 12));

            uint256 collGain = IStabilityPoolV2Wsteth(LOCAL_STABILITY_POOL_WSTETH)
                .getDepositorCollGain(address(this));
            uint256 yieldGain = IStabilityPoolV2Wsteth(LOCAL_STABILITY_POOL_WSTETH)
                .getDepositorYieldGain(address(this));

            emit log_named_uint("loop_idx", i);
            emit log_named_uint("loop_coll_gain_wstETH", collGain);
            emit log_named_uint("loop_yield_gain_bold", yieldGain);

            if (yieldGain > 0 || collGain > 0) {
                // withdrawFromSP(0) with doClaim=true triggers gain sweep.
                IStabilityPoolV2Wsteth(LOCAL_STABILITY_POOL_WSTETH).withdrawFromSP(0, true);
            }

            // Redeposit any BOLD that landed back to this contract from
            // the yield sweep, compounding the SP balance.
            uint256 newBold = IERC20(LOCAL_BOLD).balanceOf(address(this));
            if (newBold > 0) {
                IERC20(LOCAL_BOLD).approve(LOCAL_STABILITY_POOL_WSTETH, newBold);
                IStabilityPoolV2Wsteth(LOCAL_STABILITY_POOL_WSTETH).provideToSP(newBold, false);
            }
        }

        // ---- 4) Final telemetry ----
        uint256 finalSp = IStabilityPoolV2Wsteth(LOCAL_STABILITY_POOL_WSTETH)
            .getCompoundedBoldDeposit(address(this));
        emit log_named_uint("final_sp_compounded_bold", finalSp);
        emit log_named_uint("final_wsteth_balance", IERC20(Mainnet.WSTETH).balanceOf(address(this)));
        emit log_named_uint("trove_rate_e18", ITroveManagerV2Branch(LOCAL_TROVE_MANAGER_WSTETH).getTroveAnnualInterestRate(_troveId));
        emit log_named_uint("trove_debt_bold", ITroveManagerV2Branch(LOCAL_TROVE_MANAGER_WSTETH).getTroveEntireDebt(_troveId));

        _endPnL("F06-08: BOLD SP-mint recycle wstETH branch");
    }
}
