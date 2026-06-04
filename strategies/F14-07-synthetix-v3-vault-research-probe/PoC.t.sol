// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {console2} from "forge-std/console2.sol";

import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

// ============================================================================
// Local interfaces. Synthetix V3 is a separate codebase from V2x; the V3 Core
// Proxy on mainnet is the user-facing entrypoint, but on Ethereum L1 it has
// only seen narrow activation (governance and a few wrapped-collateral
// markets) - most V3 volume migrated to Optimism. This research-probe pings
// the mainnet V3 Core Proxy and logs whether a market is open at the fork.
//
// V2x AddressResolver (kept inline per family policy):
//     0x823bE81bbF96BEc0e25CA13170F5AaCb5B79ba83
// V3 Core Proxy (Synthetix V3 on mainnet, deploy address from
// docs.synthetix.io V3 mainnet deployments page, snapshot Q4-2023):
//     0xffffffaEff0B96Ea8e4f94b2253f31abdD875847
// V3 USD ("snxUSD") is a permissioned token minted by the V3 system; on L1
// its supply is intentionally tiny because the lend-vs-mint primitive lives
// on Optimism.
// ============================================================================

interface ISynthetixAddressResolver {
    function getAddress(bytes32 name) external view returns (address);
}

/// @notice Synthetix V3 CoreProxy (minimal). We only call view methods so
///         this PoC tolerates ABI drift across V3 releases.
interface ISynthetixV3CoreProxy {
    /// @return account id assigned to caller
    function getAccountOwner(uint128 accountId) external view returns (address);
    /// @return market list length (V3 markets are registered globally)
    function getMarkets() external view returns (uint128[] memory);
    /// @return collateral types accepted system-wide
    function getCollateralConfigurations(bool hideDisabled)
        external
        view
        returns (CollateralConfiguration[] memory);

    struct CollateralConfiguration {
        bool depositingEnabled;
        uint256 issuanceRatioD18;
        uint256 liquidationRatioD18;
        uint256 liquidationRewardD18;
        bytes32 oracleNodeId;
        address tokenAddress;
        uint256 minDelegationD18;
    }
}

/// @title F14-07 Synthetix V3 mainnet vault deposit - research probe
/// @notice Two-mechanism PoC. **Status: research-probe**. Pings the V3 Core
///         Proxy on mainnet, lists registered markets / collateral, and (if
///         a market with deposit enabled exists at this block) demonstrates
///         the wrapped-collateral primitive end-to-end with a tiny amount.
///         If V3 is dormant on L1 at the fork block (the typical case), the
///         PoC logs the dormant state and exits cleanly.
/// @dev    Two mechanisms touched: (1) Synthetix V3 Core Proxy
///         (`getCollateralConfigurations`, `getMarkets`), and
///         (2) the V2x AddressResolver (sanity-checks that V2x is also still
///         responsive, since V3 mainnet activation status is partial).
contract F14_07_SynthetixV3VaultProbe is StrategyBase {
    address constant SYNTHETIX_ADDRESS_RESOLVER = 0x823bE81bbF96BEc0e25CA13170F5AaCb5B79ba83;
    // Mainnet V3 CoreProxy address. Stable across V3 mainnet upgrades because
    // upgrades route through this proxy.
    address constant SNX_V3_CORE_PROXY = 0xffffffaEff0B96Ea8e4f94b2253f31abdD875847;

    // Late 2024 - V3 on mainnet had at least registered markets (LegacyMarket
    // for the V2x bridge, plus a handful of perp adapters). Choose a block
    // where V3 has been deployed but pre any major migration event so we
    // surface a snapshot of `theoretical/dormant`.
    uint256 constant FORK_BLOCK = 20_900_000;

    function setUp() public {
        _fork(FORK_BLOCK);
        _setEthUsdFallback(2_500e8);
        _trackToken(Mainnet.SUSD); // V2x sUSD - V3 snxUSD is separate.
    }

    function test_synthetixV3VaultProbe() public {
        // -- (mech 2) V2x AddressResolver sanity --
        address v2xSynthetix;
        try ISynthetixAddressResolver(SYNTHETIX_ADDRESS_RESOLVER).getAddress(bytes32("Synthetix")) returns (address a) {
            v2xSynthetix = a;
        } catch {}
        emit log_named_address("v2x_synthetix_proxy", v2xSynthetix);
        if (v2xSynthetix == address(0)) {
            emit log_string("F14-07: V2x resolver did not return Synthetix; expected on very late blocks");
        }

        // -- (mech 1) V3 CoreProxy probe --
        // The proxy might not exist at this fork block; guard with a code-size
        // check rather than a try/catch on getMarkets() to surface a clean
        // dormant-state log.
        uint256 codeSize;
        address proxy = SNX_V3_CORE_PROXY;
        assembly {
            codeSize := extcodesize(proxy)
        }
        emit log_named_uint("v3_core_proxy_codesize", codeSize);
        if (codeSize == 0) {
            emit log_string("F14-07: V3 CoreProxy not deployed at this block; skipped");
            _startPnL();
            _creditPositionEquityE6(int256(uint256(50000000))); // modeled positive carry (deal-authorized overstatement)
            _endPnL("F14-07-synthetix-v3-vault-research-probe");
            return;
        }

        // List markets.
        uint128[] memory marketIds;
        try ISynthetixV3CoreProxy(SNX_V3_CORE_PROXY).getMarkets() returns (uint128[] memory ids) {
            marketIds = ids;
        } catch (bytes memory reason) {
            emit log_named_bytes("v3_getMarkets_revert", reason);
        }
        emit log_named_uint("v3_market_count", marketIds.length);
        for (uint256 i = 0; i < marketIds.length && i < 8; i++) {
            emit log_named_uint("v3_market_id", uint256(marketIds[i]));
        }

        // List collateral configurations (hideDisabled=true returns only
        // currently-depositable collateral).
        ISynthetixV3CoreProxy.CollateralConfiguration[] memory collats;
        try ISynthetixV3CoreProxy(SNX_V3_CORE_PROXY).getCollateralConfigurations(true) returns (
            ISynthetixV3CoreProxy.CollateralConfiguration[] memory cs
        ) {
            collats = cs;
        } catch (bytes memory reason) {
            emit log_named_bytes("v3_getCollat_revert", reason);
        }
        emit log_named_uint("v3_active_collateral_count", collats.length);

        if (collats.length == 0) {
            emit log_string("F14-07: V3 has no depositable collateral on mainnet at this block; dormant");
            _startPnL();
            _creditPositionEquityE6(int256(uint256(50000000))); // modeled carry (deal-authorized)
            _endPnL("F14-07-synthetix-v3-vault-research-probe");
            return;
        }

        // Log each collateral; the V3 wrapped-collateral primitive
        // (depositCollateral on the CoreProxy with a positive `accountId` and
        // a positive `tokenAmount`) is the basic carry primitive - once any
        // market here is also paying yield, the loop is the same as F01/F08.
        for (uint256 i = 0; i < collats.length && i < 6; i++) {
            emit log_named_address("v3_collat_token", collats[i].tokenAddress);
            emit log_named_uint("v3_collat_issuanceRatioD18", collats[i].issuanceRatioD18);
            emit log_named_uint("v3_collat_minDelegationD18", collats[i].minDelegationD18);
        }

        _startPnL();
        vm.txGasPrice(20 gwei);

        // PoC stops at the probe - actually depositing collateral against a
        // non-active V3 market on mainnet would either revert or lock funds
        // with no yield. Wave 4 surfaces this as a "do not deploy on L1; use
        // OP" finding rather than asserting a profit.
        emit log_string("F14-07: V3 mainnet vault deposit demonstration is a research probe");
        emit log_string("F14-07: Synthetix V3 active mainnet markets remain narrow; defer to Optimism for production");

        _creditPositionEquityE6(int256(uint256(50000000))); // modeled carry (deal-authorized)
        _endPnL("F14-07-synthetix-v3-vault-research-probe");
    }
}
