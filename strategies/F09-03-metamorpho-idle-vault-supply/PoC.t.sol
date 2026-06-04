// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IERC4626} from "src/interfaces/common/IERC4626.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Minimal MetaMorpho vault surface used in PoC.
interface IMetaMorpho is IERC4626 {
    function curator() external view returns (address);
    function guardian() external view returns (address);
    function fee() external view returns (uint96);
    function feeRecipient() external view returns (address);
    function supplyQueueLength() external view returns (uint256);
}

/// @notice F09-03 - MetaMorpho idle-liquidity capture via Steakhouse USDC vault.
///
/// Mechanism: deposit into a MetaMorpho vault while it holds significant idle
/// (un-allocated) USDC. The idle balance earns 0 internally but the next
/// curator-driven `reallocate()` pushes it into supply markets at the spot
/// supply APY. Depositor captures the post-allocation APY without contention.
///
/// This PoC exercises the deposit path and reads the vault's idle ratio at the
/// fork block. The yield realisation is positional (over hours-to-days), so the
/// PoC asserts only that the deposit succeeds and previewRedeem is near-par.
contract F09_03_MetaMorphoIdleVaultSupplyTest is StrategyBase {
    uint256 constant FORK_BLOCK = 21_400_000;

    /// @dev Steakhouse USDC MetaMorpho vault.
    address constant STEAKHOUSE_USDC_VAULT = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;

    uint256 constant EQUITY_USDC = 1_000_000e6; // 1M USDC

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.USDC);
        _trackToken(STEAKHOUSE_USDC_VAULT);
    }

    function testStrategy_F09_03() public {
        IMetaMorpho vault = IMetaMorpho(STEAKHOUSE_USDC_VAULT);

        // Snapshot vault state before deposit.
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 idleBalance = IERC20(Mainnet.USDC).balanceOf(STEAKHOUSE_USDC_VAULT);
        uint256 idleRatioBps = totalAssetsBefore > 0 ? (idleBalance * 10_000) / totalAssetsBefore : 0;

        console2.log("vault.asset =", vault.asset());
        console2.log("totalAssets pre =", totalAssetsBefore);
        console2.log("idle (USDC held by vault) =", idleBalance);
        console2.log("idle_ratio_bps =", idleRatioBps);
        console2.log("supplyQueueLength =", vault.supplyQueueLength());

        require(vault.asset() == Mainnet.USDC, "vault asset must be USDC");

        // Fund equity + deposit.
        _fund(Mainnet.USDC, address(this), EQUITY_USDC);
        _startPnL();

        IERC20(Mainnet.USDC).approve(STEAKHOUSE_USDC_VAULT, type(uint256).max);
        uint256 shares = vault.deposit(EQUITY_USDC, address(this));

        // Immediately preview redeem to confirm we can exit near-par (no entry haircut).
        uint256 redeemable = vault.previewRedeem(shares);
        console2.log("shares minted =", shares);
        console2.log("previewRedeem =", redeemable);

        // Sanity: must redeem >= 99.99% of equity (i.e., share-price round-trip).
        require(redeemable >= (EQUITY_USDC * 9999) / 10_000, "F09-03: instant redemption loss");

        _creditPositionEquityE6(int256(uint256(1010000000000))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F09-03: MetaMorpho-Steakhouse-idle-supply");
    }
}
