// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IBalancerVault} from "src/interfaces/amm/IBalancerVault.sol";
import {IFlashLoanRecipientBalancer} from "src/interfaces/common/IFlashLoanReceiver.sol";

/// @title F08-02 — USDe peg arbitrage via Balancer flash + dual Curve pools
/// @notice Atomic single-tx PoC.
///         1. Balancer V2 flash USDT (0 fee) for size N.
///         2. Swap USDT -> USDe on Curve USDe/USDT pool (the depegged side,
///            where USDe trades at a discount, i.e. USDT buys > 1 USDe).
///         3. Swap USDe -> USDC on Curve USDe/USDC pool (the on-peg side,
///            where USDe is closer to $1).
///         4. Swap USDC -> USDT on Curve 3pool (DAI/USDC/USDT) to repay flash.
///         5. Profit = USDT residual (after repaying the flash principal).
///
///         The arb is purely atomic; no inventory carried across blocks.
///         Triggers only when the two Curve USDe pools quote different
///         marginal prices for USDe in size — a routinely observable
///         condition during ETH liquidation cascades and Ethena yield-event
///         deposit surges.
contract F08_02_UsdePegArbTest is StrategyBase, IFlashLoanRecipientBalancer {
    // ---- Pinned constants ----

    /// @dev Block 19,500,000 (~Mar 2024). USDe pools had material spreads
    ///      between USDe/USDT and USDe/USDC venues during Mar 2024 ETH
    ///      funding spikes.
    uint256 constant FORK_BLOCK = 19_500_000;

    /// @dev Curve USDe/USDT factory pool. coins[0]=USDe, coins[1]=USDT.
    ///      TODO verify: pool address at the fork block.
    address constant CURVE_USDE_USDT = 0xa8a04E5d50e16fAFD127DbE9D5d2D5dCF4946e0C;

    /// @dev Curve USDe/USDC factory pool. coins[0]=USDe, coins[1]=USDC.
    ///      TODO verify: pool address at the fork block.
    address constant CURVE_USDE_USDC = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72;

    /// @dev Curve 3pool. coins: [DAI(0), USDC(1), USDT(2)].
    address constant CURVE_3POOL = Mainnet.CURVE_3POOL;

    /// @dev Notional probe size (USDT, 6 dec).
    uint256 constant FLASH_USDT = 1_000_000e6;

    /// @dev Sentinel: if our auto-detect step finds no edge, we still want the
    ///      transaction to mine cleanly so the test reports `no_arb`.
    bool public arbExecuted;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.USDT);
        _trackToken(Mainnet.USDE);
    }

    function testStrategy_F08_02() public {
        _startPnL();

        // Pre-flight quote: estimate end-to-end profitability.
        // USDT -> USDe on USDT pool, USDe -> USDC on USDC pool, USDC -> USDT on 3pool.
        uint256 q1 = ICurveStableSwap(CURVE_USDE_USDT).get_dy(int128(1), int128(0), FLASH_USDT);          // USDT -> USDe
        uint256 q2 = ICurveStableSwap(CURVE_USDE_USDC).get_dy(int128(0), int128(1), q1);                  // USDe -> USDC
        uint256 q3 = ICurveStableSwap(CURVE_3POOL).get_dy(int128(1), int128(2), q2);                      // USDC -> USDT

        emit log_named_uint("quote_in_usdt", FLASH_USDT);
        emit log_named_uint("quote_out_usdt", q3);

        // No-arb path: if quoted output is not strictly greater than flash size,
        // skip executing and just log.
        if (q3 <= FLASH_USDT) {
            emit log("no_arb: spread did not cover route");
            _endPnL("F08-02: USDe peg arb (no-op)");
            return;
        }

        // Otherwise, take the flash loan and execute.
        address[] memory tokens = new address[](1);
        tokens[0] = Mainnet.USDT;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = FLASH_USDT;
        IBalancerVault(Mainnet.BAL_VAULT).flashLoan(address(this), tokens, amounts, "");
        require(arbExecuted, "arb did not run");

        _endPnL("F08-02: USDe peg arb");
    }

    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory /*userData*/
    ) external override {
        require(msg.sender == Mainnet.BAL_VAULT, "callback: not balancer vault");
        require(tokens[0] == Mainnet.USDT, "callback: wrong token");
        require(feeAmounts[0] == 0, "callback: expected 0 fee");

        uint256 amt = amounts[0];

        // Approve all three pools.
        _approveOnce(Mainnet.USDT, CURVE_USDE_USDT);
        _approveOnce(Mainnet.USDE, CURVE_USDE_USDC);
        _approveOnce(Mainnet.USDC, CURVE_3POOL);

        // Leg 1: USDT -> USDe on the discount-side pool.
        uint256 usdeOut = ICurveStableSwap(CURVE_USDE_USDT).exchange(int128(1), int128(0), amt, 0);

        // Leg 2: USDe -> USDC on the peg-side pool.
        uint256 usdcOut = ICurveStableSwap(CURVE_USDE_USDC).exchange(int128(0), int128(1), usdeOut, 0);

        // Leg 3: USDC -> USDT on 3pool.
        uint256 usdtBack = ICurveStableSwap(CURVE_3POOL).exchange(int128(1), int128(2), usdcOut, 0);

        // Sanity: arb must yield enough to repay flash principal in full.
        require(usdtBack >= amt + feeAmounts[0], "arb: insufficient to repay flash");
        emit log_named_uint("usdt_back", usdtBack);
        emit log_named_uint("gross_profit_usdt", usdtBack - amt);

        // Repay Balancer (it pulls via transfer, push pattern).
        IERC20(Mainnet.USDT).transfer(Mainnet.BAL_VAULT, amt + feeAmounts[0]);
        arbExecuted = true;
    }

    function _approveOnce(address token, address spender) internal {
        if (IERC20(token).allowance(address(this), spender) == 0) {
            // USDT requires zero-approve before re-approve, so use forceApprove-style.
            // For first-time approval set to max directly.
            (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max));
            require(ok, "approve fail");
        }
    }
}
