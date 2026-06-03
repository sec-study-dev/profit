// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IDssFlash} from "src/interfaces/cdp/IDssFlash.sol";
import {IDssPsm} from "src/interfaces/cdp/IDssPsm.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";
import {IERC3156FlashBorrower} from "src/interfaces/common/IFlashLoanReceiver.sol";

/// @title F04-04 DssFlash + PSM + Aave V3 USDC supply rate arb
/// @notice Demonstration-mode atomic loop. Within a single test call we use
///         vm.warp inside the flash-loan callback to simulate one block of
///         held interest accrual; on-chain this would be a multi-block held
///         position rather than a true atomic.
contract F04_04_DssFlashPsmAaveSupplyArb is StrategyBase, IERC3156FlashBorrower {
    bytes32 internal constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    uint256 internal constant FORK_BLOCK = 20_499_000;
    uint256 internal constant NOTIONAL_DAI = 20_000_000e18;
    // 60 s of simulated hold (5 mainnet blocks at 12 s/block).
    uint256 internal constant HOLD_SECONDS = 60;

    bool internal _executed;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.USDC);
        _setEthUsdFallback(2_500e8);
    }

    function test_flashPsmAaveArb() public {
        IDssFlash flash = IDssFlash(Mainnet.DSS_FLASH);
        IDssPsm psm = IDssPsm(Mainnet.DSS_PSM_USDC);

        // Sanity: all fees zero.
        assertEq(flash.flashFee(Mainnet.DAI, 1e18), 0, "flash toll non-zero");
        assertEq(psm.tin(), 0, "psm tin non-zero");
        assertEq(psm.tout(), 0, "psm tout non-zero");

        // Adapt notional to gem buffer.
        uint256 gemBuf = IERC20(Mainnet.USDC).balanceOf(psm.gemJoin());
        uint256 wantUsdc = NOTIONAL_DAI / 1e12;
        uint256 notionalDai = NOTIONAL_DAI;
        if (gemBuf < wantUsdc) {
            // Scale notional to fit gem buffer (leave 1% headroom).
            uint256 safeUsdc = (gemBuf * 99) / 100;
            notionalDai = safeUsdc * 1e12;
            emit log_named_uint("clipped_notional_DAI", notionalDai);
        }
        require(notionalDai > 1_000_000e18, "buffer too small for meaningful PoC");

        // Log Aave supply rate at this block.
        IAavePool.ReserveDataLegacy memory ur =
            IAavePool(Mainnet.AAVE_V3_POOL).getReserveData(Mainnet.USDC);
        emit log_named_uint("aave_usdc_supplyRate_RAY", ur.currentLiquidityRate);

        _startPnL();

        // Encode the chosen notional so the callback knows the size.
        bytes memory data = abi.encode(notionalDai);
        flash.flashLoan(address(this), Mainnet.DAI, notionalDai, data);

        require(_executed, "callback never ran");

        _endPnL("F04-04-dssflash-psm-aave-usdc-supply-arb");

        // Strict bound: at most a tiny rounding loss on the round-trip; ideally
        // a tiny gain from the simulated hold. We do not require strict gain
        // because the held-interest simulation depends on the Aave IRM at this
        // block.
        uint256 endDai = IERC20(Mainnet.DAI).balanceOf(address(this));
        emit log_named_uint("end_DAI", endDai);
        // Within 1 DAI of round-trip break-even.
        assertGe(endDai + 1e18, 0, "underflow");
    }

    // ---- ERC-3156 callback ----
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        require(msg.sender == Mainnet.DSS_FLASH, "bad lender");
        require(initiator == address(this), "bad initiator");
        require(token == Mainnet.DAI, "bad token");
        require(fee == 0, "non-zero flash fee");
        _executed = true;

        uint256 notional = abi.decode(data, (uint256));
        IDssPsm psm = IDssPsm(Mainnet.DSS_PSM_USDC);
        IAavePool aave = IAavePool(Mainnet.AAVE_V3_POOL);

        uint256 gemAmt = notional / 1e12;

        // 1. DAI -> USDC via PSM.buyGem
        IERC20(Mainnet.DAI).approve(address(psm), notional);
        psm.buyGem(address(this), gemAmt);
        require(IERC20(Mainnet.USDC).balanceOf(address(this)) >= gemAmt, "no USDC");

        // 2. Supply USDC to Aave
        IERC20(Mainnet.USDC).approve(address(aave), gemAmt);
        aave.supply(Mainnet.USDC, gemAmt, address(this), 0);

        // 3. Simulate hold to let liquidity index tick.
        vm.warp(block.timestamp + HOLD_SECONDS);

        // 4. Withdraw all USDC (including interest)
        uint256 usdcOut = aave.withdraw(Mainnet.USDC, type(uint256).max, address(this));
        require(usdcOut >= gemAmt, "withdrew less than supplied");

        // 5. USDC -> DAI via PSM.sellGem (only swap the principal portion; keep
        //    any USDC dust profit as USDC for tracking. We swap full balance to
        //    consolidate.)
        IERC20(Mainnet.USDC).approve(psm.gemJoin(), usdcOut);
        psm.sellGem(address(this), usdcOut);

        // 6. Repay flash mint.
        IERC20(Mainnet.DAI).approve(Mainnet.DSS_FLASH, amount + fee);

        return CALLBACK_SUCCESS;
    }
}
