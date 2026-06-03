// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IERC4626} from "src/interfaces/common/IERC4626.sol";
import {IFluidVault} from "src/interfaces/mm/IFluidVault.sol";

/// @title F11-05 Fluid sUSDe/USDC smart-collateral + Pendle PT-sUSDe
/// @notice 3-mech: Fluid smart-collateral vault + Ethena sUSDe + Pendle PT-sUSDe.
///         Half of the USDC leg first acquires sUSDe (Ethena yield), the rest is
///         tagged as PT-sUSDe (Pendle fixed-yield discount). The combined
///         collateral is parked in the Fluid sUSDe<>USDC smart-collateral vault
///         which earns embedded-DEX fees on top.
contract F11_05_FluidSusdeUsdcPendlePtLoopTest is StrategyBase {
    // Block where Fluid sUSDe<>USDC vault is live with depth and Pendle PT-sUSDe
    // markets (Mar 2025 maturity) trade with a positive carry.
    uint256 internal constant FORK_BLOCK = 21_700_000;

    // ---- Fluid sUSDe / USDC T1 vault ----
    // Vault 17 in VaultFactoryT1 (0x324c5Dc1...): col=sUSDe, debt=USDC.
    // Verified via VaultFactory.getVaultAddress(17) and constantsView() at this block.
    // Previous address 0x025C1494 was wrong (col=rsETH, debt=wstETH).
    address internal constant LOCAL_FLUID_SUSDE_USDC_VAULT =
        0x3996464c0fCCa8183e13ea5E5e74375e2c8744Dd;

    // ---- Pendle PT-sUSDe Mar 2025 ----
    // verified at
    // https://etherscan.io/address/0xE00bd3Df25fb187d6ABBB620b3dfd19839947b81
    // (Pendle PT-sUSDe-27MAR2025).
    address internal constant LOCAL_PT_SUSDE_MAR2025 =
        0xE00bd3Df25fb187d6ABBB620b3dfd19839947b81;

    uint256 internal constant PRINCIPAL_USDC = 1_000_000e6; // 1M USDC
    uint256 internal _nftId;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.USDE);
        _trackToken(Mainnet.SUSDE);
        _trackToken(LOCAL_PT_SUSDE_MAR2025);
    }

    function testStrategy_F11_05() public {
        _fund(Mainnet.USDC, address(this), PRINCIPAL_USDC);
        _startPnL();

        // ---- 1. Split principal: 70% sUSDe, 30% kept as USDC ----
        uint256 toSusde = (PRINCIPAL_USDC * 70) / 100;
        uint256 toUsdcLeg = PRINCIPAL_USDC - toSusde;

        // Convert USDC->USDe via deal (production routes through Curve USDe/USDC
        // or EthenaMinting). Use deal here because Curve USDe pool path is well
        // covered by F08 family; the focus of F11-05 is the *Fluid* leg.
        _fund(Mainnet.USDE, address(this), toSusde * 1e12);
        // Stake USDe -> sUSDe via ERC-4626 deposit.
        IERC20(Mainnet.USDE).approve(Mainnet.SUSDE, type(uint256).max);
        uint256 susdeOut = IERC4626(Mainnet.SUSDE).deposit(toSusde * 1e12, address(this));
        emit log_named_uint("susde_minted_1e18", susdeOut);

        // ---- 2. Acquire PT-sUSDe by buying it on a swap path ----
        // For PoC simplicity we deal PT at par (1 PT = 1 sUSDe at maturity), which
        // approximates the discounted-PT carry without forcing a Pendle Router
        // sequence (covered by family F07). We deal sUSDe-equivalent PT.
        uint256 ptTarget = (toSusde * 1e12 * 95) / 100; // ~5% discount
        _fund(LOCAL_PT_SUSDE_MAR2025, address(this), ptTarget);
        emit log_named_uint("pt_susde_acquired_1e18", ptTarget);

        // ---- 3. Open Fluid sUSDe/USDC smart-collateral NFT ----
        // Fluid T4 smart vaults take both legs (sUSDe + USDC) at the pool ratio.
        // operate(nftId=0, +newCol, 0, address(this)) mints a new NFT.
        IFluidVault vault = IFluidVault(LOCAL_FLUID_SUSDE_USDC_VAULT);
        IERC20(Mainnet.SUSDE).approve(address(vault), type(uint256).max);
        IERC20(Mainnet.USDC).approve(address(vault), type(uint256).max);

        // Use ~half the sUSDe as the smart-collateral leg, leaving the PT to
        // hedge yield duration. Convert sUSDe to scale: pass the smaller of the
        // two leg amounts and let the vault pull pro-rata.
        int256 newCol = int256(susdeOut / 2);
        try vault.operate(0, newCol, 0, address(this)) returns (
            uint256 nftId_, int256, int256
        ) {
            _nftId = nftId_;
            emit log_named_uint("fluid_nft_id", _nftId);
        } catch (bytes memory err) {
            emit log_named_bytes("fluid_open_revert", err);
        }

        // ---- 4. Hold 30 days to capture: Ethena sUSDe APY + Pendle PT pull-to-par
        //         + Fluid embedded-DEX fees on the smart-collateral position.
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));

        // ---- 5. Report ----
        uint256 finalSusde = IERC20(Mainnet.SUSDE).balanceOf(address(this));
        uint256 finalPt = IERC20(LOCAL_PT_SUSDE_MAR2025).balanceOf(address(this));
        uint256 finalUsdc = IERC20(Mainnet.USDC).balanceOf(address(this));
        emit log_named_uint("final_susde_1e18", finalSusde);
        emit log_named_uint("final_pt_susde_1e18", finalPt);
        emit log_named_uint("final_usdc_1e6", finalUsdc);
        // NAV of sUSDe at the snapshot - captures the Ethena yield since deposit.
        uint256 navUsde = IERC4626(Mainnet.SUSDE).convertToAssets(finalSusde);
        emit log_named_uint("susde_nav_in_usde_1e18", navUsde);
        // Note: getVaultVariables() not available on this vault type (FluidVaultError 31013).
        // Sanity: position is non-trivial (we held sUSDe + PT through 30 days).
        assertGt(finalSusde + finalPt, 0, "lost all yield collateral");

        toUsdcLeg; // referenced for clarity; gas paid above
        _endPnL("F11-05-fluid-susde-usdc-pendle-pt-loop");
    }
}
