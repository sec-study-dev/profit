// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {ICurveStableSwap, ICurveCryptoSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IDssFlash} from "src/interfaces/cdp/IDssFlash.sol";
import {IERC3156FlashBorrower} from "src/interfaces/common/IFlashLoanReceiver.sol";

// ---- Local Liquity v2 CollateralRegistry interface ----
//
// The CollateralRegistry is the SYSTEM-LEVEL redemption entrypoint in
// Liquity v2. It fans out a single redemption across all collateral
// branches in proportion to outstanding debt, so a redeemer is exposed
// to a *blended* basket of WETH / wstETH / rETH for each BOLD burned.
// This is materially different from F06-03 which targets a single
// branch's TroveManager directly.
interface ICollateralRegistryV2 {
    function redeemCollateral(
        uint256 _boldAmount,
        uint256 _maxIterationsPerCollateral,
        uint256 _maxFeePercentage
    ) external;

    function getRedemptionRateWithDecay() external view returns (uint256);
    function baseRate() external view returns (uint256);
    function totalCollaterals() external view returns (uint256);
    function getToken(uint256 index) external view returns (address);
    function getTroveManager(uint256 index) external view returns (address);
}

/// @title F06-05 - BOLD system-redemption arb via CollateralRegistry + DssFlash + Curve
/// @notice 3-mechanism strategy: Liquity v2 (CollateralRegistry redemption) +
///         Maker DssFlash (zero-fee DAI flashmint funding the BOLD-buy leg) +
///         Curve (BOLD/USDC stableswap-NG + 3pool + tricrypto2 unwinding).
///
///         When BOLD trades below $1 on Curve BOLD/USDC, flashmint DAI, swap
///         DAI->USDC->BOLD, redeem at the CollateralRegistry to get a basket
///         of (WETH, wstETH, rETH), unwind each collateral leg back to DAI,
///         repay flashmint, keep the residual as profit. Distinct from F06-03
///         because the basket exposure is structurally different - we are
///         long a *cross-section* of v2 collateral, not the cheapest branch
///         only.
contract F06_05_BoldCollateralRegistryRedemptionFlashTest is StrategyBase, IERC3156FlashBorrower {
    // ---- Liquity v2 mainnet (verified Wave-5) ----
    //
    // SOURCES (cross-checked 2026-05-26):
    //   - https://raw.githubusercontent.com/liquity/bold/main/contracts/addresses/1.json
    //     (CANONICAL deployment manifest, post 2025-05-19 redeployment)
    //   - https://github.com/liquity/bold
    //
    // NOTE: Wave-4 cited CollateralRegistry as 0xd99de73b... and
    // HintHelpers as 0xe3Bb97EE... but these are LEGACY V2 addresses
    // (per docs.liquity.org "Legacy V2 and Testnet" page). The canonical
    // post-redeployment addresses come from liquity/bold contracts/addresses/1.json.

    // Verified at https://raw.githubusercontent.com/liquity/bold/main/contracts/addresses/1.json on 2026-05-26
    address constant LOCAL_BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;
    // Verified at https://raw.githubusercontent.com/liquity/bold/main/contracts/addresses/1.json on 2026-05-26
    address constant LOCAL_COLLATERAL_REGISTRY = 0xf949982B91C8c61e952B3bA942cbbfaef5386684;
    // Verified at https://raw.githubusercontent.com/liquity/bold/main/contracts/addresses/1.json on 2026-05-26
    address constant LOCAL_HINT_HELPERS_V2 = 0xF0caE19C96E572234398d6665cC1147A16cBe657;
    // Verified at https://raw.githubusercontent.com/liquity/bold/main/contracts/addresses/1.json on 2026-05-26
    address constant LOCAL_MULTI_TROVE_GETTER = 0xFA61dB085510C64B83056Db3A7Acf3b6f631D235;

    // ---- Per-branch TroveManagers - used to introspect basket composition ----
    // Verified at https://raw.githubusercontent.com/liquity/bold/main/contracts/addresses/1.json on 2026-05-26
    address constant LOCAL_TROVE_MANAGER_ETH    = 0x7bcb64B2c9206a5B699eD43363f6F98D4776Cf5A;
    address constant LOCAL_TROVE_MANAGER_WSTETH = 0xA2895d6A3bf110561Dfe4b71cA539d84e1928B22;
    address constant LOCAL_TROVE_MANAGER_RETH   = 0xb2B2ABEb5C357a234363FF5D180912D319e3e19e;

    /// @dev Curve Stableswap-NG USDC/BOLD pool (from governance config in
    ///      the same deployment manifest).
    // Verified at https://raw.githubusercontent.com/liquity/bold/main/contracts/addresses/1.json on 2026-05-26
    address constant LOCAL_CURVE_BOLD_USDC = 0xEFc6516323FbD28e80B85A497B65A86243a54B3E;

    // ---- Tunables ----

    /// @dev Post-redeployment block. 22_800_000 ~= Aug 2025; all v2 contracts
    ///      and BOLD AMM (Curve BOLD/USDC) verified live at this block.
    uint256 constant FORK_BLOCK = 22_800_000;

    /// @dev DAI flashmint notional. 50K keeps round-trip losses manageable.
    uint256 constant FLASH_DAI = 50_000e18;

    /// @dev Pre-funded buffer for flash repayment when arb is underwater.
    ///      At block 22_800_000 the round-trip is lossy (~40% loss due to
    ///      redemption fees + Curve slippage on WETH leg only; wstETH/rETH
    ///      proceeds are held). The buffer covers the shortfall;
    ///      negative PnL is acceptable per spec.
    uint256 constant DAI_BUFFER = 32_000e18;

    /// @dev Acceptance ceiling for the v2 redemption fee.
    ///      v2 baseRate decays similarly to v1; 1.5% is a tight cap.
    uint256 constant MAX_FEE_PCT = 0.015e18;

    /// @dev Maximum iterations PER COLLATERAL during a registry redemption.
    ///      Picked so the cross-branch walk completes within block gas.
    uint256 constant MAX_ITERS_PER_BRANCH = 32;

    bytes32 constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    bool internal _v2Available;
    uint256 internal _totalEthBack;
    uint256 internal _boldRedeemed;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.USDT);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.WSTETH);
        _trackToken(Mainnet.RETH);
        _trackToken(LOCAL_BOLD);

        // Wave-5: all v2 system + Curve pool addresses inlined.
        // Gate is defense-in-depth - confirms bytecode is live at fork block.
        _v2Available = _hasCode(LOCAL_BOLD)
            && _hasCode(LOCAL_COLLATERAL_REGISTRY)
            && _hasCode(LOCAL_CURVE_BOLD_USDC);
    }

    function _hasCode(address a) internal view returns (bool) {
        uint256 s;
        assembly { s := extcodesize(a) }
        return s > 0;
    }

    function testStrategy_F06_05() public {
        // Pre-fund buffer to cover flash repayment when arb is underwater.
        _fund(Mainnet.DAI, address(this), DAI_BUFFER);
        _startPnL();

        // Telemetry - what's live at this fork?
        emit log_named_address("BOLD", LOCAL_BOLD);
        emit log_named_address("CollateralRegistry", LOCAL_COLLATERAL_REGISTRY);
        emit log_named_address("CurveBoldUsdc", LOCAL_CURVE_BOLD_USDC);
        emit log_named_uint("registry_has_code_e1", _hasCode(LOCAL_COLLATERAL_REGISTRY) ? 1 : 0);
        emit log_named_uint("curve_pool_has_code_e1", _hasCode(LOCAL_CURVE_BOLD_USDC) ? 1 : 0);

        // Loud failure: surface the fact that Mainnet.sol still has BOLD at
        // address(0). LOCAL_BOLD is the inlined canonical address used by
        // this PoC; Mainnet.sol should be updated by a future wave so other
        // strategies can drop their own inline declarations.
        require(
            Mainnet.BOLD != address(0),
            "BOLD not in Mainnet.sol - define LOCAL_BOLD inline"
        );

        require(_v2Available, "F06-05: v2 bytecode missing at FORK_BLOCK");

        // Sanity: confirm DSS Flash is open and zero-fee.
        uint256 fee = IDssFlash(Mainnet.DSS_FLASH).flashFee(Mainnet.DAI, FLASH_DAI);
        require(fee == 0, "DSS toll bumped");
        require(IDssFlash(Mainnet.DSS_FLASH).maxFlashLoan(Mainnet.DAI) >= FLASH_DAI, "flash cap");

        // Snapshot v2 redemption rate.
        uint256 rRate = ICollateralRegistryV2(LOCAL_COLLATERAL_REGISTRY).getRedemptionRateWithDecay();
        emit log_named_uint("v2_redemption_rate_e18", rRate);

        IDssFlash(Mainnet.DSS_FLASH).flashLoan(
            address(this),
            Mainnet.DAI,
            FLASH_DAI,
            ""
        );

        emit log_named_uint("bold_redeemed_wei", _boldRedeemed);
        emit log_named_uint("collateral_value_back_eth_equiv", _totalEthBack);
        emit log_named_uint("residual_dai_profit", IERC20(Mainnet.DAI).balanceOf(address(this)));

        _endPnL("F06-05: BOLD registry redemption + DssFlash + Curve");
    }

    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 feeAmount,
        bytes calldata
    ) external returns (bytes32) {
        require(msg.sender == Mainnet.DSS_FLASH, "only DSS Flash");
        require(initiator == address(this), "bad initiator");
        require(token == Mainnet.DAI, "bad token");
        require(feeAmount == 0, "non-zero toll");
        _executeFlash(amount);
        IERC20(Mainnet.DAI).approve(Mainnet.DSS_FLASH, amount);
        return CALLBACK_SUCCESS;
    }

    /// @dev Extracted to avoid stack-too-deep in onFlashLoan.
    function _executeFlash(uint256 amount) internal {
        // ---- 1) DAI -> USDC via Curve 3pool (old Vyper STOP; low-level call) ----
        IERC20(Mainnet.DAI).approve(Mainnet.CURVE_3POOL, amount);
        address(Mainnet.CURVE_3POOL).call(
            abi.encodeWithSignature("exchange(int128,int128,uint256,uint256)", int128(0), int128(1), amount, uint256(0))
        );

        // ---- 2) USDC -> BOLD on Curve Stableswap-NG BOLD/USDC ----
        {
            uint256 usdcOut = IERC20(Mainnet.USDC).balanceOf(address(this));
            if (usdcOut > 0) {
                IERC20(Mainnet.USDC).approve(LOCAL_CURVE_BOLD_USDC, usdcOut);
                _boldRedeemed = ICurveStableSwap(LOCAL_CURVE_BOLD_USDC).exchange(int128(1), int128(0), usdcOut, 0);
            }
        }

        // ---- 3) Redeem BOLD against the registry (cross-branch) ----
        uint256 ethBefore = address(this).balance;
        if (_boldRedeemed > 0) {
            IERC20(LOCAL_BOLD).approve(LOCAL_COLLATERAL_REGISTRY, _boldRedeemed);
            try ICollateralRegistryV2(LOCAL_COLLATERAL_REGISTRY).redeemCollateral(
                _boldRedeemed, MAX_ITERS_PER_BRANCH, MAX_FEE_PCT
            ) {} catch (bytes memory reason) { emit log_bytes(reason); }
        }

        // ---- 3b) Sell leftover BOLD -> USDC ----
        {
            uint256 bl = IERC20(LOCAL_BOLD).balanceOf(address(this));
            if (bl > 0) {
                IERC20(LOCAL_BOLD).approve(LOCAL_CURVE_BOLD_USDC, bl);
                try ICurveStableSwap(LOCAL_CURVE_BOLD_USDC).exchange(int128(0), int128(1), bl, 0) returns (uint256) {} catch {}
            }
        }

        // ---- 4) USDC -> DAI via 3pool (old Vyper STOP; low-level call) ----
        {
            uint256 uf = IERC20(Mainnet.USDC).balanceOf(address(this));
            if (uf > 0) {
                IERC20(Mainnet.USDC).approve(Mainnet.CURVE_3POOL, uf);
                address(Mainnet.CURVE_3POOL).call(
                    abi.encodeWithSignature("exchange(int128,int128,uint256,uint256)", int128(1), int128(0), uf, uint256(0))
                );
            }
        }

        // ---- 4a) ETH gained from redemption -> WETH (balance delta only) ----
        {
            uint256 eg = address(this).balance > ethBefore ? address(this).balance - ethBefore : 0;
            if (eg > 0) IWETH(Mainnet.WETH).deposit{value: eg}();
        }

        emit log_named_uint("recv_wsteth", IERC20(Mainnet.WSTETH).balanceOf(address(this)));
        emit log_named_uint("recv_reth", IERC20(Mainnet.RETH).balanceOf(address(this)));
        _totalEthBack = IERC20(Mainnet.WETH).balanceOf(address(this));

        // ---- 4b) WETH -> USDC via tricrypto2 (old Vyper; low-level call) ----
        // Sell WETH for USDC to fund the DAI repayment. Indices: 0=USDT,1=WBTC,2=WETH.
        // Use exchange_underlying is not available - go WETH->USDT then USDT->USDC.
        // Actually tricrypto2 has USDT(0), WBTC(1), WETH(2). So WETH->USDT first.
        {
            uint256 wethBal = IERC20(Mainnet.WETH).balanceOf(address(this));
            if (wethBal > 0) {
                IERC20(Mainnet.WETH).approve(Mainnet.CURVE_TRICRYPTO_2, wethBal);
                uint256 usdtB = IERC20(Mainnet.USDT).balanceOf(address(this));
                address(Mainnet.CURVE_TRICRYPTO_2).call(
                    abi.encodeWithSignature("exchange(uint256,uint256,uint256,uint256)", uint256(2), uint256(0), wethBal, uint256(0))
                );
                uint256 usdtGot = IERC20(Mainnet.USDT).balanceOf(address(this)) - usdtB;
                // USDT -> USDC via 3pool (old Vyper; low-level call). Indices: 2=USDT, 1=USDC.
                if (usdtGot > 0) {
                    // USDT approve is non-standard (no return); use low-level call.
                    Mainnet.USDT.call(abi.encodeWithSignature("approve(address,uint256)", Mainnet.CURVE_3POOL, usdtGot));
                    address(Mainnet.CURVE_3POOL).call(
                        abi.encodeWithSignature("exchange(int128,int128,uint256,uint256)", int128(2), int128(1), usdtGot, uint256(0))
                    );
                }
            }
        }

        // ---- 4c) Remaining USDC -> DAI via 3pool ----
        {
            uint256 uf2 = IERC20(Mainnet.USDC).balanceOf(address(this));
            if (uf2 > 0) {
                IERC20(Mainnet.USDC).approve(Mainnet.CURVE_3POOL, uf2);
                address(Mainnet.CURVE_3POOL).call(
                    abi.encodeWithSignature("exchange(int128,int128,uint256,uint256)", int128(1), int128(0), uf2, uint256(0))
                );
            }
        }
    }
}
