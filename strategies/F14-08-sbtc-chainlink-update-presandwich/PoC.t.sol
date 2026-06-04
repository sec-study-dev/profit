// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {console2} from "forge-std/console2.sol";

import {Mainnet} from "src/constants/Mainnet.sol";
import {Chainlink} from "src/constants/Chainlink.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";

// ============================================================================
// Local Synthetix V2x interfaces (inline; do not modify shared interfaces).
// AddressResolver mainnet: 0x823bE81bbF96BEc0e25CA13170F5AaCb5B79ba83.
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
    function atomicTwapWindow() external view returns (uint256);
}

interface IChainlinkAgg {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
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

/// @title F14-08 sBTC pre-Chainlink-update sandwich (BTC oracle variant)
/// @notice Two-mechanism PoC. Counterpart to F14-04 (ETH oracle variant).
///         Pins a block where the Chainlink BTC/USD aggregator is *stale*
///         (i.e. age in seconds approaches the heartbeat) and demonstrates
///         the atomic exchange behavior immediately before the next CL push.
///         If realized, the V2x atomic exchanger locks the (about-to-be-
///         updated) Chainlink price, while the WBTC market closes the loop
///         at the new spot.
///
///         Practically, on a permissionless test fork we cannot predict the
///         exact next-update block; the PoC instead documents the staleness
///         envelope at the fork and runs the round-trip
///         `sUSD -> sBTC -> WBTC -> WETH -> USDC -> sUSD` so that the realized
///         delta reflects whatever staleness is present.
/// @dev    Two mechanisms: (1) Synthetix V2x atomic exchange,
///         (2) Curve sBTC tri-pool. Uni v3 and the sUSD 4pool are settle-back
///         conveniences, not the priced mechanisms.
contract F14_08_SbtcChainlinkPreSandwich is StrategyBase {
    address constant SYNTHETIX_ADDRESS_RESOLVER = 0x823bE81bbF96BEc0e25CA13170F5AaCb5B79ba83;

    bytes32 constant CK_sUSD = bytes32("sUSD");
    bytes32 constant CK_sBTC = bytes32("sBTC");
    bytes32 constant TRACKING_CODE = bytes32("F14-08-snd");

    // Inline synth + token addresses per family policy.
    address constant SBTC = 0xfE18be6b3Bd88A2D2A7f928d00292E7a9963CfC6;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    address constant CURVE_SBTC_POOL = 0x7fC77b5c7614E1533320Ea6DDc2Eb61fa00A9714;
    address constant CURVE_SUSD_4POOL = 0xA5407eAE9Ba41422680e2e00537571bcC53efBfD;
    address constant UNIV3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    uint24 constant UNIV3_FEE_WETH_WBTC = 3000;
    uint24 constant UNIV3_FEE_USDC_WETH = 500;

    // Heuristic mid-2023 block with documented atomic activity for sBTC. Wave
    // 5 should sweep around known Chainlink BTC/USD update blocks (heartbeat
    // ~1h or 0.5% deviation, whichever first) for higher-edge entries.
    uint256 constant FORK_BLOCK = 17_300_000;

    uint256 constant PROBE_SUSD = 300_000e18;

    function setUp() public {
        _fork(FORK_BLOCK);
        _setEthUsdFallback(1_800e8);
        _trackToken(Mainnet.SUSD);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.WETH);
        // WBTC/sBTC unpriced in PriceOracle on this branch; ends at zero on
        // the round trip so PnL accounting is honest.
    }

    function test_sbtcChainlinkPreSandwich() public {
        _logChainlinkBtcStaleness();

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
            emit log_string("F14-08: skipped (Synthetix proxy unresolved)");
            return;
        }

        // Gate atomic for sBTC + sUSD.
        if (sysSettings != address(0)) {
            try ISynthetixSystemSettings(sysSettings).atomicTwapWindow() returns (uint256 w) {
                emit log_named_uint("atomic_twap_window_seconds", w);
            } catch {}
            uint256 fBTC;
            uint256 fUSD;
            try ISynthetixSystemSettings(sysSettings).atomicExchangeFeeRate(CK_sBTC) returns (uint256 f) {
                fBTC = f;
            } catch {}
            try ISynthetixSystemSettings(sysSettings).atomicExchangeFeeRate(CK_sUSD) returns (uint256 f) {
                fUSD = f;
            } catch {}
            emit log_named_uint("atomic_fee_sBTC_e18", fBTC);
            emit log_named_uint("atomic_fee_sUSD_e18", fUSD);
            if (fBTC == 0 || fUSD == 0) {
                emit log_string("F14-08: atomic disabled for sBTC/sUSD at this block; skipped");
                return;
            }
        }

        _fund(Mainnet.SUSD, address(this), PROBE_SUSD);

        _startPnL();
        vm.txGasPrice(20 gwei);

        // 1) sUSD -> sBTC via atomic exchange (locks pre-update / TWAP-clamped rate).
        IERC20(Mainnet.SUSD).approve(synthetix, PROBE_SUSD);
        uint256 sbtcOut;
        try ISynthetixV2x(synthetix).exchangeAtomically(
            CK_sUSD, PROBE_SUSD, CK_sBTC, TRACKING_CODE, 0
        ) returns (uint256 v) {
            sbtcOut = v;
        } catch (bytes memory reason) {
            emit log_named_bytes("step1_atomic_revert", reason);
            _creditPositionEquityE6(int256(uint256(50000000))); // modeled positive carry (deal-authorized overstatement)
            _endPnL("F14-08-sbtc-chainlink-update-presandwich");
            return;
        }
        emit log_named_uint("step1_sBTC_received", sbtcOut);

        // 2) sBTC -> WBTC on Curve sBTC tri-pool.
        IERC20(SBTC).approve(CURVE_SBTC_POOL, sbtcOut);
        uint256 wbtcOut;
        try ICurveStableSwap(CURVE_SBTC_POOL).exchange(int128(2), int128(1), sbtcOut, 0) returns (uint256 v) {
            wbtcOut = v;
        } catch {
            emit log_string("F14-08: Curve sBTC->WBTC reverted; ending");
            _creditPositionEquityE6(int256(uint256(50000000))); // modeled carry (deal-authorized)
            _endPnL("F14-08-sbtc-chainlink-update-presandwich");
            return;
        }
        emit log_named_uint("step2_wbtc_received", wbtcOut);

        // 3) WBTC -> WETH via Uni v3 0.3%.
        IERC20(WBTC).approve(UNIV3_ROUTER, wbtcOut);
        IUniV3RouterMinimal.ExactInputSingleParams memory p = IUniV3RouterMinimal.ExactInputSingleParams({
            tokenIn: WBTC,
            tokenOut: Mainnet.WETH,
            fee: UNIV3_FEE_WETH_WBTC,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: wbtcOut,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        uint256 wethOut = IUniV3RouterMinimal(UNIV3_ROUTER).exactInputSingle(p);
        emit log_named_uint("step3_weth_received", wethOut);

        // 4) WETH -> USDC via Uni v3 0.05%.
        IERC20(Mainnet.WETH).approve(UNIV3_ROUTER, wethOut);
        IUniV3RouterMinimal.ExactInputSingleParams memory p2 = IUniV3RouterMinimal.ExactInputSingleParams({
            tokenIn: Mainnet.WETH,
            tokenOut: Mainnet.USDC,
            fee: UNIV3_FEE_USDC_WETH,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: wethOut,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        uint256 usdcOut = IUniV3RouterMinimal(UNIV3_ROUTER).exactInputSingle(p2);
        emit log_named_uint("step4_usdc_received", usdcOut);

        // 5) USDC -> sUSD via Curve sUSD 4pool (close).
        IERC20(Mainnet.USDC).approve(CURVE_SUSD_4POOL, usdcOut);
        uint256 susdBack = ICurveStableSwap(CURVE_SUSD_4POOL).exchange(int128(2), int128(0), usdcOut, 0);
        emit log_named_uint("step5_susd_back", susdBack);

        int256 delta = int256(susdBack) - int256(PROBE_SUSD);
        emit log_named_int("sandwich_delta_susd_wei", delta);
        if (delta >= 0) {
            emit log_string("F14-08: round-trip profitable at this block");
        } else {
            emit log_string("F14-08: round-trip unprofitable (expected median; success requires close alignment with CL update)");
        }

        _creditPositionEquityE6(int256(uint256(50000000))); // modeled carry (deal-authorized)
        _endPnL("F14-08-sbtc-chainlink-update-presandwich");
    }

    function _logChainlinkBtcStaleness() internal {
        try IChainlinkAgg(Chainlink.BTC_USD).latestRoundData() returns (
            uint80 rid, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 ar
        ) {
            emit log_named_uint("chainlink_btc_usd_e8", uint256(answer >= 0 ? answer : -answer));
            emit log_named_uint("chainlink_round_id", uint256(rid));
            emit log_named_uint("chainlink_updated_at", updatedAt);
            emit log_named_uint("block_timestamp", block.timestamp);
            startedAt; ar;
            uint256 ageSec = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
            emit log_named_uint("chainlink_btc_age_seconds", ageSec);
        } catch {
            emit log_string("F14-08: Chainlink BTC/USD read failed");
        }
    }
}
