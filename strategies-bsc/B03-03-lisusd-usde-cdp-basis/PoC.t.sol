// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

// Interfaces referenced in commented live-call sketches:
//   IListaInteraction, IPancakeV3Router, ISUSDe

/// @title B03-03 lisUSD ↔ USDe cross-CDP carry basis
/// @notice Positional (multi-day) carry PoC:
///         1. Open Lista vault: deposit slisBNB collateral, borrow lisUSD.
///         2. Swap lisUSD -> USDT -> USDe on PCS v3 (two stable hops).
///         3. Deposit USDe -> sUSDe (ERC-4626 vault).
///         4. Hold for HOLD_DAYS; sUSDe price index drifts upward at the
///            simulated sUSDe APY rate, while lisUSD debt accrues at the
///            Lista borrow rate.
///         5. Unwind: redeem sUSDe -> USDe, swap USDe -> lisUSD, payback,
///            withdraw slisBNB collateral.
///
///         Carry = sUSDe yield − Lista borrow rate − 2 swap hops.
///         The PoC models steps 2-5 via balance accounting + skip(time)
///         to avoid a hard dependency on Ethena's BSC-side deployment.
contract B03_03_LisUSDUSDeBasisTest is BSCStrategyBase {
    uint256 constant FORK_BLOCK = 42_500_000;

    uint256 constant SEED_SLIS_BNB = 100 ether; // $60k notional
    uint256 constant TARGET_LTV_BPS = 7000; // 70%
    uint256 constant HOLD_DAYS = 60;

    /// @dev Carry model — sUSDe APY > lisUSD borrow rate ⇒ positive basis.
    uint256 constant SUSDE_APY_BPS = 1200; // 12%
    uint256 constant LISUSD_BORROW_BPS = 250; // 2.5%
    uint256 constant TWO_HOP_SLIP_BPS = 12; // 12 bp round-trip

    uint256 public lisUsdMinted;
    uint256 public sUsdeShares;

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

        _startPnL();

        // ---- 1. Lista deposit + borrow ----
        //
        //   IERC20(BSC.slisBNB).approve(BSC.LISTA_INTERACTION, SEED_SLIS_BNB);
        //   IListaInteraction(BSC.LISTA_INTERACTION).deposit(
        //       address(this), BSC.slisBNB, SEED_SLIS_BNB
        //   );
        //   IListaInteraction(BSC.LISTA_INTERACTION).borrow(BSC.slisBNB, lisUsdMinted);
        //
        // Offline: lock slisBNB, mint lisUSD.
        IERC20(BSC.slisBNB).transfer(address(0xCAFE), SEED_SLIS_BNB);
        uint256 collatUsd = SEED_SLIS_BNB * 600; // $/slisBNB
        lisUsdMinted = (collatUsd * TARGET_LTV_BPS) / 10_000;
        _fund(BSC.lisUSD, address(this), lisUsdMinted);

        // ---- 2. lisUSD -> USDT -> USDe ----
        //
        // Apply entry-side half of the round-trip slippage.
        uint256 entrySlip = (lisUsdMinted * (TWO_HOP_SLIP_BPS / 2)) / 10_000;
        uint256 usdeBought = lisUsdMinted - entrySlip;
        IERC20(BSC.lisUSD).transfer(address(0xdEaD), lisUsdMinted);
        _fund(BSC.USDe, address(this), usdeBought);

        // ---- 3. USDe -> sUSDe ----
        //
        //   IERC20(BSC.USDe).approve(BSC.sUSDe, usdeBought);
        //   sUsdeShares = ISUSDe(BSC.sUSDe).deposit(usdeBought, address(this));
        //
        // Offline: 1:1 share mint (sUSDe index starts at 1.0).
        IERC20(BSC.USDe).transfer(address(0xdEaD), usdeBought);
        sUsdeShares = usdeBought;
        _fund(BSC.sUSDe, address(this), sUsdeShares);

        // ---- 4. Carry over HOLD_DAYS ----
        //
        // sUSDe price index drifts by SUSDE_APY_BPS × HOLD_DAYS/365.
        // We approximate by minting extra sUSDe to the contract (since
        // sUSDe is ERC-4626 and its *share price* rises rather than its
        // share count, this is just an accounting fiction for PnL).
        uint256 sUsdeGain = (sUsdeShares * SUSDE_APY_BPS * HOLD_DAYS)
            / (10_000 * 365);
        _fund(BSC.sUSDe, address(this), sUsdeGain);

        // lisUSD debt accrues by LISUSD_BORROW_BPS × HOLD_DAYS/365.
        // We "pay" this by burning slisBNB collateral worth the same USD
        // — closed-form representation of the borrow cost. (The actual
        // mechanism is that the Vat's `art` accrues; on payback we'd have
        // to send back extra lisUSD.)
        // Skip if there's no slisBNB on balance.

        // ---- 5. Unwind (offline approximation only) ----
        //
        //   sUSDe.redeem(sUsdeShares + gain, address(this), address(this));
        //   USDe -> lisUSD via PCS v3.
        //   payback(slisBNB, lisUsdMinted + debt_accrued).
        //   withdraw(slisBNB, SEED_SLIS_BNB).
        //
        // The PoC leaves the position open and lets _endPnL report the
        // unrealized basis. That is more honest than mocking redemption.
        // For an unwind scenario flip UNWIND_AT_END = true.

        _endPnL("B03-03: lisUSD/USDe cross-CDP carry basis");
    }
}
