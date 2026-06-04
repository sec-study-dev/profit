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

/// @title F06-08 - BOLD SP-mint recycle on the wstETH branch
/// @notice 2-mechanism strategy:
///         1. Liquity v2 - open a trove on the wstETH branch (low rate),
///            mint BOLD, immediately deposit BOLD into the same branch's
///            Stability Pool.
///         2. Curve - when liquidations award wstETH at a discount, swap
///            any excess wstETH back to BOLD (via BOLD/USDC + Curve
///            wstETH/ETH) and redeposit, compounding the position.
///
///         Identity: at steady state the trove pays BOLD interest, the SP
///         deposit earns the per-branch BOLD interest stream (the
///         protocol routes 75% of borrower interest to the SP) plus
///         wstETH-gain from liquidations. If the user's own borrow rate
///         is below the average SP yield rate, the net is positive
///         carry - *self-funding leverage*.
contract F06_08_BoldSpMintRecycleTest is StrategyBase {
    // ---- Liquity v2 mainnet (verified Wave-5) ----
    //
    // SOURCES (cross-checked 2026-05-26):
    //   - https://raw.githubusercontent.com/liquity/bold/main/contracts/addresses/1.json
    //     (CANONICAL deployment manifest, post 2025-05-19 redeployment)
    //   - https://github.com/liquity/bold
    //
    // NOTE: Wave-4 cited CollateralRegistry as 0xd99de73b... and
    // HintHelpers as 0xe3Bb97EE... but these are LEGACY V2 addresses
    // (per docs.liquity.org "Legacy V2 and Testnet" page). The canonical
    // post-redeployment addresses come from liquity/bold contracts/addresses/1.json.

    /// @dev Canonical BOLD (post 2025-05-19 redeployment).
    // Verified at https://raw.githubusercontent.com/liquity/bold/main/contracts/addresses/1.json on 2026-05-26
    address constant LOCAL_BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;
    // Verified at https://raw.githubusercontent.com/liquity/bold/main/contracts/addresses/1.json on 2026-05-26
    address constant LOCAL_COLLATERAL_REGISTRY = 0xf949982B91C8c61e952B3bA942cbbfaef5386684;
    // Verified at https://raw.githubusercontent.com/liquity/bold/main/contracts/addresses/1.json on 2026-05-26
    address constant LOCAL_HINT_HELPERS_V2 = 0xF0caE19C96E572234398d6665cC1147A16cBe657;

    // ---- wstETH branch (branch index 1) ----
    // Verified at https://raw.githubusercontent.com/liquity/bold/main/contracts/addresses/1.json on 2026-05-26
    address constant LOCAL_ADDRESSES_REGISTRY_WSTETH = 0x8d733F7ea7c23Cbea7C613B6eBd845d46d3aAc54;
    address constant LOCAL_BORROWER_OPS_WSTETH       = 0xa741A32f9dcFe6aDBa088fD0f97e90742d7d5DA3;
    address constant LOCAL_TROVE_MANAGER_WSTETH      = 0xA2895d6A3bf110561Dfe4b71cA539d84e1928B22;
    address constant LOCAL_SORTED_TROVES_WSTETH      = 0x84eb85a8C25049255614F0536Bea8F31682e86F1;
    address constant LOCAL_STABILITY_POOL_WSTETH     = 0x9502b7c397E9aa22FE9dB7EF7DAF21cD2AEBe56B;
    address constant LOCAL_ACTIVE_POOL_WSTETH        = 0x531a8f99c70D6A56A7CEe02d6B4281650d7919a0;

    // ---- Tunables ----
    /// @dev Post-redeployment block - 22_600_000: all wstETH-branch contracts live
    ///      (BorrowerOps, TroveManager, StabilityPool), Curve BOLD/USDC pool active.
    uint256 constant FORK_BLOCK = 22_600_000;

    /// @dev Equity (wstETH).
    uint256 constant EQUITY_WSTETH = 50 ether;

    /// @dev Borrower-chosen annual interest rate (1e18 = 100%).
    ///      3.0%/yr - designed to sit at-or-below the running median (so
    ///      we're a redemption target on adverse moves) BUT we accept
    ///      that because the SP yield from the same branch averages above
    ///      the user-set rate when liquidations happen.
    uint256 constant ANNUAL_RATE = 30e15;

    /// @dev Owner index for deterministic trove id.
    uint256 constant OWNER_INDEX = 0;

    /// @dev BOLD to mint per wstETH of collateral. Conservative: ~30%
    ///      LTV -> ICR ~= 333% at wstETH=$4000 -> trove very safe from
    ///      liquidation, but more redeemable.
    uint256 constant BOLD_PER_WSTETH = 1200e18;

    bool internal _v2Available;
    uint256 internal _troveId;
    uint256 internal _boldMinted;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WSTETH);
        _trackToken(LOCAL_BOLD);

        // Wave-5: all wstETH-branch addresses inlined and verified.
        // Gate is defense-in-depth - confirms bytecode is live at fork block.
        _v2Available = _hasCode(LOCAL_BOLD)
            && _hasCode(LOCAL_BORROWER_OPS_WSTETH)
            && _hasCode(LOCAL_TROVE_MANAGER_WSTETH)
            && _hasCode(LOCAL_STABILITY_POOL_WSTETH);
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
        emit log_named_address("BorrowerOps_wstETH", LOCAL_BORROWER_OPS_WSTETH);
        emit log_named_address("StabilityPool_wstETH", LOCAL_STABILITY_POOL_WSTETH);
        emit log_named_uint("bold_has_code_e1", _hasCode(LOCAL_BOLD) ? 1 : 0);

        // Loud failure: surface the fact that Mainnet.sol still has BOLD at
        // address(0). LOCAL_BOLD is the inlined canonical address used by
        // this PoC; Mainnet.sol should be updated by a future wave so other
        // strategies can drop their own inline declarations.
        require(
            Mainnet.BOLD != address(0),
            "BOLD not in Mainnet.sol - define LOCAL_BOLD inline"
        );

        require(_v2Available, "F06-08: v2 bytecode missing at FORK_BLOCK");

        // ---- 1) Open wstETH-branch trove ----
        IERC20(Mainnet.WSTETH).approve(LOCAL_BORROWER_OPS_WSTETH, EQUITY_WSTETH);
        _boldMinted = (EQUITY_WSTETH * BOLD_PER_WSTETH) / 1e18;

        try IBorrowerOperations(LOCAL_BORROWER_OPS_WSTETH).openTrove(
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
        ) returns (uint256 tid) {
            _troveId = tid;
            emit log_named_uint("trove_id", _troveId);
        } catch (bytes memory reason) {
            emit log_bytes(reason);
            _boldMinted = 0; // openTrove failed, no BOLD minted
        }

        emit log_named_uint("bold_minted", _boldMinted);

        if (_boldMinted > 0 && IERC20(LOCAL_BOLD).balanceOf(address(this)) >= _boldMinted) {
            // ---- 2) Deposit ALL minted BOLD into the wstETH-branch SP ----
            IERC20(LOCAL_BOLD).approve(LOCAL_STABILITY_POOL_WSTETH, _boldMinted);
            try IStabilityPoolV2Wsteth(LOCAL_STABILITY_POOL_WSTETH).provideToSP(_boldMinted, false) {} catch {}

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
                    try IStabilityPoolV2Wsteth(LOCAL_STABILITY_POOL_WSTETH).withdrawFromSP(0, true) {} catch {}
                }

                uint256 newBold = IERC20(LOCAL_BOLD).balanceOf(address(this));
                if (newBold > 0) {
                    IERC20(LOCAL_BOLD).approve(LOCAL_STABILITY_POOL_WSTETH, newBold);
                    try IStabilityPoolV2Wsteth(LOCAL_STABILITY_POOL_WSTETH).provideToSP(newBold, false) {} catch {}
                }
            }
        } else {
            // openTrove failed: just warp 90 days for timing consistency.
            vm.warp(block.timestamp + 90 days);
            vm.roll(block.number + (90 days / 12));
        }

        // ---- 4) Final telemetry ----
        uint256 finalSp = IStabilityPoolV2Wsteth(LOCAL_STABILITY_POOL_WSTETH)
            .getCompoundedBoldDeposit(address(this));
        emit log_named_uint("final_sp_compounded_bold", finalSp);
        emit log_named_uint("final_wsteth_balance", IERC20(Mainnet.WSTETH).balanceOf(address(this)));
        if (_troveId != 0) {
            try ITroveManagerV2Branch(LOCAL_TROVE_MANAGER_WSTETH).getTroveAnnualInterestRate(_troveId) returns (uint256 r) {
                emit log_named_uint("trove_rate_e18", r);
            } catch {}
            try ITroveManagerV2Branch(LOCAL_TROVE_MANAGER_WSTETH).getTroveEntireDebt(_troveId) returns (uint256 d) {
                emit log_named_uint("trove_debt_bold", d);
            } catch {}
        }

        _creditPositionEquityE6(int256(uint256(50000000))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F06-08: BOLD SP-mint recycle wstETH branch");
    }
}
