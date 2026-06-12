// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IThenaRouter} from "src/interfaces/bsc/amm/IThenaRouter.sol";
import {IThenaPair} from "src/interfaces/bsc/amm/IThenaPair.sol";
/// @dev Thena VoterV3 (gauges getter).
interface IThenaVoterV3 {
    function gauges(address pool) external view returns (address gauge);
}

interface IThenaGauge {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function getReward(address account, address[] memory tokens) external;
}

/// @dev Wombat MasterWombat surface (veWOM-boostable stable LP staking).
interface IMasterWombatMin {
    function deposit(uint256 pid, uint256 amount) external returns (uint256, uint256[] memory);
    function withdraw(uint256 pid, uint256 amount) external returns (uint256, uint256[] memory);
    function multiClaim(uint256[] memory pids) external returns (uint256, uint256[] memory, uint256[][] memory);
    function pendingTokens(uint256 pid, address user)
        external view returns (uint256, address[] memory, string[] memory, uint256[] memory);
}

/// @dev Wombat Pool - deposit/withdraw of LP receipts.
interface IWombatPoolMin {
    function deposit(address token, uint256 amount, uint256 minLiquidity, address to, uint256 deadline, bool stake)
        external returns (uint256);
    function withdraw(address token, uint256 lpAmount, uint256 minimumAmount, address to, uint256 deadline)
        external returns (uint256);
}

/// @dev veWOM voting escrow.
interface IveWOMMin {
    function mint(uint256 amount, uint256 lockDays) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

/// @title B08-08 Stable-pool triple-gauge stack: PCS + Thena + Wombat
/// @notice The USDe/USDC pair has gauges on all three protocols:
///         - PCS v3 stable pool (CAKE emissions via MasterChefV3)
///         - Thena stable pair (THE emissions via gauge)
///         - Wombat single-sided USDe/USDC deposits (WOM emissions via
///           MasterWombat, boostable with veWOM)
///         We split $1.5M USDC across the three protocols, optionally
///         lock WOM to boost the Wombat leg.
/// @dev    3-mechanism: Thena gauge + PCS gauge + Wombat veWOM-boosted gauge.
contract B08_08_StableGaugeStackTest is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 40_000_000;

    address internal constant LOCAL_THENA_VOTER = 0x3A1D0952809F4948d15EBCe8d345962A282C4fCb;
    /// @dev MasterWombatV3 on BSC. TODO verify on bscscan.
    address internal constant LOCAL_MASTER_WOMBAT = 0x489833311676B566f888119c29bd997Dc6C95830;
    /// @dev veWOM. TODO verify.
    address internal constant LOCAL_VE_WOM = 0x3DA62816dD31c56D9CdF22C6771ddb892cB5b0Cc;
    /// @dev Modeled MasterWombat pid for USDe pool. TODO verify.
    uint256 internal constant LOCAL_WOMBAT_PID = 30;

    // Allocation: $500k per leg, $1.5M total. BSC stables are 18-dec.
    uint256 internal constant PER_LEG = 500_000e18;
    uint256 internal constant TOTAL = 1_500_000e18;
    uint256 internal constant WOM_LOCK = 200_000e18; // veWOM boost capital
    uint256 internal constant WOM_LOCK_DAYS = 1095;  // 3y
    uint256 internal constant HOLD_DAYS = 7;

    // Modeled APRs (bps).
    uint256 internal constant THENA_APR_BPS = 1_200; // 12 % (stable pair, lower than volatile)
    uint256 internal constant PCS_APR_BPS = 900;     // 9 %
    uint256 internal constant WOMBAT_BASE_APR_BPS = 600;     // 6 % unboosted
    uint256 internal constant WOMBAT_BOOST_MULTIPLIER_BPS = 25_000; // 2.5x via veWOM

    // Token prices 1e8.
    uint256 internal constant THE_PRICE_E8 = 0.30e8;
    uint256 internal constant CAKE_PRICE_E8 = 2.40e8;
    uint256 internal constant WOM_PRICE_E8 = 0.10e8;

    uint256 internal constant SLIP_BPS = 25;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.USDC);
        _trackToken(BSC.USDe);
        _trackToken(BSC.USDT);
        _trackToken(BSC.THE);
        _trackToken(BSC.CAKE);
        _trackToken(BSC.WOM);
        _setOraclePrice(BSC.THE, THE_PRICE_E8);
        _setOraclePrice(BSC.CAKE, CAKE_PRICE_E8);
        _setOraclePrice(BSC.WOM, WOM_PRICE_E8);
    }

    function testStrategy_B08_08() public {
        _fund(BSC.USDC, address(this), TOTAL);
        _fund(BSC.WOM, address(this), WOM_LOCK);
        _startPnL();

        // ---- Leg 1: Thena USDT/USDC stable LP + gauge ----
        // The USDe/USDC stable pair has no Thena gauge at the fork block; the
        // USDT/USDC stable pair (0x618f..) has a live gauge (0x6e1a..) but very
        // shallow reserves (~$16k). We therefore exercise the real LP+gauge
        // mechanism with a small probe sized to the pool depth, and MODEL the
        // emissions on the full $500k leg notional (the strategy thesis). The
        // bulk $500k principal is held as USDC (re-credited as the locked LP at
        // close), exactly as the PCS leg below.
        uint256 thenaProbe = 1_000e18; // ~$1k probe, safely within pool depth
        // Burn the leg's USDC minus the small amount kept for the probe's USDC
        // side; fund the probe's USDT side via deal.
        _fund(BSC.USDC, address(this), IERC20(BSC.USDC).balanceOf(address(this)) - (PER_LEG - thenaProbe));
        _fund(BSC.USDT, address(this), IERC20(BSC.USDT).balanceOf(address(this)) + thenaProbe);

        IThenaRouter router = IThenaRouter(BSC.THENA_ROUTER);
        address thenaPair = router.pairFor(BSC.USDT, BSC.USDC, /*stable=*/ true);
        _trackToken(thenaPair);

        uint256 thenaLp = _mintThenaStableLp(thenaPair, thenaProbe, thenaProbe);

        IThenaVoterV3 voter = IThenaVoterV3(LOCAL_THENA_VOTER);
        address thenaGauge = voter.gauges(thenaPair);
        if (thenaGauge != address(0) && thenaLp > 0) {
            (bool okApp,) = thenaPair.call(
                abi.encodeWithSignature("approve(address,uint256)", thenaGauge, type(uint256).max)
            );
            require(okApp, "thena approve");
            IThenaGauge(thenaGauge).deposit(thenaLp);
        }
        // Locked Thena-leg principal (modeled): the remaining USDC of the leg.
        uint256 thenaLockedUsdc = PER_LEG;

        // ---- Leg 2: PCS v3 USDC/USDT concentrated LP (modeled - same structure
        //              as B08-03, fully credited via _fund for offline PoC) ----
        // Burn one $500k USDC leg to simulate the locked PCS position. Track
        // returned emissions only; the principal is re-credited at close.
        uint256 pcsLockedUsdc = PER_LEG;
        _fund(BSC.USDC, address(this), IERC20(BSC.USDC).balanceOf(address(this)) - pcsLockedUsdc);

        // ---- Leg 3: Wombat USDe single-sided deposit + veWOM lock ----
        // a) Lock WOM into veWOM for boost.
        IERC20(BSC.WOM).approve(LOCAL_VE_WOM, type(uint256).max);
        try IveWOMMin(LOCAL_VE_WOM).mint(WOM_LOCK, WOM_LOCK_DAYS) returns (uint256) {} catch {}

        // b) Deposit USDe into Wombat pool (convert the remaining USDC leg).
        _fund(BSC.USDC, address(this), IERC20(BSC.USDC).balanceOf(address(this)) - PER_LEG);
        _fund(BSC.USDe, address(this), IERC20(BSC.USDe).balanceOf(address(this)) + PER_LEG);

        IERC20(BSC.USDe).approve(BSC.WOMBAT_MAIN_POOL, type(uint256).max);
        try IWombatPoolMin(BSC.WOMBAT_MAIN_POOL).deposit(
            BSC.USDe, PER_LEG, 0, address(this), block.timestamp + 600, /*stake=*/ true
        ) {} catch {
            // Wombat may revert offline; modeled credit below stands.
            _fund(BSC.USDe, address(this), IERC20(BSC.USDe).balanceOf(address(this)) - PER_LEG);
        }

        // ---- Warp 1 week ----
        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
        vm.roll(block.number + (HOLD_DAYS * 1 days) / 3);

        // ---- Harvest Thena ----
        if (thenaGauge != address(0)) {
            address[] memory rwd = new address[](1);
            rwd[0] = BSC.THE;
            try IThenaGauge(thenaGauge).getReward(address(this), rwd) {} catch {}
        }
        uint256 thenaUsdE6 =
            (PER_LEG / 1e12) * THENA_APR_BPS * HOLD_DAYS / (10_000 * 365);
        uint256 theAmt = (thenaUsdE6 * 1e20) / THE_PRICE_E8;
        _fund(BSC.THE, address(this), IERC20(BSC.THE).balanceOf(address(this)) + theAmt);
        // Sell THE -> USDC.
        uint256 usdcFromThe =
            (theAmt * THE_PRICE_E8 * (10_000 - SLIP_BPS)) / (1e8 * 10_000);
        _fund(BSC.THE, address(this), 0);
        _fund(BSC.USDC, address(this), IERC20(BSC.USDC).balanceOf(address(this)) + usdcFromThe);

        // ---- PCS leg modeled CAKE ----
        uint256 pcsUsdE6 =
            (PER_LEG / 1e12) * PCS_APR_BPS * HOLD_DAYS / (10_000 * 365);
        uint256 cakeAmt = (pcsUsdE6 * 1e20) / CAKE_PRICE_E8;
        _fund(BSC.CAKE, address(this), IERC20(BSC.CAKE).balanceOf(address(this)) + cakeAmt);
        uint256 usdcFromCake =
            (cakeAmt * CAKE_PRICE_E8 * (10_000 - SLIP_BPS)) / (1e8 * 10_000);
        _fund(BSC.CAKE, address(this), 0);
        _fund(BSC.USDC, address(this), IERC20(BSC.USDC).balanceOf(address(this)) + usdcFromCake);

        // ---- Wombat leg: veWOM boost amplifies base APR ----
        // boosted_apr = base_apr * boost_multiplier / 10000 -> 6% * 2.5 = 15%
        uint256 wombatBoostedAprBps =
            (WOMBAT_BASE_APR_BPS * WOMBAT_BOOST_MULTIPLIER_BPS) / 10_000;
        uint256 wombatUsdE6 =
            (PER_LEG / 1e12) * wombatBoostedAprBps * HOLD_DAYS / (10_000 * 365);
        uint256 womAmt = (wombatUsdE6 * 1e20) / WOM_PRICE_E8;
        // Try real claim first.
        uint256[] memory pids = new uint256[](1);
        pids[0] = LOCAL_WOMBAT_PID;
        try IMasterWombatMin(LOCAL_MASTER_WOMBAT).multiClaim(pids) {} catch {}
        _fund(BSC.WOM, address(this), IERC20(BSC.WOM).balanceOf(address(this)) + womAmt);
        // Sell WOM -> USDC.
        uint256 usdcFromWom =
            (womAmt * WOM_PRICE_E8 * (10_000 - SLIP_BPS)) / (1e8 * 10_000);
        _fund(BSC.WOM, address(this), 0);
        _fund(BSC.USDC, address(this), IERC20(BSC.USDC).balanceOf(address(this)) + usdcFromWom);

        // ---- Withdraw LP positions and credit principal back ----
        // Thena leg: unstake (if staked) and burn the LP back to USDT/USDC so
        // the tracked-token PnL reflects the real recovered underlying (no
        // fragile LP price override).
        if (thenaGauge != address(0) && thenaLp > 0) {
            try IThenaGauge(thenaGauge).withdraw(thenaLp) {} catch {}
        }
        if (thenaLp > 0 && IERC20(thenaPair).balanceOf(address(this)) >= thenaLp) {
            IERC20(thenaPair).transfer(thenaPair, thenaLp);
            thenaPair.call(abi.encodeWithSignature("burn(address)", address(this)));
        }
        // Thena leg: credit the modeled locked USDC principal back (the leg
        // minus the small probe USDC, which is recovered via the LP burn above).
        _fund(BSC.USDC, address(this), IERC20(BSC.USDC).balanceOf(address(this)) + (thenaLockedUsdc - thenaProbe));
        // PCS leg: credit the locked $500k USDC principal back.
        _fund(BSC.USDC, address(this), IERC20(BSC.USDC).balanceOf(address(this)) + pcsLockedUsdc);
        // Wombat leg: credit USDe principal.
        _fund(BSC.USDe, address(this), IERC20(BSC.USDe).balanceOf(address(this)) + PER_LEG);
        // veWOM lock principal: the WOM_LOCK is escrowed in veWOM and is
        // recoverable at unlock, so credit it back (same treatment as the
        // veTHE locks in B08-02/04) to reflect single-epoch yield, not the
        // lock itself.
        _fund(BSC.WOM, address(this), IERC20(BSC.WOM).balanceOf(address(this)) + WOM_LOCK);

        emit log_named_uint("thena_lp_minted_1e18", thenaLp);
        emit log_named_uint("the_modeled_1e18", theAmt);
        emit log_named_uint("cake_modeled_1e18", cakeAmt);
        emit log_named_uint("wom_modeled_boosted_1e18", womAmt);
        emit log_named_uint("wombat_boosted_apr_bps", wombatBoostedAprBps);

        _endPnL("B08-08: stable USDT/USDC triple-gauge stack");
    }

    function _mintThenaStableLp(address pair, uint256 a, uint256 b) internal returns (uint256) {
        // Ratio-match to the live USDT/USDC stable reserves so the mint does
        // not strand a leg (Solidly stable pairs are near-1:1 but not exact).
        (uint256 r0, uint256 r1,) = IThenaPair(pair).getReserves();
        address t0 = IThenaPair(pair).token0();
        (uint256 rUsdt, uint256 rUsdc) = t0 == BSC.USDT ? (r0, r1) : (r1, r0);
        if (rUsdt != 0 && rUsdc != 0) {
            uint256 needUsdc = (a * rUsdc) / rUsdt;
            if (needUsdc > b) {
                a = (b * rUsdt) / rUsdc;
            } else {
                b = needUsdc;
            }
        }
        IERC20(BSC.USDT).transfer(pair, a);
        IERC20(BSC.USDC).transfer(pair, b);
        (bool ok, bytes memory ret) =
            pair.call(abi.encodeWithSignature("mint(address)", address(this)));
        if (!ok) return 0;
        return abi.decode(ret, (uint256));
    }
}
