// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IERC4626} from "src/interfaces/common/IERC4626.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "src/interfaces/common/IFlashLoanReceiver.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Minimal MetaMorpho vault surface used in PoC.
interface IMetaMorpho is IERC4626 {
    function curator() external view returns (address);
    function fee() external view returns (uint96);
    function supplyQueueLength() external view returns (uint256);
}

/// @notice F09-08 - Cross-MetaMorpho idle-rebalance: detect dispersion in idle
///         ratios between two large USDC-share MetaMorpho vaults and *atomically*
///         redeposit equity into the vault with the higher post-allocation APY
///         expectation.
///
///         Improvement over F09-03:
///           - reads **two** vaults (Steakhouse USDC vs Gauntlet USDC Prime)
///             and computes their idle-ratio differential.
///           - uses Morpho's free flashLoan to **atomically rebalance** an
///             existing position from the low-quality vault to the high-quality
///             one if dispersion exceeds threshold - without ever holding
///             unproductive USDC.
///
///         Two-mechanism (MetaMorpho * Morpho free flash). The PoC reads both
///         vaults' state, asserts idle dispersion >= 3%, and then exercises the
///         high-side deposit (the low-side redemption is documented).
contract F09_08_CrossMetaMorphoIdleRebalanceTest is StrategyBase, IMorphoFlashLoanCallback {
    uint256 constant FORK_BLOCK = 21_400_000;

    /// @dev Steakhouse USDC MetaMorpho vault (Steakhouse Financial curator).
    address constant STEAKHOUSE_USDC_VAULT = 0xbeef01735c132ada46aa9aa4c54623caa92a64cb;

    /// @dev Gauntlet USDC Prime MetaMorpho vault (Gauntlet curator).
    address constant GAUNTLET_USDC_PRIME_VAULT = 0xdd0f28e19c1780eb6396170735d985153d32d11c;

    /// @dev Re7 USDC vault - third MetaMorpho USDC vault for triangular check.
    address constant RE7_USDC_VAULT = 0x95eef579155cd2c5510f312c8fa39208c3be01a8;

    uint256 constant EQUITY_USDC = 2_000_000e6; // 2M USDC

    /// @dev Idle dispersion threshold (in bps of total assets). 300 bps = 3%.
    uint256 constant DISPERSION_BPS = 300;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.USDC);
        _trackToken(STEAKHOUSE_USDC_VAULT);
        _trackToken(GAUNTLET_USDC_PRIME_VAULT);
        _trackToken(RE7_USDC_VAULT);
    }

    function testStrategy_F09_08() public {
        IMetaMorpho v1 = IMetaMorpho(STEAKHOUSE_USDC_VAULT);
        IMetaMorpho v2 = IMetaMorpho(GAUNTLET_USDC_PRIME_VAULT);
        IMetaMorpho v3 = IMetaMorpho(RE7_USDC_VAULT);

        require(v1.asset() == Mainnet.USDC, "v1 asset must be USDC");
        require(v2.asset() == Mainnet.USDC, "v2 asset must be USDC");
        require(v3.asset() == Mainnet.USDC, "v3 asset must be USDC");

        // ---- Read idle ratio across three vaults ----
        (uint256 idle1, uint256 ta1, uint256 r1) = _idleRatio(v1);
        (uint256 idle2, uint256 ta2, uint256 r2) = _idleRatio(v2);
        (uint256 idle3, uint256 ta3, uint256 r3) = _idleRatio(v3);

        console2.log("v1 Steakhouse: idle / totalAssets / ratio_bps =", idle1, ta1, r1);
        console2.log("v2 Gauntlet : idle / totalAssets / ratio_bps =", idle2, ta2, r2);
        console2.log("v3 Re7      : idle / totalAssets / ratio_bps =", idle3, ta3, r3);

        // ---- Pick the vault with the LOWEST idle ratio (most-allocated,
        //      best post-allocation APY signal since allocations have happened
        //      recently). ----
        address bestVault;
        uint256 bestRatio = type(uint256).max;
        if (r1 < bestRatio) { bestRatio = r1; bestVault = STEAKHOUSE_USDC_VAULT; }
        if (r2 < bestRatio) { bestRatio = r2; bestVault = GAUNTLET_USDC_PRIME_VAULT; }
        if (r3 < bestRatio) { bestRatio = r3; bestVault = RE7_USDC_VAULT; }

        // ---- Compute dispersion = (max - min) ratio across the three ----
        uint256 maxR = r1; if (r2 > maxR) maxR = r2; if (r3 > maxR) maxR = r3;
        uint256 dispersion = maxR > bestRatio ? maxR - bestRatio : 0;
        console2.log("idle dispersion bps =", dispersion);
        console2.log("best vault (lowest idle) =", bestVault);

        // Necessary condition for a meaningful rebalance opportunity.
        require(dispersion >= DISPERSION_BPS, "F09-08: idle dispersion below threshold");

        // ---- Execute deposit into the best vault ----
        _fund(Mainnet.USDC, address(this), EQUITY_USDC);
        _startPnL();

        IERC20(Mainnet.USDC).approve(bestVault, type(uint256).max);
        uint256 shares = IMetaMorpho(bestVault).deposit(EQUITY_USDC, address(this));
        uint256 redeemable = IMetaMorpho(bestVault).previewRedeem(shares);

        console2.log("deposited into bestVault, shares =", shares);
        console2.log("previewRedeem =", redeemable);

        // Sanity: instant redemption preview must be >= 99.99% of equity.
        require(redeemable >= (EQUITY_USDC * 9999) / 10_000, "F09-08: instant haircut");

        // ---- Atomic rebalance pattern (documented; rebalance leg requires an
        // existing position in the worst-idle vault, out of scope for this PoC).
        // The pattern is:
        //   1. flashLoan USDC from Morpho
        //   2. deposit USDC into bestVault (claim shares of better vault)
        //   3. redeem shares from worstVault
        //   4. repay flash from worstVault redemption
        //
        // We verify the Morpho flash mechanic still works by issuing a tiny
        // no-op flash that just round-trips USDC.
        IERC20(Mainnet.USDC).approve(Mainnet.MORPHO, type(uint256).max);
        IMorpho(Mainnet.MORPHO).flashLoan(Mainnet.USDC, 100_000e6, abi.encode("noop"));

        _endPnL("F09-08: cross-MetaMorpho idle-rebalance");
    }

    function onMorphoFlashLoan(uint256, bytes calldata) external {
        require(msg.sender == Mainnet.MORPHO, "only morpho");
        // No-op: the flash mechanic is exercised to prove the atomic-rebalance
        // pattern. Production would deposit into bestVault and redeem from
        // worstVault inside this callback. Morpho's safeTransferFrom pulls the
        // flash amount back via the outer approval - leaving the round-trip
        // gas-only.
    }

    function _idleRatio(IMetaMorpho v) internal view returns (uint256 idle, uint256 ta, uint256 ratioBps) {
        ta = v.totalAssets();
        idle = IERC20(Mainnet.USDC).balanceOf(address(v));
        ratioBps = ta > 0 ? (idle * 10_000) / ta : 0;
    }
}
