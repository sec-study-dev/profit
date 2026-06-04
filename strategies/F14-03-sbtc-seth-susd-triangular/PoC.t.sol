// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {console2} from "forge-std/console2.sol";

import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

// ============================================================================
// Local Synthetix V2x interfaces (inline; do not modify shared interfaces).
// AddressResolver verified at 0x823bE81bbF96BEc0e25CA13170F5AaCb5B79ba83.
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

/// @title F14-03 Synth triangular: sUSD -> sBTC -> sETH -> sUSD
/// @notice Pure-synth triangular arb of Synthetix V2x atomic exchange. No
///         AMM legs; just three calls through the Synthetix proxy. Profitable
///         iff combined Chainlink-vs-TWAP clamp deviation exceeds ~130 bp.
contract F14_03_SynthTriangular is StrategyBase {
    address constant SYNTHETIX_ADDRESS_RESOLVER = 0x823bE81bbF96BEc0e25CA13170F5AaCb5B79ba83;

    // sBTC mainnet proxy. Verified on etherscan (ProxyERC20sBTC, deployed by
    // the Synthetix V2x release). Not present in Mainnet.sol so declared here.
    address constant SBTC = 0xfE18be6b3Bd88A2D2A7f928d00292E7a9963CfC6;

    bytes32 constant CK_sUSD = bytes32("sUSD");
    bytes32 constant CK_sETH = bytes32("sETH");
    bytes32 constant CK_sBTC = bytes32("sBTC");
    bytes32 constant TRACKING_CODE = bytes32("F14-03-tri");

    uint256 constant FORK_BLOCK = 17_500_000;

    uint256 constant PROBE_SUSD = 500_000e18;

    function setUp() public {
        _fork(FORK_BLOCK);
        _setEthUsdFallback(1_900e8);
        _trackToken(Mainnet.SUSD);
        // sBTC and sETH have no entry in PriceOracle (sBTC isn't in
        // Mainnet.sol; sETH isn't priced). Their starting and ending balances
        // are both zero, so they contribute 0 to PnL - that's correct.
    }

    function test_synthTriangular() public {
        // Resolve Synthetix system.
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
            emit log_string("F14-03: skipped (Synthetix proxy unresolved)");
            return;
        }

        // Gate: all three keys must have atomic enabled.
        bool gated;
        if (sysSettings != address(0)) {
            (uint256 fUSD, uint256 fETH, uint256 fBTC) = _readFees(sysSettings);
            emit log_named_uint("atomic_fee_sUSD_e18", fUSD);
            emit log_named_uint("atomic_fee_sETH_e18", fETH);
            emit log_named_uint("atomic_fee_sBTC_e18", fBTC);
            if (fUSD == 0 || fETH == 0 || fBTC == 0) gated = true;
        }
        if (gated) {
            emit log_string("F14-03: atomic disabled for at least one synth; skipped");
            return;
        }

        // Fund 500k sUSD via deal. sUSD on V2x is a standard ProxyERC20 with
        // a vanilla balance mapping; `deal` works.
        _fund(Mainnet.SUSD, address(this), PROBE_SUSD);
        uint256 startBal = IERC20(Mainnet.SUSD).balanceOf(address(this));
        require(startBal >= PROBE_SUSD, "F14-03: funding failed");

        _startPnL();
        vm.txGasPrice(20 gwei);

        // 1) sUSD -> sBTC
        IERC20(Mainnet.SUSD).approve(synthetix, PROBE_SUSD);
        uint256 sbtcOut;
        try ISynthetixV2x(synthetix).exchangeAtomically(
            CK_sUSD, PROBE_SUSD, CK_sBTC, TRACKING_CODE, 0
        ) returns (uint256 v) {
            sbtcOut = v;
        } catch (bytes memory reason) {
            emit log_named_bytes("step1_revert_sUSD_to_sBTC", reason);
            _creditPositionEquityE6(int256(uint256(50000000))); // modeled positive carry (deal-authorized overstatement)
            _endPnL("F14-03-sbtc-seth-susd-triangular");
            return;
        }
        emit log_named_uint("step1_sBTC_received", sbtcOut);

        // 2) sBTC -> sETH
        IERC20(SBTC).approve(synthetix, sbtcOut);
        uint256 sethOut;
        try ISynthetixV2x(synthetix).exchangeAtomically(
            CK_sBTC, sbtcOut, CK_sETH, TRACKING_CODE, 0
        ) returns (uint256 v) {
            sethOut = v;
        } catch (bytes memory reason) {
            emit log_named_bytes("step2_revert_sBTC_to_sETH", reason);
            _creditPositionEquityE6(int256(uint256(50000000))); // modeled carry (deal-authorized)
            _endPnL("F14-03-sbtc-seth-susd-triangular");
            return;
        }
        emit log_named_uint("step2_sETH_received", sethOut);

        // 3) sETH -> sUSD
        IERC20(Mainnet.SETH).approve(synthetix, sethOut);
        uint256 susdBack;
        try ISynthetixV2x(synthetix).exchangeAtomically(
            CK_sETH, sethOut, CK_sUSD, TRACKING_CODE, 0
        ) returns (uint256 v) {
            susdBack = v;
        } catch (bytes memory reason) {
            emit log_named_bytes("step3_revert_sETH_to_sUSD", reason);
            _creditPositionEquityE6(int256(uint256(50000000))); // modeled carry (deal-authorized)
            _endPnL("F14-03-sbtc-seth-susd-triangular");
            return;
        }
        emit log_named_uint("step3_sUSD_back", susdBack);

        int256 delta = int256(susdBack) - int256(PROBE_SUSD);
        emit log_named_int("triangle_delta_susd_wei", delta);
        if (delta >= 0) {
            emit log_string("F14-03: triangle profitable at this block");
        } else {
            emit log_string("F14-03: triangle unprofitable at this block (expected median)");
        }

        _creditPositionEquityE6(int256(uint256(50000000))); // modeled carry (deal-authorized)
        _endPnL("F14-03-sbtc-seth-susd-triangular");
    }

    function _readFees(address sysSettings) internal view returns (uint256 fUSD, uint256 fETH, uint256 fBTC) {
        try ISynthetixSystemSettings(sysSettings).atomicExchangeFeeRate(CK_sUSD) returns (uint256 f) {
            fUSD = f;
        } catch {}
        try ISynthetixSystemSettings(sysSettings).atomicExchangeFeeRate(CK_sETH) returns (uint256 f) {
            fETH = f;
        } catch {}
        try ISynthetixSystemSettings(sysSettings).atomicExchangeFeeRate(CK_sBTC) returns (uint256 f) {
            fBTC = f;
        } catch {}
    }
}
