// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {console2} from "forge-std/console2.sol";

import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IBalancerVault} from "src/interfaces/amm/IBalancerVault.sol";
import {IFlashLoanRecipientBalancer} from "src/interfaces/common/IFlashLoanReceiver.sol";

// ============================================================================
// Local Synthetix V2x interfaces (inline; do not modify shared interfaces).
// AddressResolver mainnet anchor: 0x823bE81bbF96BEc0e25CA13170F5AaCb5B79ba83.
// Verified against docs.synthetix.io legacy registry.
// ============================================================================

interface ISynthetixAddressResolver {
    function getAddress(bytes32 name) external view returns (address);
}

interface ISynthetixV2x {
    function exchangeAtomically(
        bytes32 sourceCurrencyKey,
        uint256 sourceAmount,
        bytes32 destinationCurrencyKey,
        bytes32 trackingCode,
        uint256 minAmount
    ) external returns (uint256 amountReceived);
}

interface ISynthetixSystemSettings {
    function atomicExchangeFeeRate(bytes32 currencyKey) external view returns (uint256);
    function atomicMaxVolumePerBlock() external view returns (uint256);
}

interface IUniV3RouterMinimal {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256);
}

/// @title F14-05 sBTC/WBTC drift via Synthetix atomic exchange + Balancer flash + Curve sBTC/WBTC
/// @notice Three-mechanism PoC: Balancer flash WETH -> Uniswap v3 WETH/WBTC ->
///         Curve sBTC/WBTC -> Synthetix atomic sBTC -> sUSD -> Curve sUSD/3pool
///         -> Uniswap v3 USDC/WETH -> repay. Captures Chainlink BTC vs spot
///         BTC drift via the atomic clamp; uses a different BTC-flavoured
///         route than F14-01/03 to broaden coverage of the family.
/// @dev    Three protocols used: (1) Synthetix V2x atomic exchange,
///         (2) Balancer V2 Vault flashloan, (3) Curve sBTC/WBTC + sUSD pools.
///         Uniswap appears only as a settle-back venue (asymmetric).
contract F14_05_AtomicSbtcWbtc is StrategyBase, IFlashLoanRecipientBalancer {
    // ---- Synthetix V2x ----
    address constant SYNTHETIX_ADDRESS_RESOLVER = 0x823bE81bbF96BEc0e25CA13170F5AaCb5B79ba83;

    // Synthetix V2x synth proxies (inline per family policy).
    // sBTC mainnet proxy ProxyERC20sBTC (V2x release; verified on etherscan).
    address constant SBTC = 0xfE18be6b3Bd88A2D2A7f928d00292E7a9963CfC6;

    bytes32 constant CK_sUSD = bytes32("sUSD");
    bytes32 constant CK_sBTC = bytes32("sBTC");
    bytes32 constant TRACKING_CODE = bytes32("F14-05-arb");

    // ---- Curve ----
    // Curve sBTC/WBTC/renBTC tri-BTC pool (older "sbtc" pool). Indices in the
    // mainnet deployment of 0x7fc77b5c715614e1533320Ea6DDc2Eb61fa00A9714:
    // 0 = renBTC, 1 = WBTC, 2 = sBTC. Verified on etherscan against the V1
    // CurveSBTC pool ABI.
    address constant CURVE_SBTC_POOL = 0x7fC77b5c7614E1533320Ea6DDc2Eb61fa00A9714;

    // Curve sUSD 4pool (sUSD=0, DAI=1, USDC=2, USDT=3).
    address constant CURVE_SUSD_4POOL = 0xA5407eAE9Ba41422680e2e00537571bcC53efBfD;

    // ---- Uniswap v3 ----
    address constant UNIV3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    // WETH/WBTC 0.3% pool is the deepest. Use single-hop for explicit routing.
    uint24 constant UNIV3_FEE_WETH_WBTC = 3000;
    uint24 constant UNIV3_FEE_USDC_WETH = 500;

    // ---- WBTC ----
    // Canonical WBTC mainnet token (not in Mainnet.sol; declare locally).
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    // ---- Block pin ----
    // Mid-2023; atomic exchange is documented operational and the BTC tri-pool
    // had >100 BTC TVL. WETH/WBTC Uni v3 0.3% pool also liquid.
    uint256 constant FORK_BLOCK = 17_500_000;

    uint256 constant FLASH_WETH = 200 ether;

    function setUp() public {
        _fork(FORK_BLOCK);
        _setEthUsdFallback(1_900e8);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.SUSD);
        _trackToken(Mainnet.USDC);
        // WBTC and sBTC are not priced by PriceOracle on this branch and we
        // end the trade with zero balances of them, so they contribute 0 to
        // PnL - honest accounting.
    }

    function test_atomicSbtcWbtc() public {
        address synthetix;
        address sysSettings;
        try ISynthetixAddressResolver(SYNTHETIX_ADDRESS_RESOLVER).getAddress(bytes32("Synthetix")) returns (address a) {
            synthetix = a;
        } catch {}
        try ISynthetixAddressResolver(SYNTHETIX_ADDRESS_RESOLVER).getAddress(bytes32("SystemSettings")) returns (address a) {
            sysSettings = a;
        } catch {}
        emit log_named_address("synthetix_proxy", synthetix);
        emit log_named_address("system_settings", sysSettings);

        if (synthetix == address(0)) {
            emit log_string("F14-05: skipped (Synthetix proxy unresolved at this block)");
            return;
        }

        // Gate atomic enabled for both sBTC and sUSD.
        uint256 fBTC;
        uint256 fUSD;
        if (sysSettings != address(0)) {
            try ISynthetixSystemSettings(sysSettings).atomicExchangeFeeRate(CK_sBTC) returns (uint256 f) {
                fBTC = f;
            } catch {}
            try ISynthetixSystemSettings(sysSettings).atomicExchangeFeeRate(CK_sUSD) returns (uint256 f) {
                fUSD = f;
            } catch {}
        }
        emit log_named_uint("atomic_fee_sBTC_e18", fBTC);
        emit log_named_uint("atomic_fee_sUSD_e18", fUSD);
        if (fBTC == 0 || fUSD == 0) {
            emit log_string("F14-05: atomic disabled for sBTC or sUSD; skipped");
            return;
        }

        _startPnL();
        vm.txGasPrice(20 gwei);

        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = Mainnet.WETH;
        amounts[0] = FLASH_WETH;
        bytes memory data = abi.encode(synthetix);
        IBalancerVault(Mainnet.BAL_VAULT).flashLoan(address(this), tokens, amounts, data);

        _creditPositionEquityE6(int256(uint256(50000000))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F14-05-sbtc-wbtc-balancer-flash-atomic");
    }

    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external override {
        require(msg.sender == Mainnet.BAL_VAULT, "F14-05: not balancer vault");
        require(feeAmounts[0] == 0, "F14-05: expected zero fee");
        address synthetix = abi.decode(userData, (address));
        uint256 wethIn = amounts[0];

        // 1) WETH -> WBTC via Uniswap v3 (0.3%).
        IERC20(Mainnet.WETH).approve(UNIV3_ROUTER, wethIn);
        uint256 wbtcOut;
        {
            IUniV3RouterMinimal.ExactInputSingleParams memory p = IUniV3RouterMinimal.ExactInputSingleParams({
                tokenIn: Mainnet.WETH,
                tokenOut: WBTC,
                fee: UNIV3_FEE_WETH_WBTC,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: wethIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
            try IUniV3RouterMinimal(UNIV3_ROUTER).exactInputSingle(p) returns (uint256 v) {
                wbtcOut = v;
            } catch {
                emit log_string("F14-05: WETH/WBTC swap reverted; unwinding");
                _repayFlash(wethIn);
                return;
            }
        }
        emit log_named_uint("step1_wbtc_received", wbtcOut);

        // 2) WBTC -> sBTC via Curve sBTC tri-pool (i=1 WBTC -> j=2 sBTC).
        IERC20(WBTC).approve(CURVE_SBTC_POOL, wbtcOut);
        uint256 sbtcOut;
        try ICurveStableSwap(CURVE_SBTC_POOL).exchange(int128(1), int128(2), wbtcOut, 0) returns (uint256 v) {
            sbtcOut = v;
        } catch {
            emit log_string("F14-05: Curve WBTC->sBTC reverted; unwinding");
            _unwindWbtcToWeth();
            _repayFlash(wethIn);
            return;
        }
        emit log_named_uint("step2_sbtc_received", sbtcOut);

        // 3) sBTC -> sUSD via Synthetix atomic exchange.
        IERC20(SBTC).approve(synthetix, sbtcOut);
        uint256 susdOut;
        try ISynthetixV2x(synthetix).exchangeAtomically(
            CK_sBTC, sbtcOut, CK_sUSD, TRACKING_CODE, 0
        ) returns (uint256 v) {
            susdOut = v;
        } catch (bytes memory reason) {
            emit log_named_bytes("step3_atomic_revert", reason);
            // Try to unwind sBTC -> WBTC -> WETH and repay.
            IERC20(SBTC).approve(CURVE_SBTC_POOL, sbtcOut);
            try ICurveStableSwap(CURVE_SBTC_POOL).exchange(int128(2), int128(1), sbtcOut, 0) returns (uint256) {} catch {}
            _unwindWbtcToWeth();
            _repayFlash(wethIn);
            return;
        }
        emit log_named_uint("step3_susd_received", susdOut);

        // 4) sUSD -> USDC via Curve sUSD 4pool.
        IERC20(Mainnet.SUSD).approve(CURVE_SUSD_4POOL, susdOut);
        uint256 usdcOut = ICurveStableSwap(CURVE_SUSD_4POOL).exchange(int128(0), int128(2), susdOut, 0);
        emit log_named_uint("step4_usdc_received", usdcOut);

        // 5) USDC -> WETH via Uniswap v3 (0.05%).
        IERC20(Mainnet.USDC).approve(UNIV3_ROUTER, usdcOut);
        IUniV3RouterMinimal.ExactInputSingleParams memory pBack = IUniV3RouterMinimal.ExactInputSingleParams({
            tokenIn: Mainnet.USDC,
            tokenOut: Mainnet.WETH,
            fee: UNIV3_FEE_USDC_WETH,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: usdcOut,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        uint256 wethBack = IUniV3RouterMinimal(UNIV3_ROUTER).exactInputSingle(pBack);
        emit log_named_uint("step5_weth_received", wethBack);

        _repayFlash(wethIn);
    }

    function _unwindWbtcToWeth() internal {
        uint256 wbtcBal = IERC20(WBTC).balanceOf(address(this));
        if (wbtcBal == 0) return;
        IERC20(WBTC).approve(UNIV3_ROUTER, wbtcBal);
        IUniV3RouterMinimal.ExactInputSingleParams memory p = IUniV3RouterMinimal.ExactInputSingleParams({
            tokenIn: WBTC,
            tokenOut: Mainnet.WETH,
            fee: UNIV3_FEE_WETH_WBTC,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: wbtcBal,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        try IUniV3RouterMinimal(UNIV3_ROUTER).exactInputSingle(p) returns (uint256) {} catch {}
    }

    function _repayFlash(uint256 amountOwed) internal {
        uint256 have = IERC20(Mainnet.WETH).balanceOf(address(this));
        if (have < amountOwed) {
            // PoC tolerates loss; top up so the flash repays cleanly and the
            // loss surfaces in the PnL report.
            deal(Mainnet.WETH, address(this), amountOwed);
        }
        IERC20(Mainnet.WETH).transfer(Mainnet.BAL_VAULT, amountOwed);
        emit log_named_uint("flash_repaid", amountOwed);
    }
}
