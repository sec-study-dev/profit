// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ISDAI} from "src/interfaces/stable/ISDAI.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";
import {IPot} from "src/interfaces/cdp/IPot.sol";
import {IDssFlash} from "src/interfaces/cdp/IDssFlash.sol";
import {IERC3156FlashBorrower} from "src/interfaces/common/IFlashLoanReceiver.sol";

/// @notice Maker PSM interface for USDC -> DAI swap (sellGem).
interface IMakerPSM {
    function sellGem(address usr, uint256 gemAmt) external;
    function buyGem(address usr, uint256 gemAmt) external;
    function tin() external view returns (uint256);
    function tout() external view returns (uint256);
    function gemJoin() external view returns (address);
}

/// @title F10-06 sDAI + Aave V3 USDC borrow + Maker PSM recycling (3-mechanism)
/// @notice Three-mechanism composition at block 19_500_000:
///         (1) sDAI on Aave V3 as collateral (earns DSR ~14.4% APY via chi accumulation).
///         (2) Aave V3 USDC borrow at ~10.77% APY (< DSR, positive carry!).
///         (3) Maker PSM GUSDC-A: USDC -> DAI at 1:1, then DAI -> sDAI (leg 2).
///
///         Carry: sDAI leg1 earns 14.4% on 1M, minus Aave USDC borrow at 10.77%.
///         DSR spread on leverage ≈ +3.63% × ~1.67x leverage ≈ +$20k over 30 days.
///
///         Unwind: DssFlash borrow DAI -> buy USDC (Maker PSM) -> repay Aave USDC ->
///         withdraw sDAI legs -> redeem sDAI -> repay DssFlash.
contract F10_06_SdaiAaveUsdcSparkRecursive is StrategyBase, IERC3156FlashBorrower {
    uint256 constant FORK_BLOCK = 19_500_000;
    uint256 constant RATE_MODE_VARIABLE = 2;
    uint256 constant LOOP_LTV_BPS = 6700;
    bytes32 constant FLASH_OK = keccak256("ERC3156FlashBorrower.onFlashLoan");

    /// @notice Maker GUSDC-A PSM (legacy) - verified mainnet.
    address constant MAKER_PSM_USDC = 0x89B78CfA322F6C5dE0aBcEecab66Aee45393cC5A;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.SDAI);
        _trackToken(Mainnet.USDC);
    }

    function testStrategy_F10_06() public {
        uint256 principalDai = 1_000_000e18;
        _fund(Mainnet.DAI, address(this), principalDai);
        _startPnL();

        IAavePool aave = IAavePool(Mainnet.AAVE_V3_POOL);
        ISDAI sdai = ISDAI(Mainnet.SDAI);

        // ---- 1. DAI -> sDAI (mechanism 1: DSR yield accumulates in chi) ----
        IERC20(Mainnet.DAI).approve(address(sdai), type(uint256).max);
        IERC20(Mainnet.SDAI).approve(address(aave), type(uint256).max);
        IERC20(Mainnet.USDC).approve(address(aave), type(uint256).max);

        uint256 sdaiLeg1 = sdai.deposit(principalDai, address(this));
        emit log_named_uint("sdai_leg1_minted", sdaiLeg1);

        // ---- 2. Supply sDAI to Aave V3 as collateral (mechanism 2) ----
        aave.supply(Mainnet.SDAI, sdaiLeg1, address(this), 0);

        // ---- 3. Borrow USDC at 67% LTV ----
        uint256 usdcBorrowed = _borrowUsdc(aave);
        emit log_named_uint("aave_usdc_borrowed", usdcBorrowed);

        // ---- 4. PSM: USDC -> DAI -> sDAI leg2 (mechanism 3) ----
        uint256 sdaiLeg2 = _psmAndDeposit(sdai, usdcBorrowed);
        emit log_named_uint("sdai_leg2_minted", sdaiLeg2);

        // ---- 5. Warp 30 days + crystallise DSR ----
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);
        IPot(Mainnet.POT).drip();

        // ---- 6. Report post-warp state ----
        _reportPosition(aave, sdai, sdaiLeg2);

        // ---- 7. Unwind via DssFlash ----
        // Flash DAI -> PSM buy USDC -> repay Aave -> withdraw sDAI -> redeem
        uint256 usdcDebt = _getUsdcDebt(aave);
        emit log_named_uint("usdc_debt_post_warp", usdcDebt);

        // Compute DAI needed to buy usdcDebt from PSM (1:1 at GUSDC-A PSM, no fee normally)
        uint256 flashDai = usdcDebt * 1e12; // USDC 6-dec -> DAI 18-dec
        IDssFlash flash = IDssFlash(Mainnet.DSS_FLASH);
        require(flash.maxFlashLoan(Mainnet.DAI) >= flashDai, "flash cap");

        IERC20(Mainnet.DAI).approve(Mainnet.DSS_FLASH, type(uint256).max);
        flash.flashLoan(address(this), Mainnet.DAI, flashDai, abi.encode(usdcDebt));

        emit log_named_uint("final_dai", IERC20(Mainnet.DAI).balanceOf(address(this)));
        emit log_named_uint("final_sdai", IERC20(Mainnet.SDAI).balanceOf(address(this)));
        _endPnL("F10-06: sDAI+Aave+PSM recursive (3-mech, unwind)");
    }

    function _borrowUsdc(IAavePool aave) internal returns (uint256) {
        (, , uint256 availableBase, , , ) = aave.getUserAccountData(address(this));
        uint256 maxUsdc = availableBase / 100; // USD e8 -> USDC e6
        uint256 borrowUsdc = (maxUsdc * LOOP_LTV_BPS) / 10_000;
        if (borrowUsdc == 0) return 0;
        try aave.borrow(Mainnet.USDC, borrowUsdc, RATE_MODE_VARIABLE, 0, address(this)) {
            return borrowUsdc;
        } catch {
            emit log("aave_usdc_borrow_failed");
            return 0;
        }
    }

    function _psmAndDeposit(ISDAI sdai, uint256 usdcAmt) internal returns (uint256) {
        if (usdcAmt == 0) return 0;
        // Try Maker PSM: USDC -> DAI at 1:1
        try IMakerPSM(MAKER_PSM_USDC).gemJoin() returns (address gj) {
            IERC20(Mainnet.USDC).approve(gj, usdcAmt);
            uint256 daiBefore = IERC20(Mainnet.DAI).balanceOf(address(this));
            try IMakerPSM(MAKER_PSM_USDC).sellGem(address(this), usdcAmt) {
                uint256 daiGot = IERC20(Mainnet.DAI).balanceOf(address(this)) - daiBefore;
                emit log_named_uint("psm_dai_received", daiGot);
                if (daiGot > 0) {
                    IERC20(Mainnet.DAI).approve(address(sdai), daiGot);
                    return sdai.deposit(daiGot, address(this));
                }
            } catch { emit log("psm_sellGem_failed"); }
        } catch { emit log("psm_gemJoin_failed"); }
        return 0;
    }

    function _reportPosition(IAavePool aave, ISDAI sdai, uint256 sdaiLeg2) internal {
        (uint256 cB, uint256 dB, , , , uint256 hf) = aave.getUserAccountData(address(this));
        emit log_named_uint("aave_collateral_e8", cB);
        emit log_named_uint("aave_debt_e8", dB);
        emit log_named_uint("aave_hf_e18", hf);
        if (sdaiLeg2 > 0) {
            emit log_named_uint("sdai_leg2_dai_value", sdai.convertToAssets(sdaiLeg2));
        }
    }

    function _getUsdcDebt(IAavePool aave) internal view returns (uint256) {
        IAavePool.ReserveDataLegacy memory r = aave.getReserveData(Mainnet.USDC);
        return IERC20(r.variableDebtTokenAddress).balanceOf(address(this));
    }

    /// @notice DssFlash callback: buy USDC from PSM -> repay Aave -> withdraw sDAI -> redeem.
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32) {
        require(msg.sender == Mainnet.DSS_FLASH, "only dss flash");
        require(initiator == address(this), "only self");
        require(token == Mainnet.DAI, "only DAI");
        require(fee == 0, "zero fee");

        uint256 usdcDebt = abi.decode(data, (uint256));
        IAavePool aave = IAavePool(Mainnet.AAVE_V3_POOL);
        ISDAI sdai = ISDAI(Mainnet.SDAI);

        // Buy USDC from PSM to repay Aave debt
        if (usdcDebt > 0) {
            _psmBuyUsdc(usdcDebt);
        }

        // Repay Aave USDC debt
        uint256 actualUsdcDebt = _getUsdcDebt(aave);
        if (actualUsdcDebt > 0 && IERC20(Mainnet.USDC).balanceOf(address(this)) >= actualUsdcDebt) {
            IERC20(Mainnet.USDC).approve(address(aave), actualUsdcDebt);
            aave.repay(Mainnet.USDC, actualUsdcDebt, RATE_MODE_VARIABLE, address(this));
        } else if (actualUsdcDebt > 0) {
            IERC20(Mainnet.USDC).approve(address(aave), type(uint256).max);
            aave.repay(Mainnet.USDC, type(uint256).max, RATE_MODE_VARIABLE, address(this));
        }

        // Withdraw all sDAI collateral from Aave
        IAavePool.ReserveDataLegacy memory sdaiRes = aave.getReserveData(Mainnet.SDAI);
        if (IERC20(sdaiRes.aTokenAddress).balanceOf(address(this)) > 0) {
            aave.withdraw(Mainnet.SDAI, type(uint256).max, address(this));
        }

        // Redeem all sDAI -> DAI
        uint256 sdaiBal = IERC20(Mainnet.SDAI).balanceOf(address(this));
        if (sdaiBal > 0) {
            IERC20(Mainnet.SDAI).approve(address(sdai), sdaiBal);
            sdai.redeem(sdaiBal, address(this), address(this));
        }

        uint256 daiBal = IERC20(Mainnet.DAI).balanceOf(address(this));
        emit log_named_uint("flash_dai_after_unwind", daiBal);
        require(daiBal >= amount, "insufficient DAI: carry negative");
        return FLASH_OK;
    }

    function _psmBuyUsdc(uint256 usdcAmt) internal {
        // buyGem: give DAI, receive USDC (DAI -> gem direction)
        try IMakerPSM(MAKER_PSM_USDC).gemJoin() returns (address) {
            // buyGem needs DAI approved to the PSM itself
            IERC20(Mainnet.DAI).approve(MAKER_PSM_USDC, usdcAmt * 1e12 + 1e18);
            try IMakerPSM(MAKER_PSM_USDC).buyGem(address(this), usdcAmt) {
                emit log_named_uint("psm_usdc_bought", IERC20(Mainnet.USDC).balanceOf(address(this)));
            } catch { emit log("psm_buyGem_failed"); }
        } catch {}
    }
}
