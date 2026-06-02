// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IThenaVoter} from "src/interfaces/bsc/amm/IThenaVoter.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {IListaStakeManager} from "src/interfaces/bsc/lst/IListaStakeManager.sol";
import {console2} from "forge-std/console2.sol";

/// @title B15-08 — veTHE bribe vote + Pendle YT-asBNB + Venus credit stack
///
/// @notice Triple-mechanism *ve(3,3) + tokenized-yield + lending* stack:
///         1. **veTHE** — lock THE for veTHE; vote on the asBNB/WBNB Thena
///            pool to direct emissions and harvest weekly bribe baskets
///            (Lista, Astherus and BTCB-side gauges historically bribe in
///            USDT + lisUSD + asBNB).
///         2. **Pendle YT-asBNB** — use harvested bribe USDT to buy
///            YT-asBNB for *points + restake yield* exposure (decays to
///            zero at maturity but accrues Astherus / Babylon points).
///         3. **Venus collateral** — supply seed asBNB + harvested
///            asBNB-side bribes as Venus collateral (proxy vBNB until
///            vAsBNB lists), borrow USDT for the next YT purchase cycle.
///
/// @dev Distinct from B15-02 (Thena gauge stake, not veTHE lock-and-vote),
///      B15-04 (YT-asBNB only, single LTV, no veTHE), and B15-06 (BTC
///      stack).  Here veTHE acts as a *yield director* feeding the
///      YT-buy loop.
contract B15_08_VetheePendleYtAsBnbVenusStackTest is BSCStrategyBase {
    uint256 constant FORK_BLOCK = 42_850_000;

    /// @notice Pendle YT-asBNB market. // TODO verify.
    address constant LOCAL_YT_ASBNB_MARKET = 0x9eC4c502D989F04FfA9312C9D6E3F872EC91A0F9;

    /// @notice Thena Voter (same address used by B15-02).
    address constant LOCAL_THENA_VOTER = 0x374cc2276b842fEcD65af36D7C60A5B78373EdE1;

    /// @notice Placeholder asBNB/WBNB Thena pool. // TODO verify.
    address constant LOCAL_ASBNB_WBNB_POOL = 0xdeAD0000bEef00000000aDDEAdd00000B15B0008;

    // ---- Sizing ----
    uint256 constant SEED_BNB = 50 ether;
    uint256 constant SEED_THE = 5_000e18;            // tokens to lock
    uint256 constant VENUS_LTV_BPS = 5000;           // 50 %
    uint256 constant HOLD_DAYS = 90;

    /// @dev Implied YT entry price as bps of underlying notional.
    uint256 constant YT_ENTRY_BPS = 500;             // 5 %

    // ---- Carry assumptions ----
    uint256 constant THE_VOTE_BRIBE_APR_BPS = 4000;  // 40 % on locked notional
    uint256 constant VENUS_USDT_BORROW_BPS = 500;    // 5 %
    uint256 constant ASBNB_RESTAKE_APR_BPS = 950;    // 9.5 %

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
        } catch {
            console2.log("BSC_RPC_URL not set; B15-08 runs as offline projection");
        }
        _trackToken(BSC.THE);
        _trackToken(BSC.asBNB);
        _trackToken(BSC.USDT);
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.WBNB);
    }

    function testStrategy_B15_08() public {
        vm.deal(address(this), SEED_BNB);
        _fund(BSC.THE, address(this), SEED_THE);
        _startPnL();

        // ---- Leg A: Lock THE → veTHE → vote on asBNB pool ----
        // We don't import the veTHE NFT interface — but the lock-and-vote
        // shape is well-known.  We attempt the canonical createLock /
        // vote ABI by raw call, and otherwise model the locked THE as
        // sent to the veTHE address.
        IERC20(BSC.THE).approve(BSC.veTHE, SEED_THE);
        bool veLockLive;
        (bool ok,) =
            BSC.veTHE.call(abi.encodeWithSignature("createLock(uint256,uint256)", SEED_THE, 4 * 365 days));
        veLockLive = ok;
        if (!veLockLive) {
            // Offline: model lock as transfer (THE no longer ours).
            IERC20(BSC.THE).transfer(BSC.veTHE, SEED_THE);
            console2.log("vethe_lock_offline_modelled_THE_1e18=", SEED_THE);
        } else {
            console2.log("vethe_lock_live_THE_1e18=", SEED_THE);
        }

        // Vote the asBNB/WBNB gauge — try the canonical voter ABI.
        address[] memory pools = new address[](1);
        pools[0] = LOCAL_ASBNB_WBNB_POOL;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000; // 100 %
        try IThenaVoter(LOCAL_THENA_VOTER).vote(0, pools, weights) {
            console2.log("vethe_vote_live");
        } catch {
            console2.log("vethe_vote_offline_no_op");
        }

        // ---- Leg B: BNB -> asBNB seed (becomes Venus collateral) ----
        uint256 asBnbHeld;
        try IListaStakeManager(BSC.ASTHERUS_STAKE_MANAGER).deposit{value: SEED_BNB}() {
            asBnbHeld = IERC20(BSC.asBNB).balanceOf(address(this));
        } catch {
            _fund(BSC.asBNB, address(this), SEED_BNB);
            asBnbHeld = SEED_BNB;
        }
        console2.log("seed_asbnb_1e18=", asBnbHeld);

        // ---- Leg C: Venus supply asBNB (proxy vBNB) + borrow USDT ----
        uint256 asBnbUsd = asBnbHeld * 600;
        uint256 usdtBorrow = (asBnbUsd * VENUS_LTV_BPS) / 10_000;

        _enterVenusBnbMarket();
        bool venusLive;
        try IVToken(BSC.vUSDT).borrow(usdtBorrow) returns (uint256 err) {
            venusLive = (err == 0);
        } catch {
            venusLive = false;
        }
        if (!venusLive) {
            _fund(BSC.USDT, address(this), usdtBorrow);
            console2.log("venus_borrow_offline_funded_USDT_1e18=", usdtBorrow);
        } else {
            console2.log("venus_borrow_live_USDT_1e18=", usdtBorrow);
        }

        // ---- Leg D: Pendle YT-asBNB swap with the borrowed USDT ----
        IERC20(BSC.USDT).approve(BSC.PENDLE_ROUTER_V4, usdtBorrow);
        uint256 ytFace = (usdtBorrow * 10_000) / YT_ENTRY_BPS;
        bool pendleLive = _trySwapUsdtForYt(usdtBorrow);
        if (!pendleLive) {
            // Burn USDT to model the YT spend.
            uint256 bal = IERC20(BSC.USDT).balanceOf(address(this));
            uint256 burn = usdtBorrow > bal ? bal : usdtBorrow;
            if (burn > 0) IERC20(BSC.USDT).transfer(address(0xdEaD), burn);
            console2.log("pendle_yt_offline_face_1e18=", ytFace);
        } else {
            console2.log("pendle_yt_live_face_1e18=", ytFace);
        }

        // ---- 90-day carry projection ----
        // Vote bribes: 40 % APR on the locked THE notional, paid in
        // USDT + lisUSD + asBNB (we split equally).
        uint256 lockUsd = SEED_THE / 10; // assume $0.10 / THE → $500 locked
        uint256 bribeUsd = (lockUsd * THE_VOTE_BRIBE_APR_BPS * HOLD_DAYS) / (10_000 * 365);
        _fund(BSC.USDT, address(this), bribeUsd / 3);
        _fund(BSC.lisUSD, address(this), bribeUsd / 3);
        _fund(BSC.asBNB, address(this), (bribeUsd / 3) / 600);

        // Venus carry cost — borrow side.
        uint256 venusCost = (usdtBorrow * VENUS_USDT_BORROW_BPS * HOLD_DAYS) / (10_000 * 365);
        // asBNB collateral keeps earning Astherus restake.
        uint256 asBnbYield = (asBnbHeld * ASBNB_RESTAKE_APR_BPS * HOLD_DAYS) / (10_000 * 365);

        _fund(BSC.USDT, address(this), 0); // ensure ledger fresh
        _fund(BSC.asBNB, address(this), asBnbYield);

        uint256 usdtBal = IERC20(BSC.USDT).balanceOf(address(this));
        uint256 burn2 = venusCost > usdtBal ? usdtBal : venusCost;
        if (burn2 > 0) IERC20(BSC.USDT).transfer(address(0xdEaD), burn2);

        console2.log("projection_vote_bribe_usd_1e18=", bribeUsd);
        console2.log("projection_asbnb_restake_bnb_1e18=", asBnbYield);
        console2.log("projection_venus_borrow_cost_usdt_1e18=", venusCost);

        _endPnL("B15-08: veTHE + Pendle YT-asBNB + Venus stack");
    }

    function _enterVenusBnbMarket() internal {
        address[] memory mkts = new address[](1);
        mkts[0] = BSC.vBNB;
        try IVenusComptroller(BSC.VENUS_COMPTROLLER).enterMarkets(mkts) returns (uint256[] memory) {} catch {}
    }

    function _trySwapUsdtForYt(uint256 usdtIn) internal returns (bool ok) {
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: BSC.USDT,
            netTokenIn: usdtIn,
            tokenMintSy: BSC.USDT,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        IPendleRouter.LimitOrderData memory emptyLimit;
        try IPendleRouter(BSC.PENDLE_ROUTER_V4).swapExactTokenForYt(
            address(this), LOCAL_YT_ASBNB_MARKET, 0, approx, input, emptyLimit
        ) returns (uint256, uint256, uint256) {
            ok = true;
        } catch {
            ok = false;
        }
    }
}
