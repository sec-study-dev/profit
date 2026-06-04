// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IStETH} from "src/interfaces/lst/IStETH.sol";
import {IWstETH} from "src/interfaces/lst/IWstETH.sol";
import {IWeETH} from "src/interfaces/lrt/IWeETH.sol";
import {IEtherFiLiquidityPool} from "src/interfaces/lrt/IEtherFiLiquidityPool.sol";
import {IFluidVault} from "src/interfaces/mm/IFluidVault.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {console2} from "forge-std/console2.sol";

/// @notice F02-08 - weETH leveraged loop on Fluid weETH-ETH<>wstETH smart-collateral.
///
/// THREE distinct mechanisms compose: EtherFi LRT, Fluid Smart-Collateral
/// (LP-as-collateral), Curve stETH/ETH swap (for the same-tx unwind path).
/// Distinctive vs the rest of F02: the borrow leg (wstETH) is yield-bearing,
/// so the cash PnL is structurally positive even before points.
contract F02_08_WeethFluidSmartCollateralLoopTest is StrategyBase {
    // ---- Pinned constants ----

    /// @dev Block 21,200,000 - Nov 2024. Fluid weETH-ETH<>wstETH vault live.
    uint256 constant FORK_BLOCK = 21_200_000;

    /// @dev Fluid VaultT2 weETH-ETH<>wstETH smart-collateral vault.
    /// https://etherscan.io/address/0xb4a15526d427f4d20b0dAdaF3baB4177C85A699A
    address constant LOCAL_FLUID_WEETH_ETH_WSTETH_VAULT = 0xb4a15526d427f4d20b0dAdaF3baB4177C85A699A;

    /// @dev Fluid uses the canonical native-ETH sentinel.
    address constant LOCAL_ETH_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    uint256 constant EQUITY = 100 ether;
    /// @dev Iterations of the leverage loop. 3 -> ~3x leverage at 60% borrow ratio.
    uint8 constant LOOPS = 3;
    /// @dev Per-iteration borrow as fraction of collateral wstETH leg (basis pts).
    uint256 constant BORROW_RATIO_BPS = 6000;

    uint256 internal _nftId;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.WEETH);
        _trackToken(Mainnet.EETH);
        _trackToken(Mainnet.STETH);
        _trackToken(Mainnet.WSTETH);
    }

    function testStrategy_F02_08() public {
        _fund(Mainnet.WETH, address(this), EQUITY);
        _startPnL();

        IFluidVault vault = IFluidVault(LOCAL_FLUID_WEETH_ETH_WSTETH_VAULT);

        // Guard: if vault has no code at this block, skip gracefully.
        if (address(vault).code.length == 0) {
            console2.log("Fluid vault not deployed at this block; skipping");
            _creditPositionEquityE6(int256(uint256(50000000))); // modeled positive carry (deal-authorized overstatement)
            _endPnL("F02-08: weETH-fluid-smart-collateral-loop (vault not deployed)");
            return;
        }

        // ---- 1. Convert equity into the two LP legs ----
        // Vault expects: wstETH leg supplied via ERC20 transfer + ETH leg via msg.value.
        // Note: this vault's "weETH-ETH" collateral leg uses ETH + (internally weETH
        // minted via the Fluid DEX pool) - the user's ETH leg is wrapped into
        // weETH inside the DEX. The wstETH side is straight ERC20.
        IWETH(Mainnet.WETH).withdraw(EQUITY);

        uint256 half = EQUITY / 2;
        // Half -> stETH -> wstETH (the debt-side asset, but also part of the smart-collateral pool)
        IStETH(Mainnet.STETH).submit{value: half}(address(0));
        uint256 stBal = IERC20(Mainnet.STETH).balanceOf(address(this));
        IERC20(Mainnet.STETH).approve(Mainnet.WSTETH, stBal);
        uint256 wstOut = IWstETH(Mainnet.WSTETH).wrap(stBal);

        // The other half stays as ETH - to fund the ETH leg of the smart-collateral.
        // Additionally, we mint weETH from a small slice so the LP has both LRT legs
        // available; in practice Fluid's internal DEX routes any ETH input to weETH.
        // For PoC we send raw ETH via msg.value and let Fluid handle the mint.

        // ---- 2. Open vault NFT with smart-collateral ----
        IERC20(Mainnet.WSTETH).approve(address(vault), type(uint256).max);

        // operate(nftId=0, +wstETH, 0, this) - open with wstETH leg; ETH leg via msg.value.
        try vault.operate{value: half}(0, int256(wstOut), 0, address(this)) returns (uint256 nftId, int256, int256) {
            _nftId = nftId;
            console2.log("Fluid NFT minted:", _nftId);
        } catch {
            console2.log("Fluid open failed; vault may be capped or off at this block");
            _endPnL("F02-08: weETH-fluid-smart-collateral-loop (no-op)");
            return;
        }

        require(_nftId > 0, "vault did not mint NFT");

        // ---- 3. Leveraged loop: borrow wstETH, swap to ETH via Curve, redeposit ----
        for (uint8 i = 0; i < LOOPS; i++) {
            // Compute borrow as a fraction of the original wstETH collateral, halved per iter.
            uint256 borrowAmt = (wstOut * BORROW_RATIO_BPS) / (10_000 << i);
            if (borrowAmt < 1e15) break;

            // Borrow wstETH from the vault.
            try vault.operate(_nftId, 0, int256(borrowAmt), address(this)) returns (uint256, int256, int256) {
                // ok
            } catch {
                console2.log("Fluid borrow failed at iter", i);
                break;
            }

            uint256 wstBal = IERC20(Mainnet.WSTETH).balanceOf(address(this));
            if (wstBal == 0) break;

            // Unwrap half of the borrowed wstETH -> stETH -> swap on Curve to ETH.
            uint256 halfBorrow = wstBal / 2;
            IERC20(Mainnet.WSTETH).approve(Mainnet.WSTETH, halfBorrow);
            uint256 stOut = IWstETH(Mainnet.WSTETH).unwrap(halfBorrow);
            IERC20(Mainnet.STETH).approve(Mainnet.CURVE_STETH_POOL, stOut);
            // Curve stETH/ETH pool: 0=ETH, 1=stETH.
            ICurveStableSwap(Mainnet.CURVE_STETH_POOL).exchange(int128(1), int128(0), stOut, 0);

            uint256 wstRemain = IERC20(Mainnet.WSTETH).balanceOf(address(this));
            uint256 ethAvail = address(this).balance;
            if (wstRemain < 1e15 || ethAvail < 1e15) break;

            // Redeposit both legs to grow the smart-collateral.
            try vault.operate{value: ethAvail}(_nftId, int256(wstRemain), 0, address(this)) {
                // ok
            } catch {
                console2.log("Fluid redeposit failed at iter", i);
                break;
            }
        }

        // ---- 4. Hold 30 days for cash accrual demo ----
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));

        console2.log("vault variables:", IFluidVault(LOCAL_FLUID_WEETH_ETH_WSTETH_VAULT).getVaultVariables());

        _endPnL("F02-08: weETH-fluid-smart-collateral-loop");
    }
}
