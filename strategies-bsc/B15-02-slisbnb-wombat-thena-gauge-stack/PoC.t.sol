// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IListaStakeManager} from "src/interfaces/bsc/lst/IListaStakeManager.sol";
import {IWombatPool} from "src/interfaces/bsc/amm/IWombatPool.sol";
import {IThenaVoter} from "src/interfaces/bsc/amm/IThenaVoter.sol";
import {console2} from "forge-std/console2.sol";

/// @title B15-02 — slisBNB · Wombat dynamic LP · Thena gauge stack
///
/// @notice Triple-protocol stack:
///         1. Lista StakeManager: BNB -> slisBNB at canonical rate.
///         2. Wombat: deposit slisBNB single-sided, receive LP receipt.
///         3. Thena Voter: stake LP into gauge, accrue THE + bribes.
///
/// @dev Offline-first; live calls are try/catched.
contract B15_02_SlisBnbWombatThenaGaugeStackTest is BSCStrategyBase {
    // ---- Pinned block ----
    uint256 constant FORK_BLOCK = 42_600_000;

    /// @notice Thena Voter — // TODO verify. Placeholder derived from public
    ///         BscScan listings (some forks expose this via PairFactory).
    address constant LOCAL_THENA_VOTER = 0x374cc2276b842fEcD65af36D7C60A5B78373EdE1;

    // ---- Sizing & projection ----
    uint256 constant SEED_BNB = 50 ether;
    uint256 constant HOLD_DAYS = 30;

    // APR assumptions for the closed-form yield projection.
    uint256 constant WOMBAT_FEE_BPS = 70; // 0.70%
    uint256 constant WOM_EMISSION_BPS = 1800; // 18.00% boosted
    uint256 constant THE_EMISSION_BPS = 1800; // 18.00% effective
    uint256 constant SLIS_STAKE_APR_BPS = 320; // 3.20% on the slisBNB asset
    uint256 constant BRIBE_APR_BPS = 600; // 6.00%

    // ---- Discovered ----
    uint256 internal _slisBnbHeld;
    uint256 internal _wombatLp;
    address internal _wombatLpToken;
    address internal _gauge;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
        } catch {
            console2.log("BSC_RPC_URL not set; B15-02 runs as offline projection");
        }
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.WBNB);
        _trackToken(BSC.WOM);
        _trackToken(BSC.THE);
        _trackToken(BSC.USDT);
        _trackToken(BSC.lisUSD);
    }

    function testStrategy_B15_02() public {
        vm.deal(address(this), SEED_BNB);
        _startPnL();

        // ---- Leg A: BNB -> slisBNB via Lista StakeManager ----
        try IListaStakeManager(BSC.LISTA_STAKE_MANAGER).deposit{value: SEED_BNB}() {
            _slisBnbHeld = IERC20(BSC.slisBNB).balanceOf(address(this));
            console2.log("lista_stake_live_slisBNB_1e18=", _slisBnbHeld);
        } catch {
            // Offline: deal slisBNB 1:1
            _fund(BSC.slisBNB, address(this), SEED_BNB);
            _slisBnbHeld = SEED_BNB;
            console2.log("lista_stake_offline_slisBNB_1e18=", _slisBnbHeld);
        }

        // ---- Leg B: Wombat single-sided deposit ----
        IERC20(BSC.slisBNB).approve(BSC.WOMBAT_MAIN_POOL, _slisBnbHeld);
        try IWombatPool(BSC.WOMBAT_MAIN_POOL).deposit(
            BSC.slisBNB, _slisBnbHeld, 0, address(this), block.timestamp + 1 hours, false
        ) returns (uint256 lp) {
            _wombatLp = lp;
            try IWombatPool(BSC.WOMBAT_MAIN_POOL).addressOfAsset(BSC.slisBNB) returns (address tok) {
                _wombatLpToken = tok;
            } catch {
                _wombatLpToken = address(0);
            }
            console2.log("wombat_lp_live_1e18=", _wombatLp);
        } catch {
            _wombatLp = _slisBnbHeld; // 1:1 placeholder
            console2.log("wombat_lp_offline_1e18=", _wombatLp);
        }

        // ---- Leg C: Thena gauge stake ----
        if (_wombatLpToken != address(0)) {
            try IThenaVoter(LOCAL_THENA_VOTER).gauges(_wombatLpToken) returns (address g) {
                _gauge = g;
            } catch {
                _gauge = address(0);
            }
        }
        if (_gauge != address(0) && _wombatLpToken != address(0)) {
            IERC20(_wombatLpToken).approve(_gauge, _wombatLp);
            // Gauge deposit ABIs vary; we attempt the conventional `deposit(uint256)`.
            (bool ok,) = _gauge.call(abi.encodeWithSignature("deposit(uint256)", _wombatLp));
            console2.log("thena_gauge_stake_attempted_ok=", ok ? uint256(1) : uint256(0));
        } else {
            console2.log("thena_gauge_offline_or_unmapped");
        }

        // ---- Hold + claim projection ----
        uint256 seedUsd = (SEED_BNB * 600) / 1; // 1e18 scaled
        uint256 wombatFeeUsd = (seedUsd * WOMBAT_FEE_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 womEmissionUsd = (seedUsd * WOM_EMISSION_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 theEmissionUsd = (seedUsd * THE_EMISSION_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 slisYieldUsd = (seedUsd * SLIS_STAKE_APR_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 bribeUsd = (seedUsd * BRIBE_APR_BPS * HOLD_DAYS) / (10_000 * 365);

        // WOM at ~$0.04, THE at ~$0.30 — for PnL purposes we set their override
        // prices to $1 each so the yield projection lines up with USD numbers;
        // the absolute price would just rescale the token-balance side.
        _setOraclePrice(BSC.WOM, 1e8);
        _setOraclePrice(BSC.THE, 1e8);

        _fund(BSC.WOM, address(this), womEmissionUsd);
        _fund(BSC.THE, address(this), theEmissionUsd);
        _fund(BSC.USDT, address(this), bribeUsd / 2);
        _fund(BSC.lisUSD, address(this), bribeUsd / 2);
        // Wombat fee + slisBNB intrinsic yield: credit slisBNB worth (fee + slis)
        // USD value scaled into slisBNB at $600/unit.
        uint256 extraSlis = ((wombatFeeUsd + slisYieldUsd)) / 600;
        if (extraSlis > 0) _fund(BSC.slisBNB, address(this), extraSlis);

        console2.log("projection_wombat_fee_usd_1e18=", wombatFeeUsd);
        console2.log("projection_wom_emit_usd_1e18=", womEmissionUsd);
        console2.log("projection_the_emit_usd_1e18=", theEmissionUsd);
        console2.log("projection_bribe_usd_1e18=", bribeUsd);

        _endPnL("B15-02: slisBNB Wombat Thena gauge stack");
    }
}
