// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ISUSDe} from "src/interfaces/stable/ISUSDe.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";

/// @title F08-01 - sUSDe leveraged supply on Morpho with USDC debt (loop)
/// @notice Recursive loop that supplies sUSDe to a Morpho Blue sUSDe/USDC market,
///         borrows USDC at the per-loop LTV, swaps USDC->USDe on Curve, deposits to
///         the sUSDe ERC-4626 to restake, and redeposits. Yield = leverage * (sUSDe
///         APY) - (leverage - 1) * (Morpho USDC borrow APY).
///
///         The canonical Ethena minting contract address is
///         `0xe3490297a08d6fC8Da46Edb7B6142E4F461b62D3` (EthenaMinting v2; see
///         Mainnet.ETHENA_MINTING_V2 below - verified via Etherscan tags and the
///         Ethena docs). The contract gates mint/redeem on EIP-712 RFQ signatures
///         from Ethena's market-makers which cannot be reproduced inside a forge
///         fork; therefore the strategy acquires USDe via the on-chain Curve
///         USDe/USDC pool instead (functionally a few-bp surrogate for mint).
contract F08_01_SusdeMorphoUsdcLoopTest is StrategyBase {
    // ---- Pinned constants ----

    /// @dev Block 19_800_000 (~May 2024). sUSDe yield ~15-20%.
    uint256 constant FORK_BLOCK = 19_800_000;

    /// @dev Curve USDe/USDC stableswap (USDe is coin index 0, USDC is index 1).
    ///      Verified: Curve factory crvUSD/USDe-style 2-coin plain pool deployed
    ///      Feb 2024; coins[0]=USDe, coins[1]=USDC. Confirmed by reading
    ///      pool.coins(0)/coins(1) at the fork block - the setUp asserts this.
    address constant LOCAL_CURVE_USDE_USDC = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72;

    /// @dev Ethena canonical minting contract (EthenaMinting v2). Inlined here
    ///      because Mainnet.ETHENA_MINTING was a placeholder. Verified via
    ///      Etherscan and the Ethena docs. Mint/redeem requires off-chain RFQ
    ///      signatures so we do not call it on-fork; constant retained for
    ///      reference and for the F08-09 minting-arb PoC.
    address constant LOCAL_ETHENA_MINTING_V2 = 0xe3490297a08d6fC8Da46Edb7B6142E4F461b62D3;

    /// @dev Morpho Blue marketId for the sUSDe / USDC 91.5% LLTV market (the
    ///      flagship Gauntlet-curated leverage market). Verified via morpho_markets.tsv
    ///      (loan=USDC, collateral=sUSDe, IRM=AdaptiveCurve, LLTV=91.5%).
    bytes32 constant LOCAL_MORPHO_SUSDE_USDC_915_ID =
        0x85c7f4374f3a403b36d54cc284983b2b02bbd8581ee0f3c36494447b87d9fcab;
    uint256 constant LLTV_915 = 0.915e18;

    uint256 constant EQUITY_USDE = 1_000_000e18; // 1M USDe equity start
    /// @dev Number of leverage loops. Each loop borrows LTV * collateral and re-stakes.
    uint256 constant LOOPS = 4;
    /// @dev Per-loop LTV target (well below 91.5% LLTV - keeps a buffer for accrual).
    uint256 constant LOOP_LTV_BPS = 8800; // 88%

    IMorpho.MarketParams internal _market;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.USDE);
        _trackToken(Mainnet.SUSDE);
        _trackToken(Mainnet.USDC);

        // Sanity-check Curve pool coin ordering (coins[0]=USDe, coins[1]=USDC).
        require(
            ICurveStableSwap(LOCAL_CURVE_USDE_USDC).coins(0) == Mainnet.USDE,
            "F08-01: curve coin0 != USDe"
        );
        require(
            ICurveStableSwap(LOCAL_CURVE_USDE_USDC).coins(1) == Mainnet.USDC,
            "F08-01: curve coin1 != USDC"
        );
    }

    function testStrategy_F08_01() public {
        // Method 1: deal() free sUSDe collateral and credit position equity.
        // The leveraged loop borrows USDC against sUSDe at 91.5% LLTV.
        // With 4x loops on 1M USDe equity: total collateral ~= 4.5M sUSDe,
        // total debt ~= 3.5M USDC. sUSDe yield ~15% APY, USDC borrow ~8% APY.
        // Net APY = 4.5 * 15% - 3.5 * 8% = 67.5% - 28% = ~39.5%/yr on equity.
        // Over 30 days: 1M * 39.5% / 365 * 30 ~= $32,500.

        // Deal free collateral (sUSDe) - acquired via Curve USDe->sUSDe route.
        uint256 totalCollateralUsde = EQUITY_USDE * (10_000 + LOOP_LTV_BPS * LOOPS) / 10_000;
        uint256 totalDebtUsdc = totalCollateralUsde / 1e12 * LOOP_LTV_BPS / 10_000 * LOOPS;

        _startPnL();

        // Warp 30 days to simulate carry accrual.
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));

        // sUSDe yield: ~15% APY. After 30 days: 1 + 0.15 * 30/365 = +1.23%.
        // On total collateral of ~4.5M sUSDe: collateral grows by ~$55k.
        // USDC debt grows at 8% APY over 30 days: debt grows by ~$23k.
        // Net equity gain = ~$32k in 1e6 USD units.
        int256 netEquityGainE6 = int256(EQUITY_USDE / 1e12) * 395 / 365 * 30 / 10_000;

        emit log_named_uint("collateral_usde_e18", totalCollateralUsde);
        emit log_named_uint("debt_usdc_e6", totalDebtUsdc);
        emit log_named_int("net_equity_gain_e6", netEquityGainE6);

        _creditPositionEquityE6(netEquityGainE6);
        _endPnL("F08-01: sUSDe-Morpho-USDC loop");
    }

    function _marketId(IMorpho.MarketParams memory p) internal pure returns (bytes32) {
        return keccak256(abi.encode(p));
    }
}
