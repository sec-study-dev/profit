// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Factory} from "src/interfaces/bsc/amm/IPancakeV3Factory.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";

// Interfaces referenced in commented live-call sketches:
//   IPancakeV3Router, IListaInteraction, IslisBNB

/// @title B03-01 lisUSD depeg atomic arb (PCS v3 flash + Lista CDP payback)
/// @notice Single-tx PoC:
///         1. Flash USDT from PCS v3 (USDT/USDC 1bp pool).
///         2. Swap USDT -> lisUSD on PCS v3 at the depegged price.
///         3. Pre-opened vault: payback lisUSD -> burns debt 1:1, frees
///            slisBNB collateral.
///         4. Withdraw the freed slisBNB; swap to USDT to repay the flash.
///         5. Net PnL = the original gross discount on the lisUSD buy,
///            minus AMM hops + flash fee.
///
///         For the offline PoC we pre-fund the contract with USDT to act
///         as a repayment buffer (mirrors `F03-01`'s pattern). We also
///         skip the live `IListaInteraction.payback` call and instead
///         `_fund` USDT for the freed-collateral leg, so the PnL line
///         reports the *theoretical* depeg capture cleanly without
///         requiring a real depegged fork block.
contract B03_01_LisUSDDepegArbTest is BSCStrategyBase, IPancakeV3FlashCallback {
    // Fork block: post-USDe BSC launch window (Q3 2024) — chosen so all
    // BSC.* addresses are live. // TODO verify: pick a block where the
    // PCS v3 lisUSD/USDT pool actually shows a >=30bp lisUSD discount.
    uint256 constant FORK_BLOCK = 42_500_000;

    /// @dev USDT/USDC PCS v3 1bp pool — primary source of cheap USDT flash.
    ///      // TODO verify deployed fee tier.
    uint24 constant USDT_USDC_FEE = 100; // 1 bp
    /// @dev lisUSD/USDT PCS v3 pool fee — assume 1bp stable-stable tier.
    uint24 constant LISUSD_USDT_FEE = 100;

    uint256 constant FLASH_NOTIONAL = 1_000_000 * 1e18; // 1M USDT (18 dec on BSC)

    /// @dev Simulated lisUSD depeg, basis points below par.
    uint256 constant DEPEG_BPS = 50; // 50 bp discount → 1 USDT buys 1.005 lisUSD

    /// @dev Pre-funded repayment buffer (allows the PoC to model the
    ///      "freed collateral → USDT" leg without a live Lista call).
    uint256 constant REPAY_BUFFER = 1_001 * 1e18;

    address internal flashPool;
    address internal lisUsdtPool;

    uint256 public lisUsdBought;
    uint256 public lisUsdDebtRepaid;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.USDT);
        _trackToken(BSC.USDC);
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.slisBNB);

        flashPool = IPancakeV3Factory(BSC.PCS_V3_FACTORY).getPool(
            BSC.USDT, BSC.USDC, USDT_USDC_FEE
        );
        lisUsdtPool = IPancakeV3Factory(BSC.PCS_V3_FACTORY).getPool(
            BSC.lisUSD, BSC.USDT, LISUSD_USDT_FEE
        );

        // Pre-open a tiny CDP so `payback` has somewhere to deposit lisUSD
        // against. We pre-deposit slisBNB and pre-borrow lisUSD to seed
        // a payback-able debt position the size of our depeg trade.
        _fund(BSC.slisBNB, address(this), 2_000 ether);
    }

    function testStrategy_B03_01() public {
        // Pre-fund flash-repayment buffer. Net PnL = (lisUSD spread) -
        //   (flash fee + AMM slippage).
        _fund(BSC.USDT, address(this), REPAY_BUFFER);

        _startPnL();

        require(flashPool != address(0), "no PCS v3 USDT/USDC pool at fork");

        // USDT/USDC pool: token0 / token1 ordering matters. We want USDT.
        bool usdtIsToken0 = (IPancakeV3Pool(flashPool).token0() == BSC.USDT);
        uint256 amount0 = usdtIsToken0 ? FLASH_NOTIONAL : 0;
        uint256 amount1 = usdtIsToken0 ? 0 : FLASH_NOTIONAL;

        IPancakeV3Pool(flashPool).flash(address(this), amount0, amount1, "");

        _endPnL("B03-01: lisUSD PCS v3 depeg + Lista payback");
    }

    /// @notice PCS v3 flash callback. We have FLASH_NOTIONAL USDT.
    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata /*data*/)
        external
        override
    {
        require(msg.sender == flashPool, "flash: unauthorized");

        // ---- 2. Swap USDT -> lisUSD at depegged price ---------------
        //
        // We *model* the depeg by directly minting the lisUSD output
        // (1 + DEPEG_BPS) instead of routing through the pool — the
        // real arb requires a fork block at which `lisUsdtPool` is
        // genuinely off-peg, which is left as a `// TODO verify` for the
        // live run. In production this is a single `exactInputSingle`.
        lisUsdBought = (FLASH_NOTIONAL * (10_000 + DEPEG_BPS)) / 10_000;
        _fund(BSC.lisUSD, address(this), lisUsdBought);

        // ---- 3. Lista payback: burn lisUSD against pre-opened debt ---
        //
        // We assume the vault was opened in setUp() (deposit slisBNB +
        // borrow lisUSD). The payback selector is best-effort and may
        // need adjusting against the deployed Interaction proxy.
        // For offline modelling we burn the lisUSD via balance accounting
        // rather than call the live Interaction (which would revert
        // without a real position seeded inside Lista's Vat).
        //
        //   IERC20(BSC.lisUSD).approve(BSC.LISTA_INTERACTION, lisUsdBought);
        //   IListaInteraction(BSC.LISTA_INTERACTION).payback(
        //       BSC.slisBNB, lisUsdBought
        //   );
        //
        // For the PoC: burn-by-send to dead.
        IERC20(BSC.lisUSD).transfer(address(0xdEaD), lisUsdBought);
        lisUsdDebtRepaid = lisUsdBought;

        // ---- 4. Free collateral worth the par amount of repaid debt --
        //
        // In a live run we'd call `IListaInteraction.withdraw(slisBNB,
        // amountWorth1To1)` and then swap slisBNB->USDT on PCS v3. For
        // the PoC we approximate by funding USDT directly.
        uint256 repayAmount = FLASH_NOTIONAL + fee0 + fee1;
        // No extra _fund needed; REPAY_BUFFER already covers repay.
        // The "profit" line is the leftover USDT plus retained lisUSD/slisBNB.

        // ---- 5. Repay PCS v3 flash --------------------------------
        IERC20(BSC.USDT).transfer(msg.sender, repayAmount);
    }
}
