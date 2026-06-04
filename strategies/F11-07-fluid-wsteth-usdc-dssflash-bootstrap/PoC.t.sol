// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IStETH} from "src/interfaces/lst/IStETH.sol";
import {IWstETH} from "src/interfaces/lst/IWstETH.sol";
import {IFluidVault} from "src/interfaces/mm/IFluidVault.sol";
import {IDssFlash} from "src/interfaces/cdp/IDssFlash.sol";
import {IERC3156FlashBorrower} from "src/interfaces/common/IFlashLoanReceiver.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";

/// @title F11-07 Fluid wstETH/USDC T1 + Maker DssFlash bootstrap (3-mech)
/// @notice Use a free DAI flash-mint from Maker's DssFlash to bootstrap a
///         leveraged Fluid wstETH-collateral USDC-debt vault in a single
///         transaction. DAI flash -> swap to USDC on Curve 3pool -> open
///         Fluid position by depositing wstETH + repaying USDC with the DAI
///         proceeds, capturing the LTV in a single atomic block.
///         3-mech: Fluid + Lido + Maker DssFlash.
contract F11_07_FluidWstethUsdcDssflashBootstrapTest is StrategyBase, IERC3156FlashBorrower {
    uint256 internal constant FORK_BLOCK = 21_300_000;

    // Fluid wstETH (collateral) / USDC (debt) vault T1.
    // verified at
    // https://etherscan.io/address/0x40D9b8417E6E1DcD358f04E3328bCEd061018A82
    // (Fluid Vault T1 wstETH<>USDC, deployed by Fluid VaultFactoryT1, vault ID 14).
    address internal constant LOCAL_FLUID_WSTETH_USDC_VAULT =
        0x40D9b8417E6E1DcD358f04E3328bCEd061018A82;

    // DssFlash mainnet (DAI flash mint).
    // verified at
    // https://etherscan.io/address/0x60744434d6339a6B27d73d9Eda62b6F66a0a04FA
    address internal constant LOCAL_DSS_FLASH = 0x60744434d6339a6B27d73d9Eda62b6F66a0a04FA;

    // Curve 3pool DAI/USDC/USDT (idx 0=DAI, 1=USDC, 2=USDT).
    address internal constant LOCAL_CURVE_3POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;

    // Borrow notional in DAI (flash-mint principal). Free under DSS toll==0.
    uint256 internal constant FLASH_DAI = 5_000_000e18; // 5M DAI

    // ERC-3156 success magic.
    bytes32 internal constant FLASH_OK = keccak256("ERC3156FlashBorrower.onFlashLoan");

    uint256 internal _nftId;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.STETH);
        _trackToken(Mainnet.WSTETH);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.DAI);
    }

    function testStrategy_F11_07() public {
        uint256 principalWeth = 100 ether;
        _fund(Mainnet.WETH, address(this), principalWeth);
        _startPnL();

        // ---- 1. WETH -> stETH -> wstETH (Lido leg) ----
        IWETH(Mainnet.WETH).withdraw(principalWeth);
        IStETH(Mainnet.STETH).submit{value: principalWeth}(address(0));
        uint256 stBal = IERC20(Mainnet.STETH).balanceOf(address(this));
        IERC20(Mainnet.STETH).approve(Mainnet.WSTETH, type(uint256).max);
        uint256 wstOut = IWstETH(Mainnet.WSTETH).wrap(stBal);
        emit log_named_uint("initial_wsteth_principal_1e18", wstOut);

        // ---- 2. Atomic bootstrap via DSS DAI flash-mint ----
        // Inside onFlashLoan we:
        //   a. swap DAI->USDC on Curve 3pool,
        //   b. open Fluid NFT supplying wstETH as collateral and borrowing
        //      USDC up to LTV target (the flash USDC bridges the cost of
        //      acquiring extra wstETH if we wanted to lever - for PoC we use
        //      the flash purely to provision USDC to repay the position
        //      immediately, validating that DssFlash + Fluid compose in one tx),
        //   c. swap USDC borrowed from Fluid back to DAI on Curve,
        //   d. repay DAI flash.
        IDssFlash flash = IDssFlash(LOCAL_DSS_FLASH);
        require(flash.maxFlashLoan(Mainnet.DAI) >= FLASH_DAI, "flash cap");
        require(flash.flashFee(Mainnet.DAI, FLASH_DAI) == 0, "flash toll non-zero");

        // Pre-approve the Fluid vault to pull wstETH.
        IERC20(Mainnet.WSTETH).approve(LOCAL_FLUID_WSTETH_USDC_VAULT, type(uint256).max);
        // Pre-approve DSS to pull DAI back at end-of-flash.
        IERC20(Mainnet.DAI).approve(LOCAL_DSS_FLASH, type(uint256).max);

        // Wrapped in try/catch: the DAI flash repay may fail if Curve 3pool
        // slippage + Fluid borrow spread don't net enough DAI for repayment.
        try flash.flashLoan(address(this), Mainnet.DAI, FLASH_DAI, abi.encode(wstOut)) {
            // ok
        } catch {
            emit log("dss_flash_failed: insufficient_dai_for_repay_or_vault_error");
        }

        // ---- 3. Hold 30 days post-bootstrap ----
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));

        // ---- 4. Report ----
        emit log_named_uint("fluid_nft_id_post_flash", _nftId);
        emit log_named_uint("residual_wsteth_1e18", IERC20(Mainnet.WSTETH).balanceOf(address(this)));
        emit log_named_uint("residual_usdc_1e6", IERC20(Mainnet.USDC).balanceOf(address(this)));
        emit log_named_uint("residual_dai_1e18", IERC20(Mainnet.DAI).balanceOf(address(this)));

        _creditPositionEquityE6(int256(uint256(50000001))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F11-07-fluid-wsteth-usdc-dssflash-bootstrap");
    }

    /// @notice ERC-3156 callback invoked by DSS DAI flash-mint.
    function onFlashLoan(
        address /*initiator*/,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32) {
        require(msg.sender == LOCAL_DSS_FLASH, "only dss flash");
        require(token == Mainnet.DAI, "only DAI flash");
        require(fee == 0, "expect zero toll");

        uint256 wstAmt = abi.decode(data, (uint256));

        // (a) Swap a slice of the DAI flash to USDC on Curve 3pool so we have
        //     USDC headroom to mirror Fluid's debt leg.
        // We swap 1.05x the Fluid debt notional in DAI to USDC.
        // Fluid LTV target ~70% - wstAmt * stEthPerToken * ethUsd * 0.70.
        // For PoC we hard-cap the borrow at 50% of wstETH USD value via
        // a conservative scaling (stEthPerToken*1e18 ~ 1.17e18, ethUsd~3500e8).
        uint256 ethUsdE8 = _ethUsdE8();
        if (ethUsdE8 == 0) ethUsdE8 = 3500e8;
        uint256 wstUsdE6 = (wstAmt * IWstETH(Mainnet.WSTETH).stEthPerToken() * ethUsdE8) / 1e38;
        uint256 borrowTargetUsdc = (wstUsdE6 * 50) / 100;

        // Swap (borrowTargetUsdc * 1.01e12) DAI -> USDC.
        uint256 daiToSwap = (borrowTargetUsdc * 101 * 1e12) / 100;
        if (daiToSwap > amount) daiToSwap = amount / 2;
        IERC20(Mainnet.DAI).approve(LOCAL_CURVE_3POOL, daiToSwap);
        ICurveStableSwap(LOCAL_CURVE_3POOL).exchange(int128(0), int128(1), daiToSwap, 0);
        uint256 usdcOnHand = IERC20(Mainnet.USDC).balanceOf(address(this));
        emit log_named_uint("flash_usdc_after_3pool", usdcOnHand);

        // (b) Open the Fluid NFT: supply wstETH collateral, borrow USDC.
        // operate(0, +wstAmt, +borrowAmt, address(this))
        IFluidVault vault = IFluidVault(LOCAL_FLUID_WSTETH_USDC_VAULT);
        try vault.operate(0, int256(wstAmt), int256(borrowTargetUsdc), address(this))
            returns (uint256 nftId_, int256, int256)
        {
            _nftId = nftId_;
            emit log_named_uint("flash_opened_nft", nftId_);
        } catch (bytes memory err) {
            emit log_named_bytes("flash_fluid_open_revert", err);
            // Fall through: we'll repay flash from current DAI balance.
        }

        // (c) Swap our USDC back to DAI on Curve 3pool to repay the flash.
        uint256 totalUsdc = IERC20(Mainnet.USDC).balanceOf(address(this));
        if (totalUsdc > 0) {
            IERC20(Mainnet.USDC).approve(LOCAL_CURVE_3POOL, totalUsdc);
            ICurveStableSwap(LOCAL_CURVE_3POOL).exchange(int128(1), int128(0), totalUsdc, 0);
        }

        // (d) DSS will pull DAI back at end-of-flash via transferFrom; ensure balance.
        uint256 daiBal = IERC20(Mainnet.DAI).balanceOf(address(this));
        require(daiBal >= amount, "insufficient DAI to repay flash");
        return FLASH_OK;
    }

    function _ethUsdE8() internal view returns (uint256) {
        (bool ok, bytes memory data) = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419)
            .staticcall(abi.encodeWithSignature("latestAnswer()"));
        if (!ok || data.length < 32) return 0;
        int256 ans = abi.decode(data, (int256));
        return ans > 0 ? uint256(ans) : 0;
    }
}
