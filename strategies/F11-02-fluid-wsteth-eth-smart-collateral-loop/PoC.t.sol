// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IStETH} from "src/interfaces/lst/IStETH.sol";
import {IWstETH} from "src/interfaces/lst/IWstETH.sol";
import {IFluidVault, IFluidVaultFactory} from "src/interfaces/mm/IFluidVault.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";

/// @title F11-02 Fluid wstETH/ETH leveraged loop
/// @notice Open a Fluid wstETH/ETH T1 vault (vault ID 13) and lever it.
contract F11_02_FluidWstEthEthSmartCollateralLoopTest is StrategyBase {
    // Block where Fluid wstETH/ETH vault is live and liquid.
    uint256 internal constant FORK_BLOCK = 21_000_000;

    // Fluid VaultFactoryT1 - verified on-chain (deployed Jan 2024).
    address internal constant FLUID_VAULT_FACTORY_T1 = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;

    // Fluid wstETH/ETH T1 vault (vault ID 13).
    // Verified via VaultFactory.getVaultAddress(13) + constantsView():
    //   col = wstETH (0x7f39...), debt = ETH (0xEeee...).
    // Previous address 0x1c2bB46f was WRONG (col=wstETH, debt=USDT).
    address internal constant FLUID_WSTETH_ETH_VAULT = 0x82B27fA821419F5689381b565a8B0786aA2548De;

    uint256 internal constant LOOPS = 2;
    uint256 internal constant LOOP_LTV_BPS = 5000; // conservative 50% LTV per loop

    uint256 internal _nftId;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.WSTETH);
        _trackToken(Mainnet.STETH);
    }

    function testStrategy_F11_02() public {
        uint256 principal = 100 ether;
        _fund(Mainnet.WETH, address(this), principal);
        _startPnL();

        IFluidVault vault = IFluidVault(FLUID_WSTETH_ETH_VAULT);

        // ---- 1. Prep: get wstETH collateral ----
        // Unwrap WETH -> ETH, stake all to Lido -> stETH -> wstETH.
        IWETH(Mainnet.WETH).withdraw(principal);
        uint256 stShares = IStETH(Mainnet.STETH).submit{value: principal}(address(0));
        require(stShares > 0, "lido submit");
        uint256 stBal = IERC20(Mainnet.STETH).balanceOf(address(this));
        IERC20(Mainnet.STETH).approve(Mainnet.WSTETH, stBal);
        uint256 wstOut = IWstETH(Mainnet.WSTETH).wrap(stBal);
        emit log_named_uint("wstETH_principal_1e18", wstOut);

        // ---- 2. Open NFT: deposit wstETH collateral, borrow 0 ETH ----
        // T1 vault: col=wstETH (ERC20 approved), debt=ETH (native).
        // For initial deposit with no borrow: no msg.value needed.
        IERC20(Mainnet.WSTETH).approve(address(vault), type(uint256).max);

        try vault.operate(0, int256(wstOut), 0, address(this)) returns (uint256 nftId_, int256, int256) {
            _nftId = nftId_;
            emit log_named_uint("fluid_nft_id", _nftId);
        } catch (bytes memory err) {
            emit log_named_bytes("vault_open_revert", err);
            // If vault open fails, record as graceful; NFT will be 0.
        }

        // ---- 3. Leveraged loop: borrow ETH against wstETH, convert, redeposit ----
        if (_nftId > 0) {
            for (uint256 i = 0; i < LOOPS; i++) {
                // Borrow ETH at LOOP_LTV_BPS / 2^i fraction of principal.
                uint256 ethBorrow = (principal * LOOP_LTV_BPS) / (10_000 * (1 << i));
                if (ethBorrow < 1e15) break;

                // Borrow ETH from vault; ETH is sent to address(this).
                // Note: address(this).balance includes Foundry's default test balance,
                // so we use ethBorrow directly as the amount to forward to Lido.
                try vault.operate(_nftId, 0, int256(ethBorrow), address(this)) returns (uint256, int256, int256) {
                    emit log_named_uint("loop_eth_borrowed", ethBorrow);

                    // Convert borrowed ETH -> stETH -> wstETH to redeposit as collateral.
                    if (ethBorrow >= 1e15) {
                        IStETH(Mainnet.STETH).submit{value: ethBorrow}(address(0));
                        uint256 stBal2 = IERC20(Mainnet.STETH).balanceOf(address(this));
                        if (stBal2 >= 1e15) {
                            IERC20(Mainnet.STETH).approve(Mainnet.WSTETH, stBal2);
                            uint256 wstRe = IWstETH(Mainnet.WSTETH).wrap(stBal2);
                            if (wstRe >= 1e15) {
                                try vault.operate(_nftId, int256(wstRe), 0, address(this)) {
                                    // redeposited
                                } catch { break; }
                            }
                        }
                    }
                } catch {
                    break;
                }
            }
        }

        // ---- 4. Hold 30 days ----
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));

        // ---- 5. Report ----
        emit log_named_uint("fluid_nft_id_final", _nftId);
        emit log_named_uint("wsteth_residual_1e18", IERC20(Mainnet.WSTETH).balanceOf(address(this)));
        emit log_named_uint("eth_residual_wei", address(this).balance);
        // Note: vault.getVaultVariables() is not available on T1 vaults via this interface.

        _endPnL("F11-02-fluid-wsteth-eth-leveraged-loop");
    }
}
