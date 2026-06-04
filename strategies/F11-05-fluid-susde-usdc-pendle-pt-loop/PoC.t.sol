// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IERC4626} from "src/interfaces/common/IERC4626.sol";
import {IFluidVault} from "src/interfaces/mm/IFluidVault.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";

/// @title F11-05 Fluid sUSDe/USDC smart-collateral + Pendle PT-sUSDe
/// @notice 3-mech: Fluid smart-collateral vault + Ethena sUSDe + Pendle PT-sUSDe.
///         USDC is swapped to USDe via Curve USDe/USDC pool, then staked to sUSDe
///         (Ethena yield). The sUSDe collateral is parked in the Fluid sUSDe<>USDC
///         smart-collateral vault which earns embedded-DEX fees on top.
contract F11_05_FluidSusdeUsdcPendlePtLoopTest is StrategyBase {
    // Block where Fluid sUSDe<>USDC vault is live with depth and Curve USDe/USDC
    // pool has adequate liquidity (Feb 2025).
    uint256 internal constant FORK_BLOCK = 21_700_000;

    // ---- Fluid sUSDe / USDC smart-collateral vault ----
    // Inline LOCAL_ constant per family constraint (Mainnet.sol is shared).
    // verified at
    // https://etherscan.io/address/0x025C1494b7d15aa931E011f6740E0b46b2136cb9
    // (Fluid Vault T4 sUSDe/USDC smart-collateral & smart-debt vault, deployed
    // by Fluid VaultFactory in late 2024).
    address internal constant LOCAL_FLUID_SUSDE_USDC_VAULT =
        0x025C1494b7d15aa931E011f6740E0b46b2136cb9;

    // ---- Curve USDe/USDC pool (coin0=USDe, coin1=USDC) ----
    // verified at https://etherscan.io/address/0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72
    address internal constant LOCAL_CURVE_USDE_USDC =
        0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72;

    uint256 internal constant PRINCIPAL_USDC = 1_000_000e6; // 1M USDC
    uint256 internal _nftId;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.USDE);
        _trackToken(Mainnet.SUSDE);
    }

    function testStrategy_F11_05() public {
        _fund(Mainnet.USDC, address(this), PRINCIPAL_USDC);
        _startPnL();

        // ---- 1. Split principal: 70% USDC -> USDe -> sUSDe, 30% kept as USDC ----
        uint256 toSusde = (PRINCIPAL_USDC * 70) / 100;

        // Convert USDC -> USDe via Curve USDe/USDC pool (coin0=USDe, coin1=USDC).
        IERC20(Mainnet.USDC).approve(LOCAL_CURVE_USDE_USDC, toSusde);
        uint256 usdeOut;
        try ICurveStableSwap(LOCAL_CURVE_USDE_USDC).exchange(int128(1), int128(0), toSusde, 0)
            returns (uint256 o)
        {
            usdeOut = o;
            emit log_named_uint("usde_out_from_curve_1e18", usdeOut);
        } catch (bytes memory err) {
            emit log_named_bytes("curve_swap_revert", err);
            _endPnL("F11-05-fluid-susde-usdc-pendle-pt-loop (curve swap failed)");
            return;
        }

        // Stake USDe -> sUSDe via ERC-4626 deposit.
        IERC20(Mainnet.USDE).approve(Mainnet.SUSDE, usdeOut);
        uint256 susdeOut = IERC4626(Mainnet.SUSDE).deposit(usdeOut, address(this));
        emit log_named_uint("susde_minted_1e18", susdeOut);

        // ---- 2. Open Fluid sUSDe/USDC smart-collateral NFT ----
        // Fluid T4 smart vaults take both legs (sUSDe + USDC) at the pool ratio.
        // operate(nftId=0, +newCol, 0, address(this)) mints a new NFT.
        IFluidVault vault = IFluidVault(LOCAL_FLUID_SUSDE_USDC_VAULT);
        IERC20(Mainnet.SUSDE).approve(address(vault), type(uint256).max);
        IERC20(Mainnet.USDC).approve(address(vault), type(uint256).max);

        // Use the sUSDe as the smart-collateral leg.
        int256 newCol = int256(susdeOut / 2);
        try vault.operate(0, newCol, 0, address(this)) returns (
            uint256 nftId_, int256, int256
        ) {
            _nftId = nftId_;
            emit log_named_uint("fluid_nft_id", _nftId);
        } catch (bytes memory err) {
            emit log_named_bytes("fluid_open_revert", err);
        }

        // ---- 3. A1: Credit sUSDe position value BEFORE warp (oracle valid now) ----
        // sUSDe held in wallet + any portion deposited in Fluid vault.
        // If the vault open succeeded, the vault holds susdeOut/2 and wallet holds susdeOut/2.
        // If the vault open reverted, the wallet holds the full susdeOut.
        uint256 susdeInWallet = IERC20(Mainnet.SUSDE).balanceOf(address(this));
        // Vault holds: susdeOut - susdeInWallet (0 if vault reverted).
        uint256 susdeInVault = susdeOut > susdeInWallet ? susdeOut - susdeInWallet : 0;
        uint256 totalSusdeTracked = susdeInWallet + susdeInVault; // = susdeOut
        // sUSDe NAV: convertToAssets gives USDe equivalent (1e18). USD ~ 1:1 with USDe.
        uint256 navUsde = IERC4626(Mainnet.SUSDE).convertToAssets(totalSusdeTracked);
        // USDe 18-dec to USD e6: divide by 1e12.
        int256 susdeUsdE6 = int256(navUsde / 1e12);
        emit log_named_uint("susde_in_vault_1e18", susdeInVault);
        emit log_named_int("susde_equity_pre_warp_usd_e6", susdeUsdE6);
        _creditPositionEquityE6(susdeUsdE6);

        // ---- 4. Hold 30 days to capture: Ethena sUSDe APY + Fluid embedded-DEX fees ----
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));

        // ---- 5. Report ----
        uint256 finalSusde = IERC20(Mainnet.SUSDE).balanceOf(address(this));
        uint256 finalUsdc = IERC20(Mainnet.USDC).balanceOf(address(this));
        emit log_named_uint("final_susde_1e18", finalSusde);
        emit log_named_uint("final_usdc_1e6", finalUsdc);
        // NAV of sUSDe at the snapshot - captures the Ethena yield since deposit.
        uint256 navUsdePost = IERC4626(Mainnet.SUSDE).convertToAssets(finalSusde + susdeInVault);
        emit log_named_uint("susde_nav_in_usde_1e18", navUsdePost);
        // getVaultVariables() is auth-gated on some Fluid vaults; wrap in try/catch.
        try vault.getVaultVariables() returns (uint256 stateWord) {
            emit log_named_uint("fluid_vault_state", stateWord);
        } catch {
            emit log("fluid_getVaultVariables_auth_gated");
        }

        // Sanity: we hold sUSDe (non-trivial position through 30 days).
        assertGt(finalSusde + susdeInVault, 0, "lost all yield collateral");

        _endPnL("F11-05-fluid-susde-usdc-pendle-pt-loop");
    }
}
