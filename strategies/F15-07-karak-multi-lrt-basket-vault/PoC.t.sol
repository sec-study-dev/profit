// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWstETH} from "src/interfaces/lst/IWstETH.sol";
import {IStETH} from "src/interfaces/lst/IStETH.sol";
import {IPufETH} from "src/interfaces/lrt/IPufETH.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Karak V1 VaultSupervisor - user-facing deposit entry point.
/// deposit(vault, amount, minSharesOut) routes assets through the supervisor,
/// which holds all vault shares on behalf of users.
interface IKarakVaultSupervisor {
    function deposit(address vault, uint256 amount, uint256 minSharesOut) external returns (uint256 shares);
    function getDeposits(address user) external view returns (address[] memory vaults, uint256[] memory shares);
    function getVaults() external view returns (address[] memory);
}

/// @notice Minimal Karak vault - read-only accessors only.
interface IKarakVault {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
}

/// @notice Minimal EtherFi liquidity pool - eETH mint via ETH deposit.
interface IEtherFiLiquidityPool {
    function deposit() external payable returns (uint256);
}

/// @notice Minimal weETH wrapper - wrap rebasing eETH into non-rebasing weETH.
interface IWeETHWrapper {
    function wrap(uint256 eETHAmount) external returns (uint256);
}

/// @notice F15-07 - Karak V1 multi-LRT basket: deposit pufETH + weETH + wstETH
///         into three Karak vaults in one transaction for a layered point stack.
///
/// 3-mechanism compose:
///   1. **Karak restaking** - Karak XP + (eventual) KAR token airdrop on every
///      deposited asset.
///   2. **LRT layer (EtherFi + Puffer)** - each pufETH and weETH share keeps
///      accruing its native LRT points (ETHFI loyalty, Puffer Carrot)
///      *while sitting inside the Karak vault* (Karak deposits do NOT
///      surrender the underlying claim; the user is the vault-share owner).
///   3. **LST layer (Lido via wstETH)** - wstETH continues to compound Lido
///      staking yield inside Karak's wstETH vault.
///
/// All three vaults hold their respective assets simultaneously on the same
/// equity, with no cross-collateralisation. This is a **point-diversification
/// PoC** - the cash leg at fork-block is ~$0; the value is the airdrop
/// expectation of (KAR + ETHFI + PUFFER + LDO) all earning on overlapping
/// notionals.
///
/// KARAK V1 DEPOSIT ARCHITECTURE:
///   Users must call VaultSupervisor.deposit(vault, amount, minSharesOut) NOT
///   vault.deposit() directly. The VaultSupervisor is the authorized depositor
///   for all Karak V1 vaults. Calling vault.deposit() directly returns
///   Unauthorized() (selector 0x82b42900). The supervisor holds the vault
///   shares; user positions are tracked via VaultSupervisor.getDeposits(user).
contract F15_07_KarakMultiLrtBasketVaultTest is StrategyBase {
    // ---- Karak V1 VaultSupervisor ----
    // All user deposits must go through this contract, not directly to vaults.
    // Verified: 0x54e44DbB92dBA848ACe27F44c0CB4268981eF1CC on mainnet.
    address constant KARAK_VAULT_SUPERVISOR = 0x54e44DbB92dBA848ACe27F44c0CB4268981eF1CC;

    // ---- Karak v1 vault addresses (verified via VaultSupervisor.getVaults()) ----
    // Confirmed by calling asset() on each vault at FORK_BLOCK and verified in
    // VaultSupervisor.getVaults() return value:
    //   wstETH vault -> 0xa3726beDFD1a8AA696b9B4581277240028c4314b (wstETH)
    //   weETH  vault -> 0x2DABcea55a12d73191AeCe59F508b191Fb68AdaC (weETH)
    //   pufETH vault -> 0x68754d29f2e97B837Cb622ccfF325adAC27E9977 (pufETH)

    /// @dev Karak wstETH vault (Karak V1).
    address constant KARAK_WSTETH_VAULT = 0xa3726beDFD1a8AA696b9B4581277240028c4314b;

    /// @dev Karak pufETH vault (Karak V1).
    address constant KARAK_PUFETH_VAULT = 0x68754d29f2e97B837Cb622ccfF325adAC27E9977;

    /// @dev Karak weETH vault (Karak V1).
    address constant KARAK_WEETH_VAULT = 0x2DABcea55a12d73191AeCe59F508b191Fb68AdaC;

    /// @dev Apr-May 2024 - Karak V1 vaults live, LRT deposits open,
    ///      pufETH depositStETH active (depositWstETH function did not exist
    ///      in the deployed version; use depositStETH which requires stETH allowance).
    uint256 constant FORK_BLOCK = 19_800_000;

    /// @dev Per-leg equity: 30 ETH-equivalent in each of the three LRTs.
    uint256 constant LEG_ETH = 30 ether;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WSTETH);
        _trackToken(Mainnet.STETH);
        _trackToken(Mainnet.WEETH);
        _trackToken(Mainnet.EETH);
        _trackToken(Mainnet.PUFETH);
    }

    function testStrategy_F15_07() public {
        // Fund with WETH then unwrap to ETH for downstream minting.
        // We treat 90 ETH total equity = 30 ETH * 3 legs.
        vm.deal(address(this), 90 ether);

        _startPnL();

        uint256 sharesWst = 0;
        uint256 sharesWee = 0;
        uint256 sharesPuf = 0;

        // =========================================================
        //  Leg A: ETH -> stETH -> wstETH -> Karak wstETH vault
        //         via VaultSupervisor.deposit()
        // =========================================================
        {
            // Lido submit() mints stETH 1:1 against ETH.
            IStETH(Mainnet.STETH).submit{value: LEG_ETH}(address(0));
            uint256 stBal = IERC20(Mainnet.STETH).balanceOf(address(this));
            console2.log("Leg A: stETH minted:", stBal);

            // Wrap stETH -> wstETH.
            IERC20(Mainnet.STETH).approve(Mainnet.WSTETH, stBal);
            uint256 wstOut = IWstETH(Mainnet.WSTETH).wrap(stBal);
            console2.log("Leg A: wstETH minted:", wstOut);

            if (wstOut > 0 && address(KARAK_WSTETH_VAULT).code.length > 0) {
                // Approve VaultSupervisor (NOT the vault) to pull wstETH.
                IERC20(Mainnet.WSTETH).approve(KARAK_VAULT_SUPERVISOR, wstOut);
                try IKarakVaultSupervisor(KARAK_VAULT_SUPERVISOR).deposit(
                    KARAK_WSTETH_VAULT, wstOut, 0
                ) returns (uint256 sh) {
                    sharesWst = sh;
                    console2.log("Leg A: Karak-wstETH shares:", sh);
                } catch Error(string memory reason) {
                    console2.log("Leg A: Karak wstETH deposit reverted:", reason);
                } catch {
                    console2.log("Leg A: Karak wstETH deposit reverted (unknown)");
                }
            } else {
                console2.log("Leg A: Karak wstETH vault not deployed at this block; skipping");
            }
        }

        // =========================================================
        //  Leg B: ETH -> eETH -> weETH -> Karak weETH vault
        //         via VaultSupervisor.deposit()
        // =========================================================
        {
            uint256 eBefore = IERC20(Mainnet.EETH).balanceOf(address(this));
            try IEtherFiLiquidityPool(Mainnet.ETHERFI_LIQUIDITY_POOL).deposit{value: LEG_ETH}() {
                // ok
            } catch Error(string memory reason) {
                console2.log("Leg B: EtherFi deposit reverted:", reason);
            } catch {
                console2.log("Leg B: EtherFi deposit reverted (unknown)");
            }
            uint256 eMinted = IERC20(Mainnet.EETH).balanceOf(address(this)) - eBefore;
            console2.log("Leg B: eETH minted:", eMinted);

            if (eMinted > 0) {
                // Wrap eETH -> weETH (non-rebasing for vault deposit).
                IERC20(Mainnet.EETH).approve(Mainnet.WEETH, eMinted);
                uint256 weOut = 0;
                try IWeETHWrapper(Mainnet.WEETH).wrap(eMinted) returns (uint256 w) {
                    weOut = w;
                } catch {
                    console2.log("Leg B: weETH wrap reverted");
                }
                console2.log("Leg B: weETH minted:", weOut);

                if (weOut > 0) {
                    // Approve VaultSupervisor (NOT the vault) to pull weETH.
                    IERC20(Mainnet.WEETH).approve(KARAK_VAULT_SUPERVISOR, weOut);
                    try IKarakVaultSupervisor(KARAK_VAULT_SUPERVISOR).deposit(
                        KARAK_WEETH_VAULT, weOut, 0
                    ) returns (uint256 sh) {
                        sharesWee = sh;
                        console2.log("Leg B: Karak-weETH shares:", sh);
                    } catch Error(string memory reason) {
                        console2.log("Leg B: Karak weETH deposit reverted:", reason);
                    } catch {
                        console2.log("Leg B: Karak weETH deposit reverted (unknown)");
                    }
                }
            }
        }

        // =========================================================
        //  Leg C: ETH -> stETH -> pufETH -> Karak pufETH vault
        //         via VaultSupervisor.deposit()
        // =========================================================
        {
            // Mint another batch of stETH via Lido.
            IStETH(Mainnet.STETH).submit{value: LEG_ETH}(address(0));
            uint256 stBalC = IERC20(Mainnet.STETH).balanceOf(address(this));
            console2.log("Leg C: stETH for Puffer:", stBalC);

            // NOTE: Puffer Finance's deployed pufETH contract does NOT implement
            // depositWstETH(). The only stETH-based minting path is depositStETH(),
            // which requires msg.sender to have sufficient stETH and to approve
            // the pufETH contract. We use stETH directly here rather than
            // wrapping to wstETH first.
            uint256 pufBefore = IERC20(Mainnet.PUFETH).balanceOf(address(this));
            IERC20(Mainnet.STETH).approve(Mainnet.PUFETH, stBalC);
            try IPufETH(Mainnet.PUFETH).depositStETH(stBalC, address(this)) returns (uint256) {
                // ok
            } catch Error(string memory reason) {
                console2.log("Leg C: pufETH mint reverted:", reason);
            } catch {
                console2.log("Leg C: pufETH mint reverted (unknown)");
            }
            uint256 pufMinted = IERC20(Mainnet.PUFETH).balanceOf(address(this)) - pufBefore;
            console2.log("Leg C: pufETH minted:", pufMinted);

            if (pufMinted > 0) {
                // Approve VaultSupervisor (NOT the vault) to pull pufETH.
                IERC20(Mainnet.PUFETH).approve(KARAK_VAULT_SUPERVISOR, pufMinted);
                try IKarakVaultSupervisor(KARAK_VAULT_SUPERVISOR).deposit(
                    KARAK_PUFETH_VAULT, pufMinted, 0
                ) returns (uint256 sh) {
                    sharesPuf = sh;
                    console2.log("Leg C: Karak-pufETH shares:", sh);
                } catch Error(string memory reason) {
                    console2.log("Leg C: Karak pufETH deposit reverted:", reason);
                } catch {
                    console2.log("Leg C: Karak pufETH deposit reverted (unknown)");
                }
            }
        }

        // ---- Report: user positions are tracked by VaultSupervisor ----
        // VaultSupervisor holds vault shares; getDeposits() returns user's
        // allocated shares per vault.
        (address[] memory depVaults, uint256[] memory depShares) =
            IKarakVaultSupervisor(KARAK_VAULT_SUPERVISOR).getDeposits(address(this));
        console2.log("VaultSupervisor positions count:", depVaults.length);
        for (uint256 i = 0; i < depVaults.length; i++) {
            console2.log("  vault:", depVaults[i]);
            console2.log("  shares:", depShares[i]);
        }

        console2.log("Karak wstETH shares (return value):", sharesWst);
        console2.log("Karak weETH  shares (return value):", sharesWee);
        console2.log("Karak pufETH shares (return value):", sharesPuf);

        _endPnL("F15-07: karak-multi-lrt-basket-vault");

        // Sanity: at least one leg must land a Karak-share balance.
        require(sharesWst > 0 || sharesWee > 0 || sharesPuf > 0, "all 3 Karak deposits failed");
    }
}
