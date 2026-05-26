// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IBalancerVault} from "src/interfaces/amm/IBalancerVault.sol";
import {IFlashLoanRecipientBalancer} from "src/interfaces/common/IFlashLoanReceiver.sol";

/// @title F08-09 - Ethena minting arbitrage: mint USDe at $1, sell at premium on Curve
/// @notice **Three-mechanism composition** capturing the structural arb between
///         Ethena's RFQ minting (always fair-value at $1) and Curve's secondary
///         USDe market (which can trade at a premium during yield-event deposit
///         surges).
///
///         The canonical loop:
///         1. **Balancer V2 flashloan** funds the mint collateral (USDT/USDC).
///         2. **EthenaMinting v2** (`0xe3490297a08d6fC8Da46Edb7B6142E4F461b62D3`)
///            mints USDe at $1 in exchange for the collateral asset - gated on
///            an EIP-712 signed RFQ from one of Ethena's market makers.
///         3. **Curve USDe/USDC** sells the freshly-minted USDe at the
///            secondary-market premium for clean USDC. Excess USDC closes the
///            Balancer flash and books PnL.
///
///         ## RFQ-signature simulation
///
///         The real EthenaMinting flow requires a signed Order from one of
///         Ethena's whitelisted market makers - not reproducible inside a
///         forge fork. The PoC simulates the mint atomically by:
///           - Deducting `collateral_amount` of the input asset from the
///             contract (representing the mint outflow).
///           - Crediting `usde_amount == collateral_amount` USDe at $1 par
///             via `deal()` (representing the protocol mint).
///         The simulation preserves accounting invariants - the strategy's
///         net cash flow is identical to a real RFQ mint at $1.
///
///         When EthenaMinting is exercised in production, the simulation
///         block is replaced with a single `IEthenaMinting.mint(order, sig)`
///         call after an off-chain RFQ co-sign.
contract F08_09_EthenaMintCurveBalancerArbTest is StrategyBase, IFlashLoanRecipientBalancer {
    // ---- Pinned constants ----

    /// @dev Block 20_100_000 (~Jul 2024). USDe had episodic premiums on the
    ///      Curve USDC pool during the Jul-2024 sUSDe-yield uplift news cycle.
    uint256 constant FORK_BLOCK = 20_100_000;

    /// @dev Ethena canonical minting contract (EthenaMinting v2). Verified via
    ///      Etherscan tags and Ethena docs. Mint requires EIP-712 signature.
    address constant LOCAL_ETHENA_MINTING_V2 = 0xe3490297a08d6fC8Da46Edb7B6142E4F461b62D3;

    /// @dev Curve USDe/USDC factory pool (coin 0 = USDe, coin 1 = USDC).
    address constant LOCAL_CURVE_USDE_USDC = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72;

    /// @dev Notional probe - flashloan in USDC, mint USDe, sell USDe back to USDC.
    uint256 constant FLASH_USDC = 2_000_000e6;

    /// @dev Minimum premium (bps over face) to execute. Below this, the arb is
    ///      not worth gas + Balancer fee + Curve fees + signature/operational cost.
    uint256 constant MIN_PREMIUM_BPS = 15; // 0.15%

    bool public arbExecuted;
    uint256 public realisedPremiumBps;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.USDE);

        require(
            ICurveStableSwap(LOCAL_CURVE_USDE_USDC).coins(0) == Mainnet.USDE,
            "F08-09: curve coin0 != USDe"
        );
        require(
            ICurveStableSwap(LOCAL_CURVE_USDE_USDC).coins(1) == Mainnet.USDC,
            "F08-09: curve coin1 != USDC"
        );

        // Sanity-check the EthenaMinting address has code at the fork block.
        // We don't call it - only verify the contract exists so the PoC
        // surfaces a clear failure if the address constant drifts.
        uint256 size;
        address addr = LOCAL_ETHENA_MINTING_V2;
        assembly {
            size := extcodesize(addr)
        }
        require(size > 0, "F08-09: EthenaMinting v2 has no code at fork block");
    }

    function testStrategy_F08_09() public {
        _startPnL();

        // ---- Quote: would the round trip USDC -> USDe (mint at $1) -> USDC
        //                                                       (sell on Curve) profit? ----
        //
        // Mint side returns 1 USDe per 1 USDC face (1e12 scale).
        uint256 usdeFromMint = FLASH_USDC * 1e12; // 18-dec USDe per 6-dec USDC
        // Sell side quote on Curve: USDe (idx 0) -> USDC (idx 1).
        uint256 usdcFromSell = ICurveStableSwap(LOCAL_CURVE_USDE_USDC).get_dy(
            int128(0), int128(1), usdeFromMint
        );

        emit log_named_uint("quote_usdc_in", FLASH_USDC);
        emit log_named_uint("quote_usde_minted", usdeFromMint);
        emit log_named_uint("quote_usdc_out", usdcFromSell);

        if (usdcFromSell <= FLASH_USDC) {
            // Premium is negative (USDe below par on Curve) - no arb path.
            emit log("no_arb: USDe trading at discount; mint arb not profitable");
            _endPnL("F08-09: Ethena mint arb (no-op)");
            return;
        }

        uint256 premiumBps = ((usdcFromSell - FLASH_USDC) * 10_000) / FLASH_USDC;
        realisedPremiumBps = premiumBps;
        emit log_named_uint("realised_premium_bps", premiumBps);

        if (premiumBps < MIN_PREMIUM_BPS) {
            emit log("no_arb: premium below MIN_PREMIUM_BPS gate");
            _endPnL("F08-09: Ethena mint arb (premium too small)");
            return;
        }

        // ---- Execute via Balancer flashloan ----
        address[] memory tokens = new address[](1);
        tokens[0] = Mainnet.USDC;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = FLASH_USDC;
        IBalancerVault(Mainnet.BAL_VAULT).flashLoan(address(this), tokens, amounts, "");
        require(arbExecuted, "F08-09: arb did not run");

        _endPnL("F08-09: Ethena mint + Curve + Balancer flash arb");
    }

    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory /*userData*/
    ) external override {
        require(msg.sender == Mainnet.BAL_VAULT, "F08-09: callback not Balancer");
        require(tokens[0] == Mainnet.USDC, "F08-09: callback wrong token");
        require(feeAmounts[0] == 0, "F08-09: expected 0 Balancer fee");

        uint256 usdcIn = amounts[0];

        // ---- Step A: simulate EthenaMinting RFQ mint at $1 par ----
        //
        // In production:
        //   IEthenaMinting.Order order = (signed off-chain by Ethena MM);
        //   IEthenaMinting.Signature sig = (Ethena MM signature);
        //   IERC20(USDC).approve(EthenaMinting, usdcIn);
        //   IEthenaMinting(LOCAL_ETHENA_MINTING_V2).mint(order, sig);
        // Result: contract burns `usdcIn` USDC, receives `usdcIn * 1e12` USDe.
        //
        // Fork-PoC: we deduct USDC and credit USDe at the same $1 par. The
        // accounting is identical to the real mint; the only difference is
        // that no signature is verified on-chain.
        uint256 usdeMinted = usdcIn * 1e12;

        // Deduct USDC (simulate the collateral leaving the contract on mint).
        deal(Mainnet.USDC, address(this), IERC20(Mainnet.USDC).balanceOf(address(this)) - usdcIn);
        // Credit USDe (simulate the protocol mint output).
        deal(Mainnet.USDE, address(this), IERC20(Mainnet.USDE).balanceOf(address(this)) + usdeMinted);

        // ---- Step B: sell USDe -> USDC on Curve at the secondary premium ----
        _approveOnce(Mainnet.USDE, LOCAL_CURVE_USDE_USDC);
        uint256 usdcOut = ICurveStableSwap(LOCAL_CURVE_USDE_USDC).exchange(
            int128(0), int128(1), usdeMinted, 0
        );
        emit log_named_uint("usdc_out_from_curve_sell", usdcOut);

        // ---- Step C: repay Balancer flash ----
        uint256 repay = usdcIn + feeAmounts[0];
        require(usdcOut >= repay, "F08-09: insufficient USDC to repay flash");
        emit log_named_uint("gross_profit_usdc", usdcOut - repay);
        IERC20(Mainnet.USDC).transfer(Mainnet.BAL_VAULT, repay);

        arbExecuted = true;
    }

    function _approveOnce(address token, address spender) internal {
        if (IERC20(token).allowance(address(this), spender) == 0) {
            (bool ok,) = token.call(
                abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max)
            );
            require(ok, "F08-09: approve failed");
        }
    }
}
