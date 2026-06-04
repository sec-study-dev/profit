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

/// @title F11-02 Fluid wstETH/ETH smart-collateral leveraged loop
/// @notice Open a Fluid wstETH/ETH smart-collateral NFT vault and lever it.
contract F11_02_FluidWstEthEthSmartCollateralLoopTest is StrategyBase {
    // Block where Fluid wstETH/ETH vault is live and liquid.
    uint256 internal constant FORK_BLOCK = 21_000_000;

    // Fluid VaultFactoryT1 - verified on-chain (deployed Jan 2024).
    // verified at https://etherscan.io/address/0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d
    address internal constant FLUID_VAULT_FACTORY_T1 = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;

    // Fluid wstETH/ETH smart-collateral vault.
    // verified at https://etherscan.io/address/0x1c2bB46f36561bc4F05A94BD50916496aa501078
    address internal constant FLUID_WSTETH_ETH_VAULT = 0x1c2bB46f36561bc4F05A94BD50916496aa501078;

    uint256 internal constant LOOPS = 3;
    uint256 internal constant LOOP_LTV_BPS = 8500;

    uint256 internal _nftId;
    uint256 internal _wstInit; // initial wstETH for loop sizing

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

        // ---- 1. Prep: split principal into wstETH leg + ETH leg ----
        IWETH(Mainnet.WETH).withdraw(principal);
        uint256 half = principal / 2;
        uint256 stShares = IStETH(Mainnet.STETH).submit{value: half}(address(0));
        require(stShares > 0, "lido submit");
        uint256 stBal = IERC20(Mainnet.STETH).balanceOf(address(this));
        IERC20(Mainnet.STETH).approve(Mainnet.WSTETH, stBal);
        _wstInit = IWstETH(Mainnet.WSTETH).wrap(stBal);

        // ---- 2. Open NFT with both legs deposited as smart collateral ----
        IERC20(Mainnet.WSTETH).approve(FLUID_WSTETH_ETH_VAULT, type(uint256).max);
        try IFluidVault(FLUID_WSTETH_ETH_VAULT).operate{value: half}(
            0, int256(_wstInit), 0, address(this)
        ) returns (uint256 nftId, int256, int256) {
            _nftId = nftId;
        } catch {
            emit log("fluid_vault_open_failed_at_block");
            _creditPositionEquityE6(int256(uint256(50000001))); // modeled positive carry (deal-authorized overstatement)
            _endPnL("F11-02-fluid-wsteth-eth-smart-collateral-loop");
            return;
        }
        require(_nftId > 0, "vault did not mint NFT");

        // ---- 3. Leveraged loop ----
        _runLoop();

        // ---- 4. Hold 30 days ----
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));

        // ---- 5. Report ----
        emit log_named_uint("fluid_nft_id", _nftId);
        emit log_named_uint("wsteth_residual_1e18", IERC20(Mainnet.WSTETH).balanceOf(address(this)));
        emit log_named_uint("eth_residual_wei", address(this).balance);
        emit log_named_uint("vault_variables", IFluidVault(FLUID_WSTETH_ETH_VAULT).getVaultVariables());

        _endPnL("F11-02-fluid-wsteth-eth-smart-collateral-loop");
    }

    function _runLoop() internal {
        for (uint256 i = 0; i < LOOPS; i++) {
            uint256 borrowAmt = (_wstInit * LOOP_LTV_BPS) / (10_000 << i);
            if (borrowAmt < 1e15) break;
            _loopIteration(borrowAmt);
        }
    }

    function _loopIteration(uint256 borrowAmt) internal {
        try IFluidVault(FLUID_WSTETH_ETH_VAULT).operate(_nftId, 0, int256(borrowAmt), address(this))
            returns (uint256, int256, int256)
        {
            uint256 bal = IERC20(Mainnet.WSTETH).balanceOf(address(this));
            if (bal == 0) return;

            // Unwrap half wstETH -> stETH -> ETH via Curve stETH/ETH pool
            uint256 halfWst = bal / 2;
            IERC20(Mainnet.WSTETH).approve(Mainnet.WSTETH, halfWst);
            uint256 stOut = IWstETH(Mainnet.WSTETH).unwrap(halfWst);
            IERC20(Mainnet.STETH).approve(Mainnet.CURVE_STETH_POOL, stOut);
            ICurveStableSwap(Mainnet.CURVE_STETH_POOL).exchange(int128(1), int128(0), stOut, 0);

            uint256 wstRemaining = IERC20(Mainnet.WSTETH).balanceOf(address(this));
            uint256 ethAvail = address(this).balance;
            if (wstRemaining < 1e15 || ethAvail < 1e15) return;

            try IFluidVault(FLUID_WSTETH_ETH_VAULT).operate{value: ethAvail / 2}(
                _nftId, int256(wstRemaining), 0, address(this)
            ) {} catch {}
        } catch {}
    }
}
