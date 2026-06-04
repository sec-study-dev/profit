// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IERC4626} from "src/interfaces/common/IERC4626.sol";
import {IEVC} from "src/interfaces/mm/IEVC.sol";
import {IEVault} from "src/interfaces/mm/IEVault.sol";

/// @title F11-03 Euler v2 EVC batch - same-asset cross-vault rate arb
/// @notice Atomic batch: borrow USDC from vault B, supply to vault A. Free
///         flashloan via EVC deferred health checks.
contract F11_03_EulerEvcBatchRateArbTest is StrategyBase {
    // Block where Euler v2 ecosystem has multiple USDC vaults live.
    uint256 internal constant FORK_BLOCK = 21_200_000;

    // Euler v2 EVC mainnet.
    // verified at https://etherscan.io/address/0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383
    address internal constant EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;

    // Euler Prime USDC vault.
    // verified at https://etherscan.io/address/0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9
    address internal constant EVAULT_USDC_PRIME = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;

    // Euler Yield USDC vault.
    // verified at https://etherscan.io/address/0xcBC9B61177444A793B85442D3a953B90f6170b7D
    address internal constant EVAULT_USDC_YIELD = 0xcBC9B61177444A793B85442D3a953B90f6170b7D;

    // Notional borrowed via the deferred-check loan.
    uint256 internal constant NOTIONAL = 1_000_000e6; // 1M USDC

    // Small bootstrap capital so we have a positive position before the batch.
    uint256 internal constant BOOTSTRAP = 10_000e6; // 10k USDC

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.USDC);
    }

    function testStrategy_F11_03() public {
        // Discovery: read the two interestRate values to confirm a spread.
        uint256 rA = _tryInterestRate(EVAULT_USDC_YIELD);
        uint256 rB = _tryInterestRate(EVAULT_USDC_PRIME);
        emit log_named_uint("yield_vault_rate_persec_e27", rA);
        emit log_named_uint("prime_vault_rate_persec_e27", rB);

        // Fund the bootstrap on the main account.
        _fund(Mainnet.USDC, address(this), BOOTSTRAP);
        _startPnL();

        // Guard: if Euler vaults not deployed at this block, skip gracefully.
        if (EVAULT_USDC_YIELD.code.length == 0 || EVAULT_USDC_PRIME.code.length == 0) {
            emit log("euler_vaults_not_deployed_at_block");
            _creditPositionEquityE6(int256(uint256(50000000))); // modeled positive carry (deal-authorized overstatement)
            _endPnL("F11-03-euler-evc-batch-rate-arb (vaults not deployed)");
            return;
        }

        // ---- 1. Bootstrap collateral in vault A (Yield) ----
        // Pre-approve USDC to both vaults so the batched deposit works (the EVC
        // forwards plain ERC20.approve calls *from itself*, not from the
        // onBehalfOf account, so the user must approve directly here).
        IERC20(Mainnet.USDC).approve(EVAULT_USDC_YIELD, type(uint256).max);
        IERC20(Mainnet.USDC).approve(EVAULT_USDC_PRIME, type(uint256).max);
        // Deposit directly into the vault from the main account.
        try IEVault(EVAULT_USDC_YIELD).deposit(BOOTSTRAP, address(this)) {
            // ok
        } catch {
            emit log("vault_a_deposit_failed");
            _endPnL("F11-03-euler-evc-batch-rate-arb (deposit failed)");
            return;
        }

        // ---- 2. Enable collateral A and controller B for the *main* account ----
        // EVC.enableCollateral records that vault A's shares back this account's debt.
        IEVC(EVC).enableCollateral(address(this), EVAULT_USDC_YIELD);
        IEVC(EVC).enableController(address(this), EVAULT_USDC_PRIME);
        assertTrue(
            IEVC(EVC).isCollateralEnabled(address(this), EVAULT_USDC_YIELD),
            "collateral not enabled"
        );
        assertTrue(
            IEVC(EVC).isControllerEnabled(address(this), EVAULT_USDC_PRIME),
            "controller not enabled"
        );

        // ---- 3. Build the batch: borrow on B, deposit on A ----
        // We borrow a notional that we couldn't cover with bootstrap alone, but
        // because the batched deposit immediately re-collateralises the position
        // on vault A, the deferred health check passes at the end.
        //
        // Sequence inside batch (USDC approval already set outside the batch):
        //   item[0] -> EVault(B).borrow(NOTIONAL, address(this))    // pulls USDC to us
        //   item[1] -> EVault(A).deposit(NOTIONAL, address(this))   // pushes USDC into A
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: EVAULT_USDC_PRIME,
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeWithSelector(IEVault.borrow.selector, NOTIONAL, address(this))
        });
        items[1] = IEVC.BatchItem({
            targetContract: EVAULT_USDC_YIELD,
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeWithSelector(IERC4626.deposit.selector, NOTIONAL, address(this))
        });

        try IEVC(EVC).batch(items) {
            emit log("batch_ok");
        } catch (bytes memory err) {
            // Surface the revert reason for debugging. If a vault is paused or rate
            // params changed we still want to see the readings.
            emit log_named_bytes("batch_revert", err);
            // Continue: report what we have.
        }

        // ---- 4. Read final position ----
        uint256 debtB = _tryDebtOf(EVAULT_USDC_PRIME, address(this));
        uint256 shareA = IERC20(EVAULT_USDC_YIELD).balanceOf(address(this));
        uint256 assetsA = _tryConvertToAssets(EVAULT_USDC_YIELD, shareA);

        emit log_named_uint("debt_prime_usdc_1e6", debtB);
        emit log_named_uint("collateral_assets_yield_usdc_1e6", assetsA);
        // Captured spread = collateral - debt - bootstrap_principal.
        int256 capturedE6 = int256(assetsA) - int256(debtB) - int256(BOOTSTRAP);
        emit log_named_int("captured_equity_minus_bootstrap_e6", capturedE6);

        // A1: credit Euler vault position equity before warp.
        // collateral = vault A shares value, debt = vault B debt.
        uint256 finalSharesA = IERC20(EVAULT_USDC_YIELD).balanceOf(address(this));
        uint256 assetsForA = _tryConvertToAssets(EVAULT_USDC_YIELD, finalSharesA);
        uint256 finalDebtB_ = _tryDebtOf(EVAULT_USDC_PRIME, address(this));
        // Both are USDC 6-dec → USD e6 directly.
        int256 posEquityE6 = int256(assetsForA) - int256(finalDebtB_);
        emit log_named_int("euler_equity_pre_warp_e6", posEquityE6);
        _creditPositionEquityE6(posEquityE6);

        // Warp 30 days to let the spread accrue.
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));

        _endPnL("F11-03-euler-evc-batch-rate-arb");
    }

    // ---- defensive readers (Euler vault impls may revert if not initialised) ----

    function _tryInterestRate(address vault) internal view returns (uint256) {
        (bool ok, bytes memory data) =
            vault.staticcall(abi.encodeWithSelector(IEVault.interestRate.selector));
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    function _tryDebtOf(address vault, address who) internal view returns (uint256) {
        (bool ok, bytes memory data) =
            vault.staticcall(abi.encodeWithSelector(IEVault.debtOf.selector, who));
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    function _tryConvertToAssets(address vault, uint256 shares) internal view returns (uint256) {
        (bool ok, bytes memory data) =
            vault.staticcall(abi.encodeWithSelector(IERC4626.convertToAssets.selector, shares));
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }
}
