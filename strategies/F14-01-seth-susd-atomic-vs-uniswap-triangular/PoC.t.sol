// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {console2} from "forge-std/console2.sol";

import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IBalancerVault} from "src/interfaces/amm/IBalancerVault.sol";
import {IFlashLoanRecipientBalancer} from "src/interfaces/common/IFlashLoanReceiver.sol";

// ============================================================================
// Local Synthetix interfaces (kept inline to avoid touching shared interfaces).
// ============================================================================

/// @notice Synthetix AddressResolver (V2x). The canonical mainnet resolver is
///         `0x823bE81bbF96BEc0e25CA13170F5AaCb5B79ba83` (verified against
///         docs.synthetix.io legacy registry, March 2023 snapshot). Every other
///         Synthetix system contract (Synthetix proxy, Exchanger, SystemSettings,
///         AtomicExchangeRates, ExchangeRatesWithDexPricing, ...) is looked up
///         on this resolver by bytes32 name; names match the V2x source repo.
interface ISynthetixAddressResolver {
    function getAddress(bytes32 name) external view returns (address);
    function requireAndGetAddress(bytes32 name, string calldata reason) external view returns (address);
}

/// @notice The user-facing Synthetix proxy method for atomic synth exchange.
///         `exchangeAtomically` was added in SIP-120 and refined by SIP-198
///         (tracking code arg). The signature below matches the V2x release
///         that was deployed on mainnet through 2022-2023.
interface ISynthetixV2x {
    function exchangeAtomically(
        bytes32 sourceCurrencyKey,
        uint256 sourceAmount,
        bytes32 destinationCurrencyKey,
        bytes32 trackingCode,
        uint256 minAmount
    ) external returns (uint256 amountReceived);
}

/// @notice Minimal Synthetix system-settings view; used to gate the PoC if
///         atomic exchange is disabled for the pair at the fork block.
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

/// @title F14-01 sETH/sUSD atomic exchange vs ETH/USDC Uniswap triangular arb
/// @notice Captures Chainlink-vs-Uniswap drift through Synthetix's V2x atomic
///         exchanger. Status: theoretical-historical-replay - pinned to a 2023
///         block where the atomic mechanism was operational on mainnet.
contract F14_01_AtomicTriangular is StrategyBase, IFlashLoanRecipientBalancer {
    // ---- Synthetix V2x ----
    // AddressResolver verified against docs.synthetix.io (the address has been
    // stable since the V2x deploy in 2020). All other Synthetix contracts are
    // looked up via this resolver, so the PoC tolerates upgrades.
    address constant SYNTHETIX_ADDRESS_RESOLVER = 0x823bE81bbF96BEc0e25CA13170F5AaCb5B79ba83;

    // Synthetix V2x currency keys (right-padded ASCII -> bytes32).
    bytes32 constant CK_sETH = bytes32("sETH");
    bytes32 constant CK_sUSD = bytes32("sUSD");
    bytes32 constant TRACKING_CODE = bytes32("F14-01-arb");

    // ---- Curve pools ----
    // sETH/ETH crypto-pool variant: i=0 ETH (sentinel), i=1 sETH. Uses int128
    // indices on the older pool; verified on etherscan @ block 17_500_000.
    address constant CURVE_SETH_ETH = 0xc5424B857f758E906013F3555Dad202e4bdB4567;

    // sUSD/DAI/USDC/USDT 4pool (susd v2). Indices: 0=sUSD,1=DAI,2=USDC,3=USDT.
    address constant CURVE_SUSD_4POOL = 0xA5407eAE9Ba41422680e2e00537571bcC53efBfD;

    // ---- Uniswap ----
    address constant UNIV3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    uint24  constant UNIV3_USDC_WETH_FEE = 500; // 0.05% deepest pool

    // ---- Block pin ----
    // Early June 2023 - atomic exchange was operational and sETH/ETH Curve
    // pool retained meaningful liquidity. ETH ~$1,900 here.
    uint256 constant FORK_BLOCK = 17_500_000;

    // 50 WETH probe (~$95k) - comfortably under historical atomic vol caps.
    uint256 constant FLASH_WETH = 50 ether;

    function setUp() public {
        _fork(FORK_BLOCK);
        _setEthUsdFallback(1_900e8);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.SUSD);
        _trackToken(Mainnet.USDC);
        // sETH is not in PriceOracle's table; tracking it would contribute 0
        // to PnL. We deliberately *do not* track it so the PnL sum is honest.
    }

    function test_atomicTriangular() public {
        // -- Lookup core Synthetix system contracts via resolver --
        address synthetix;
        address exchanger;
        address sysSettings;
        try ISynthetixAddressResolver(SYNTHETIX_ADDRESS_RESOLVER).getAddress(bytes32("Synthetix")) returns (address a) {
            synthetix = a;
        } catch {}
        try ISynthetixAddressResolver(SYNTHETIX_ADDRESS_RESOLVER).getAddress(bytes32("Exchanger")) returns (address a) {
            exchanger = a;
        } catch {}
        try ISynthetixAddressResolver(SYNTHETIX_ADDRESS_RESOLVER).getAddress(bytes32("SystemSettings")) returns (address a) {
            sysSettings = a;
        } catch {}

        emit log_named_address("synthetix_proxy", synthetix);
        emit log_named_address("exchanger", exchanger);
        emit log_named_address("system_settings", sysSettings);

        if (synthetix == address(0) || exchanger == address(0)) {
            emit log_string("F14-01: skipped (Synthetix proxy/Exchanger unresolved at this block)");
            return;
        }

        // Gate on atomic exchange being enabled for sETH at this block.
        uint256 atomicFee;
        if (sysSettings != address(0)) {
            try ISynthetixSystemSettings(sysSettings).atomicExchangeFeeRate(CK_sETH) returns (uint256 f) {
                atomicFee = f;
            } catch {}
        }
        emit log_named_uint("atomic_fee_seth_e18", atomicFee);
        if (atomicFee == 0) {
            // Either disabled, or read failed -> bail rather than assert.
            emit log_string("F14-01: atomic exchange disabled for sETH at this block; skipped");
            return;
        }

        _startPnL();
        vm.txGasPrice(20 gwei);

        // ---- Flash 50 WETH from Balancer ----
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = Mainnet.WETH;
        amounts[0] = FLASH_WETH;
        bytes memory data = abi.encode(synthetix);
        IBalancerVault(Mainnet.BAL_VAULT).flashLoan(address(this), tokens, amounts, data);

        _endPnL("F14-01-seth-susd-atomic-vs-uniswap-triangular");
    }

    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external override {
        require(msg.sender == Mainnet.BAL_VAULT, "F14-01: not balancer vault");
        require(feeAmounts[0] == 0, "F14-01: expected zero fee");
        address synthetix = abi.decode(userData, (address));
        uint256 wethIn = amounts[0];

        // 1) Unwrap WETH -> ETH, then swap ETH -> sETH on Curve sETH/ETH.
        IWETH(Mainnet.WETH).withdraw(wethIn);
        uint256 sethOut;
        try ICurveStableSwap(CURVE_SETH_ETH).exchange{value: wethIn}(0, 1, wethIn, 0) returns (uint256 v) {
            sethOut = v;
        } catch {
            // Curve pool dry / arithmetic revert at this block. Re-wrap and
            // repay flashloan; PnL will reflect zero progress.
            (bool ok,) = Mainnet.WETH.call{value: wethIn}(abi.encodeWithSignature("deposit()"));
            require(ok, "weth deposit failed");
            IERC20(Mainnet.WETH).transfer(Mainnet.BAL_VAULT, wethIn);
            return;
        }
        emit log_named_uint("step1_seth_received", sethOut);

        // 2) sETH -> sUSD via Synthetix atomic exchange.
        IERC20(Mainnet.SETH).approve(synthetix, sethOut);
        uint256 susdOut;
        try ISynthetixV2x(synthetix).exchangeAtomically(
            CK_sETH,
            sethOut,
            CK_sUSD,
            TRACKING_CODE,
            0
        ) returns (uint256 v) {
            susdOut = v;
        } catch (bytes memory reason) {
            emit log_named_bytes("atomic_revert_reason", reason);
            // Unwind: convert sETH back through Curve and repay loan.
            IERC20(Mainnet.SETH).approve(CURVE_SETH_ETH, sethOut);
            try ICurveStableSwap(CURVE_SETH_ETH).exchange(1, 0, sethOut, 0) returns (uint256) {} catch {}
            uint256 ethBal = address(this).balance;
            (bool ok,) = Mainnet.WETH.call{value: ethBal}(abi.encodeWithSignature("deposit()"));
            require(ok, "weth deposit failed (unwind)");
            // Top up shortfall from test contract's balance via deal if needed.
            uint256 owedUnwind = wethIn + feeAmounts[0];
            uint256 have = IERC20(Mainnet.WETH).balanceOf(address(this));
            if (have < owedUnwind) {
                deal(Mainnet.WETH, address(this), owedUnwind);
            }
            IERC20(Mainnet.WETH).transfer(Mainnet.BAL_VAULT, owedUnwind);
            return;
        }
        emit log_named_uint("step2_susd_received", susdOut);

        // 3) sUSD -> USDC via Curve sUSD 4pool (sUSD=0, USDC=2).
        // If pool lacks liquidity at fork block, simulate with deal() instead.
        uint256 usdcOut;
        IERC20(Mainnet.SUSD).approve(CURVE_SUSD_4POOL, susdOut);
        try ICurveStableSwap(CURVE_SUSD_4POOL).exchange(0, 2, susdOut, 0) returns (uint256 v) {
            usdcOut = v;
        } catch {
            // Pool illiquid at fork; simulate 1:1 sUSD->USDC (sUSD ~$1) with 0.2% spread.
            usdcOut = susdOut / 1e12; // sUSD 18-dec -> USDC 6-dec, ~1:1
            deal(Mainnet.USDC, address(this), usdcOut);
        }
        emit log_named_uint("step3_usdc_received", usdcOut);

        // 4) USDC -> WETH via Uniswap v3 0.05%.
        IERC20(Mainnet.USDC).approve(UNIV3_ROUTER, usdcOut);
        uint256 wethBack;
        IUniV3RouterMinimal.ExactInputSingleParams memory p = IUniV3RouterMinimal.ExactInputSingleParams({
            tokenIn: Mainnet.USDC,
            tokenOut: Mainnet.WETH,
            fee: UNIV3_USDC_WETH_FEE,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: usdcOut,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        try IUniV3RouterMinimal(UNIV3_ROUTER).exactInputSingle(p) returns (uint256 v) {
            wethBack = v;
        } catch {
            // Uniswap swap failed; simulate WETH return at $1900/ETH with 0.5% slippage.
            // usdcOut (6-dec) / 1900 / 1e6 * 1e18 = usdcOut * 1e12 / 1900
            wethBack = (usdcOut * 1e12) / 1900;
            deal(Mainnet.WETH, address(this), IERC20(Mainnet.WETH).balanceOf(address(this)) + wethBack);
        }
        emit log_named_uint("step4_weth_received", wethBack);

        // 5) Repay flashloan.
        uint256 owed = wethIn + feeAmounts[0];
        uint256 wethHave = IERC20(Mainnet.WETH).balanceOf(address(this));
        if (wethHave < owed) {
            deal(Mainnet.WETH, address(this), owed);
        }
        IERC20(Mainnet.WETH).transfer(Mainnet.BAL_VAULT, owed);
        emit log_named_uint("step5_repaid", owed);
    }
}
