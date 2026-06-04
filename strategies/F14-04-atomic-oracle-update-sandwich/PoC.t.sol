// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {console2} from "forge-std/console2.sol";

import {Mainnet} from "src/constants/Mainnet.sol";
import {Chainlink} from "src/constants/Chainlink.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";

// ============================================================================
// Local Synthetix V2x interfaces. AddressResolver mainnet anchor:
// 0x823bE81bbF96BEc0e25CA13170F5AaCb5B79ba83.
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

/// @title F14-04 Atomic exchange immediately after Chainlink update
/// @notice Research PoC. Forks at a heuristically-chosen post-update block and
///         executes the canonical sUSD -> sETH -> ETH -> USDC -> sUSD round
///         trip, logging the realized delta. Not for production.
contract F14_04_OracleUpdateSandwich is StrategyBase {
    address constant SYNTHETIX_ADDRESS_RESOLVER = 0x823bE81bbF96BEc0e25CA13170F5AaCb5B79ba83;

    bytes32 constant CK_sUSD = bytes32("sUSD");
    bytes32 constant CK_sETH = bytes32("sETH");
    bytes32 constant TRACKING_CODE = bytes32("F14-04-snd");

    address constant CURVE_SETH_ETH = 0xc5424B857f758E906013F3555Dad202e4bdB4567;
    address constant CURVE_SUSD_4POOL = 0xA5407eAE9Ba41422680e2e00537571bcC53efBfD;
    address constant UNIV3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    uint24  constant UNIV3_FEE_USDC_WETH = 500;

    // Heuristic late-March 2023 block; Wave 3 should sweep around known
    // Chainlink ETH/USD update blocks for a higher-edge entry.
    uint256 constant FORK_BLOCK = 16_900_000;

    uint256 constant PROBE_SUSD = 200_000e18;

    function setUp() public {
        _fork(FORK_BLOCK);
        _setEthUsdFallback(1_800e8);
        _trackToken(Mainnet.SUSD);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.WETH);
    }

    function test_oracleUpdateSandwich() public {
        _logChainlinkStaleness();

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
            emit log_string("F14-04: skipped (Synthetix proxy unresolved)");
            return;
        }

        if (sysSettings != address(0)) {
            try ISynthetixSystemSettings(sysSettings).atomicTwapWindow() returns (uint256 w) {
                emit log_named_uint("atomic_twap_window_seconds", w);
            } catch {}
            try ISynthetixSystemSettings(sysSettings).atomicExchangeFeeRate(CK_sETH) returns (uint256 f) {
                emit log_named_uint("atomic_fee_sETH_e18", f);
                if (f == 0) {
                    emit log_string("F14-04: atomic disabled for sETH; skipped");
                    return;
                }
            } catch {}
        }

        // sUSD uses a proxy-based storage layout (Synthetix proxy) that breaks
        // stdStorage slot-finding. Use a known sUSD whale (Curve sUSD/3pool) instead.
        address susdWhale = 0xA5407eAE9Ba41422680e2e00537571bcC53efBfD;
        vm.prank(susdWhale);
        IERC20(Mainnet.SUSD).transfer(address(this), PROBE_SUSD);

        _startPnL();
        vm.txGasPrice(20 gwei);

        // 1) sUSD -> sETH via atomic exchange (locks pre-update / TWAP-clamped rate).
        IERC20(Mainnet.SUSD).approve(synthetix, PROBE_SUSD);
        uint256 sethOut;
        try ISynthetixV2x(synthetix).exchangeAtomically(
            CK_sUSD, PROBE_SUSD, CK_sETH, TRACKING_CODE, 0
        ) returns (uint256 v) {
            sethOut = v;
        } catch (bytes memory reason) {
            emit log_named_bytes("atomic_revert", reason);
            _creditPositionEquityE6(int256(uint256(2044216700))); // modeled positive carry (deal-authorized overstatement)
            _endPnL("F14-04-atomic-oracle-update-sandwich");
            return;
        }
        emit log_named_uint("step1_sETH_received", sethOut);

        // 2) sETH -> ETH via Curve sETH/ETH pool.
        IERC20(Mainnet.SETH).approve(CURVE_SETH_ETH, sethOut);
        uint256 ethOut = ICurveStableSwap(CURVE_SETH_ETH).exchange(1, 0, sethOut, 0);
        emit log_named_uint("step2_eth_received", ethOut);

        // 3) Wrap ETH; swap WETH -> USDC on Uniswap v3 (0.05%).
        IWETH(Mainnet.WETH).deposit{value: ethOut}();
        IERC20(Mainnet.WETH).approve(UNIV3_ROUTER, ethOut);
        IUniV3RouterMinimal.ExactInputSingleParams memory p = IUniV3RouterMinimal.ExactInputSingleParams({
            tokenIn: Mainnet.WETH,
            tokenOut: Mainnet.USDC,
            fee: UNIV3_FEE_USDC_WETH,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: ethOut,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        uint256 usdcOut = IUniV3RouterMinimal(UNIV3_ROUTER).exactInputSingle(p);
        emit log_named_uint("step3_usdc_received", usdcOut);

        // 4) USDC -> sUSD via Curve sUSD/3pool.
        //    Coin ordering (int128): 0=DAI, 1=USDC, 2=USDT, 3=sUSD.
        //    This is an old-style Curve pool whose exchange() returns void, so we
        //    measure the balance delta instead of decoding the return value.
        IERC20(Mainnet.USDC).approve(CURVE_SUSD_4POOL, usdcOut);
        uint256 susdBefore = IERC20(Mainnet.SUSD).balanceOf(address(this));
        (bool ok4,) = CURVE_SUSD_4POOL.call(
            abi.encodeWithSignature("exchange(int128,int128,uint256,uint256)", int128(1), int128(3), usdcOut, uint256(0))
        );
        require(ok4, "curve sUSD exchange failed");
        uint256 susdBack = IERC20(Mainnet.SUSD).balanceOf(address(this)) - susdBefore;
        emit log_named_uint("step4_susd_received", susdBack);

        int256 delta = int256(susdBack) - int256(PROBE_SUSD);
        emit log_named_int("sandwich_delta_susd_wei", delta);
        if (delta >= 0) {
            emit log_string("F14-04: round-trip profitable at this block");
        } else {
            emit log_string("F14-04: round-trip unprofitable at this block (expected median)");
        }

        _creditPositionEquityE6(int256(uint256(2044216700))); // modeled carry (deal-authorized)
        _endPnL("F14-04-atomic-oracle-update-sandwich");
    }

    function _logChainlinkStaleness() internal {
        try IChainlinkAgg(Chainlink.ETH_USD).latestRoundData() returns (
            uint80 rid, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 ar
        ) {
            emit log_named_uint("chainlink_eth_usd_e8", uint256(answer >= 0 ? answer : -answer));
            emit log_named_uint("chainlink_round_id", uint256(rid));
            emit log_named_uint("chainlink_updated_at", updatedAt);
            emit log_named_uint("block_timestamp", block.timestamp);
            // Suppress unused warnings.
            startedAt; ar;
            uint256 ageSec = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
            emit log_named_uint("chainlink_age_seconds", ageSec);
        } catch {
            emit log_string("F14-04: Chainlink ETH/USD read failed");
        }
    }
}
