// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWstETH} from "src/interfaces/lst/IWstETH.sol";
import {IStETH} from "src/interfaces/lst/IStETH.sol";
import {IPufETH} from "src/interfaces/lrt/IPufETH.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Minimal Karak v2 vault - ERC-4626-style deposit(assets, receiver).
interface IKarakVault {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function balanceOf(address account) external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function asset() external view returns (address);
}

/// @notice Minimal EtherFi liquidity pool - eETH mint via ETH deposit.
interface IEtherFiLiquidityPool {
    function deposit() external payable returns (uint256);
}

/// @notice Minimal weETH wrapper - wrap rebasing eETH into non-rebasing weETH.
interface IWeETHWrapper {
    function wrap(uint256 eETHAmount) external returns (uint256);
}

/// @notice F15-07 - Karak v2 multi-LRT basket: deposit pufETH + weETH + wstETH
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
contract F15_07_KarakMultiLrtBasketVaultTest is StrategyBase {
    // ---- Karak v2 vault addresses ----
    // Karak deploys per-asset vaults under its DelegationSupervisor. The
    // canonical addresses below correspond to the Sep-2024 v2 launch set.
    // Cross-reference: Karak docs (https://docs.karak.network/) + Etherscan
    // label "Karak: ...Vault".

    /// @dev Karak wstETH vault. Largest single LST vault on Karak.
    address constant KARAK_WSTETH_VAULT = 0xa1a300919ddf0dc4b6ce1acfc1f4f71be0e80f97;

    /// @dev Karak pufETH vault. Active since Karak v1 (Apr 2024).
    address constant KARAK_PUFETH_VAULT = 0xbe3ca34d0e877a1fc889bd5231d65477779aff4e;

    /// @dev Karak weETH vault.
    address constant KARAK_WEETH_VAULT = 0x7c22725d1e0871f0043397c9761ad99a86ffd498;

    /// @dev Sep 2024 - Karak v2 live, multi-LRT vaults all accepting deposits.
    uint256 constant FORK_BLOCK = 20_700_000;

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

        // =========================================================
        //  Leg A: ETH -> stETH -> wstETH -> Karak wstETH vault
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

            // Karak wstETH vault deposit (best-effort; vault may be capped).
            IERC20(Mainnet.WSTETH).approve(KARAK_WSTETH_VAULT, wstOut);
            try IKarakVault(KARAK_WSTETH_VAULT).deposit(wstOut, address(this)) returns (uint256 sh) {
                console2.log("Leg A: Karak-wstETH shares:", sh);
            } catch Error(string memory reason) {
                console2.log("Leg A: Karak wstETH deposit reverted:", reason);
            } catch {
                console2.log("Leg A: Karak wstETH deposit reverted (unknown)");
            }
        }

        // =========================================================
        //  Leg B: ETH -> eETH -> weETH -> Karak weETH vault
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
                    IERC20(Mainnet.WEETH).approve(KARAK_WEETH_VAULT, weOut);
                    try IKarakVault(KARAK_WEETH_VAULT).deposit(weOut, address(this)) returns (uint256 sh) {
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
        //  Leg C: ETH -> stETH -> wstETH -> pufETH -> Karak pufETH vault
        // =========================================================
        {
            // Mint another batch of stETH via Lido.
            IStETH(Mainnet.STETH).submit{value: LEG_ETH}(address(0));
            uint256 stBalC = IERC20(Mainnet.STETH).balanceOf(address(this));
            // Wrap whatever stETH we now hold from the leg-C mint (LEG_ETH-ish).
            // We re-snapshot the wstETH delta around the wrap to isolate leg C.
            uint256 wstBefore = IERC20(Mainnet.WSTETH).balanceOf(address(this));
            IERC20(Mainnet.STETH).approve(Mainnet.WSTETH, stBalC);
            IWstETH(Mainnet.WSTETH).wrap(stBalC);
            uint256 wstForPuffer = IERC20(Mainnet.WSTETH).balanceOf(address(this)) - wstBefore;
            console2.log("Leg C: wstETH ready for Puffer:", wstForPuffer);

            // Mint pufETH from wstETH.
            uint256 pufBefore = IERC20(Mainnet.PUFETH).balanceOf(address(this));
            IERC20(Mainnet.WSTETH).approve(Mainnet.PUFETH, wstForPuffer);
            try IPufETH(Mainnet.PUFETH).depositWstETH(wstForPuffer, address(this)) returns (uint256) {
                // ok
            } catch Error(string memory reason) {
                console2.log("Leg C: pufETH mint reverted:", reason);
            } catch {
                console2.log("Leg C: pufETH mint reverted (unknown)");
            }
            uint256 pufMinted = IERC20(Mainnet.PUFETH).balanceOf(address(this)) - pufBefore;
            console2.log("Leg C: pufETH minted:", pufMinted);

            if (pufMinted > 0) {
                IERC20(Mainnet.PUFETH).approve(KARAK_PUFETH_VAULT, pufMinted);
                try IKarakVault(KARAK_PUFETH_VAULT).deposit(pufMinted, address(this)) returns (uint256 sh) {
                    console2.log("Leg C: Karak-pufETH shares:", sh);
                } catch Error(string memory reason) {
                    console2.log("Leg C: Karak pufETH deposit reverted:", reason);
                } catch {
                    console2.log("Leg C: Karak pufETH deposit reverted (unknown)");
                }
            }
        }

        // ---- Report ----
        uint256 karWst = IKarakVault(KARAK_WSTETH_VAULT).balanceOf(address(this));
        uint256 karWee = IKarakVault(KARAK_WEETH_VAULT).balanceOf(address(this));
        uint256 karPuf = IKarakVault(KARAK_PUFETH_VAULT).balanceOf(address(this));
        console2.log("Karak wstETH balance:", karWst);
        console2.log("Karak weETH  balance:", karWee);
        console2.log("Karak pufETH balance:", karPuf);

        _endPnL("F15-07: karak-multi-lrt-basket-vault");

        // Sanity: at least one leg must land a Karak-share balance.
        require(karWst > 0 || karWee > 0 || karPuf > 0, "all 3 Karak deposits failed");
    }
}
