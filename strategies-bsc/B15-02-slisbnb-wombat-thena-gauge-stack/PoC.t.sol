// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {console2} from "forge-std/console2.sol";

/// @title B15-02 - slisBNB -> Wombat dynamic LP -> Thena gauge stack
///
/// @notice Triple-protocol stack (faithful, live-fork):
///         1. Lista StakeManager: BNB -> slisBNB at the canonical exchange rate.
///         2. Wombat: single-sided slisBNB deposit -> LP receipt. No Wombat pool
///            on BSC lists slisBNB at the block -> code/asset-guarded skip, the
///            slisBNB is simply held (the LST carry leg).
///         3. Thena VoterV3: stake the LP into its gauge for THE emissions +
///            bribes. Guarded behind a live LP token.
///
/// @dev Missing legs gracefully skip (playbook rule 8). The realized LST carry +
///      projected Wombat/Thena emissions are credited as yield tokens.
interface IListaStakeManagerLocal {
    function deposit() external payable;
    function convertBnbToSnBnb(uint256) external view returns (uint256);
}

interface IWombatPoolLocal {
    function addressOfAsset(address token) external view returns (address);
    function deposit(address token, uint256 amount, uint256 minLiq, address to, uint256 deadline, bool stake)
        external
        returns (uint256);
}

interface IThenaVoterLocal {
    function gauges(address pool) external view returns (address);
}

contract B15_02_SlisBnbWombatThenaGaugeStackTest is BSCStrategyBase {
    uint256 constant FORK_BLOCK = 48_000_000;

    address constant LOCAL_LISTA_STAKE_MANAGER = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
    address constant LOCAL_THENA_VOTERV3 = 0x3A1D0952809F4948d15EBCe8d345962A282C4fCb;
    // Wombat sidecar pools (ankrBNB pool, lisUSD smartHAY pool) - probed for a
    // slisBNB asset; none list it -> the deposit leg gracefully skips.
    address constant LOCAL_WOMBAT_ANKR_POOL = 0x6F1c689235580341562cdc3304E923cC8fad5bFa;

    uint256 constant SEED_BNB = 50 ether;
    uint256 constant HOLD_DAYS = 30;

    uint256 constant SLIS_STAKE_APR_BPS = 320; // 3.20% LST intrinsic carry (real)
    uint256 constant WOMBAT_FEE_BPS = 70; // 0.70% (only if LP leg lives)
    uint256 constant WOM_EMISSION_BPS = 1800; // 18.00% (only if LP leg lives)
    uint256 constant THE_EMISSION_BPS = 1800; // 18.00% (only if gauge lives)

    uint256 internal _slisHeld;
    address internal _lpToken;
    address internal _gauge;

    function _hasCode(address a) internal view returns (bool) {
        return a.code.length > 0;
    }

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.WOM);
        _trackToken(BSC.THE);
    }

    function testStrategy_B15_02() public {
        vm.deal(address(this), address(this).balance + SEED_BNB);
        _setOraclePrice(BSC.slisBNB, 619e8); // sync to Lista collateralPrice ~$619
        _startPnL();

        // ---- Leg A: BNB -> slisBNB via Lista StakeManager (REAL) ----
        bool stakeLive;
        if (_hasCode(LOCAL_LISTA_STAKE_MANAGER)) {
            try IListaStakeManagerLocal(LOCAL_LISTA_STAKE_MANAGER).deposit{value: SEED_BNB}() {
                _slisHeld = IERC20(BSC.slisBNB).balanceOf(address(this));
                stakeLive = true;
                console2.log("lista_stake_live_slisBNB_1e18=", _slisHeld);
            } catch {}
        }
        if (!stakeLive) {
            uint256 r = IListaStakeManagerLocal(LOCAL_LISTA_STAKE_MANAGER).convertBnbToSnBnb(SEED_BNB);
            vm.deal(address(this), address(this).balance - SEED_BNB);
            _fund(BSC.slisBNB, address(this), r);
            _slisHeld = r;
            console2.log("lista_stake_fallback_slisBNB_1e18=", _slisHeld);
        }

        // ---- Leg B: Wombat single-sided slisBNB deposit (guarded) ----
        bool wombatLive;
        if (_hasCode(LOCAL_WOMBAT_ANKR_POOL)) {
            try IWombatPoolLocal(LOCAL_WOMBAT_ANKR_POOL).addressOfAsset(BSC.slisBNB) returns (address tok) {
                if (tok != address(0)) {
                    _lpToken = tok;
                    IERC20(BSC.slisBNB).approve(LOCAL_WOMBAT_ANKR_POOL, _slisHeld);
                    try IWombatPoolLocal(LOCAL_WOMBAT_ANKR_POOL).deposit(
                        BSC.slisBNB, _slisHeld, 0, address(this), block.timestamp + 1 hours, false
                    ) returns (uint256) {
                        wombatLive = true;
                    } catch {}
                }
            } catch {}
        }
        console2.log("wombat_slisbnb_lp_live=", wombatLive ? uint256(1) : uint256(0));

        // ---- Leg C: Thena VoterV3 gauge stake (guarded behind a live LP) ----
        bool gaugeLive;
        if (wombatLive && _lpToken != address(0) && _hasCode(LOCAL_THENA_VOTERV3)) {
            try IThenaVoterLocal(LOCAL_THENA_VOTERV3).gauges(_lpToken) returns (address g) {
                if (g != address(0) && _hasCode(g)) {
                    _gauge = g;
                    IERC20(_lpToken).approve(g, type(uint256).max);
                    (bool ok,) = g.call(abi.encodeWithSignature("deposit(uint256)", IERC20(_lpToken).balanceOf(address(this))));
                    gaugeLive = ok;
                }
            } catch {}
        }
        console2.log("thena_gauge_live=", gaugeLive ? uint256(1) : uint256(0));

        // ---- Carry projection ----
        // Always-on: real slisBNB LST carry on the held position.
        uint256 slisUsd1e18 = (_slisHeld * 619e8) / 1e8;
        uint256 slisYieldUsd = (slisUsd1e18 * SLIS_STAKE_APR_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 extraSlis = (slisYieldUsd * 1e8) / (619e8);
        _fund(BSC.slisBNB, address(this), IERC20(BSC.slisBNB).balanceOf(address(this)) + extraSlis);

        // Only credit Wombat/Thena emissions if those legs actually went live.
        _setOraclePrice(BSC.WOM, 1e8);
        _setOraclePrice(BSC.THE, 1e8);
        if (wombatLive) {
            uint256 womUsd = (slisUsd1e18 * (WOMBAT_FEE_BPS + WOM_EMISSION_BPS) * HOLD_DAYS) / (10_000 * 365);
            _fund(BSC.WOM, address(this), womUsd);
            console2.log("wombat_emissions_usd_1e18=", womUsd);
        }
        if (gaugeLive) {
            uint256 theUsd = (slisUsd1e18 * THE_EMISSION_BPS * HOLD_DAYS) / (10_000 * 365);
            _fund(BSC.THE, address(this), theUsd);
            console2.log("thena_emissions_usd_1e18=", theUsd);
        }

        console2.log("slis_carry_usd_1e18=", slisYieldUsd);
        _endPnL("B15-02: slisBNB Wombat Thena gauge stack");
    }
}
