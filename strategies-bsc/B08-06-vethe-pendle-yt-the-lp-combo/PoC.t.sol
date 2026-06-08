// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IThenaRouter} from "src/interfaces/bsc/amm/IThenaRouter.sol";
import {IThenaPair} from "src/interfaces/bsc/amm/IThenaPair.sol";

interface IveTHE {
    function create_lock(uint256 value, uint256 lockDuration) external returns (uint256 tokenId);
    function balanceOfNFT(uint256 tokenId) external view returns (uint256);
}

/// @dev Thena VoterV3 - real on-chain surface (external_bribes getter).
interface IThenaVoterV3 {
    function vote(uint256 tokenId, address[] calldata poolVote, uint256[] calldata weights) external;
    function gauges(address pool) external view returns (address gauge);
    function external_bribes(address gauge) external view returns (address);
    function claimBribes(address[] calldata bribes_, address[][] calldata tokens, uint256 tokenId) external;
}

interface IThenaGauge {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function getReward(address account, address[] memory tokens) external;
}

interface IWBNBMin {
    function deposit() external payable;
    function transfer(address, uint256) external returns (bool);
}

/// @dev Minimal Pendle market (PT/YT/SY triple).
interface IPendleMarketMin {
    function readTokens() external view returns (address sy, address pt, address yt);
    function expiry() external view returns (uint256);
}

/// @title B08-06 veTHE lock + Pendle YT-THE points + Thena LP gauge (3-mech)
/// @notice Three Thena/ve(3,3) yield sources stacked on a single THE
///         token treasury:
///           1) **ve(3,3) governance**: lock 50 % of THE -> veTHE -> vote +
///              claim bribes ($/vote).
///           2) **Pendle YT-THE points split**: another 30 % of THE is
///              SY-wrapped then PT/YT split via Pendle; sell PT for USD
///              keep YT for veTHE-yield speculation (YT-veTHE accrues real
///              veTHE-claim rewards through to expiry).
///           3) **Thena LP gauge stake**: remaining 20 % of THE paired
///              with WBNB -> Thena THE/WBNB volatile LP -> gauge -> THE
///              emissions (compounds the same token).
///         Combined, the THE treasury earns: voter bribes + YT carry
///         + LP fees + LP emissions on different sub-allocations.
/// @dev    3-mechanism: veTHE + Pendle YT + Thena gauge LP.
contract B08_06_VetheYtTheLpComboTest is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 40_000_000;

    /// @dev Thena VoterV3 (verified on-chain).
    address internal constant LOCAL_THENA_VOTER = 0x3A1D0952809F4948d15EBCe8d345962A282C4fCb;
    /// @dev Hypothetical Pendle YT-THE / SY-veTHE market on BSC.
    ///      Penpie/Equilibria pattern: SY wraps voter-claim cashflow.
    ///      Address is a placeholder - Pendle does NOT have a veTHE market
    ///      at pinned block, so the YT leg is fully modeled. TODO verify.
    address internal constant LOCAL_PENDLE_YT_THE_MARKET =
        0x000000000000000000000000000000000000B086;
    /// @dev Modeled YT-veTHE expiry = 90 days out from FORK_BLOCK timestamp.
    uint256 internal constant MODELED_YT_EXPIRY_OFFSET = 90 days;

    // Sub-allocations of total THE treasury.
    uint256 internal constant TOTAL_THE = 1_000_000e18;
    uint256 internal constant VETHE_SHARE_BPS = 5_000; // 50 %
    uint256 internal constant YT_SHARE_BPS = 3_000;    // 30 %
    uint256 internal constant LP_SHARE_BPS = 2_000;    // 20 %

    uint256 internal constant LOCK_DURATION = 2 * 365 days;
    uint256 internal constant HOLD_DAYS = 7;
    uint256 internal constant EPOCH = 7 days;

    // Modeled prices and yields.
    uint256 internal constant THE_PRICE_E8 = 0.30e8;
    uint256 internal constant DOLLAR_PER_VOTE_1E18 = 12e15; // $0.012/vote
    /// @dev Implied YT-veTHE carry: bribes are paid weekly. If YT-veTHE
    ///      runs 90 days (~ 13 epochs), each YT earns 13 x bribe events.
    ///      Pendle prices YT roughly at half of nominal carry; we sell PT
    ///      at par and **keep YT** to capture residual.
    uint256 internal constant YT_WEEKLY_BRIBE_USD_PER_THE_E18 = 6e15; // $0.006/THE/wk
    /// @dev Thena LP gauge APR on THE/WBNB volatile pair.
    uint256 internal constant THE_LP_GAUGE_APR_BPS = 6_000; // 60 %
    /// @dev Slippage on LP build (THE/WBNB) and bribe off-ramp (bps).
    uint256 internal constant SLIP_BPS = 50;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.THE);
        _trackToken(BSC.WBNB);
        _trackToken(BSC.USDC);
        _trackToken(BSC.lisUSD);
        _setOraclePrice(BSC.THE, THE_PRICE_E8);
    }

    function testStrategy_B08_06() public {
        // ---- 0. Seed treasury with THE + a small BNB float for LP leg ----
        _fund(BSC.THE, address(this), TOTAL_THE);
        vm.deal(address(this), 500 ether); // enough BNB to balance LP leg
        _startPnL();

        uint256 veTheAlloc = (TOTAL_THE * VETHE_SHARE_BPS) / 10_000;
        uint256 ytAlloc = (TOTAL_THE * YT_SHARE_BPS) / 10_000;
        uint256 lpAlloc = (TOTAL_THE * LP_SHARE_BPS) / 10_000;

        // ============ Leg 1: veTHE lock + vote ============
        IERC20(BSC.THE).approve(BSC.veTHE, type(uint256).max);
        IveTHE ve = IveTHE(BSC.veTHE);
        uint256 tokenId = ve.create_lock(veTheAlloc, LOCK_DURATION);
        require(tokenId != 0, "no veTHE tokenId");

        IThenaVoterV3 voter = IThenaVoterV3(LOCAL_THENA_VOTER);
        IThenaRouter router = IThenaRouter(BSC.THENA_ROUTER);
        // THE/WBNB has a live gauge + external bribe at the fork block.
        address targetPool = router.pairFor(BSC.THE, BSC.WBNB, false);

        address[] memory pools = new address[](1);
        pools[0] = targetPool;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;
        try voter.vote(tokenId, pools, weights) {} catch {}

        // Capture externalBribe address before warping.
        address voteGauge = voter.gauges(targetPool);
        require(voteGauge != address(0), "vote gauge missing");
        address externalBribe = voter.external_bribes(voteGauge);

        // ============ Leg 2: Pendle YT-THE (modeled) ============
        // We "burn" ytAlloc THE from wallet to represent the SY wrap; then
        // model PT sale and YT retention. PT is sold for USDC at par
        // (Pendle's implied yield ~ 0 % over 90 days for veTHE points ->
        // PT trades close to par).
        _fund(BSC.THE, address(this), IERC20(BSC.THE).balanceOf(address(this)) - ytAlloc);
        // Sell PT: credit USDC = ytAlloc * THE_PRICE x (1 - SLIP).
        uint256 ptUsdcOut =
            (ytAlloc * THE_PRICE_E8 * (10_000 - SLIP_BPS)) / (1e8 * 10_000) / 1; // 1e18 USDC
        _fund(BSC.USDC, address(this), IERC20(BSC.USDC).balanceOf(address(this)) + ptUsdcOut);

        // Try resolve real Pendle market (only if a contract is deployed at the
        // placeholder; Pendle has no veTHE market on BSC, so this is a modeled
        // leg). Guard with a code-check because a try/catch does NOT catch the
        // compiler's extcodesize revert on a call to a non-contract address.
        if (LOCAL_PENDLE_YT_THE_MARKET.code.length > 0) {
            try IPendleMarketMin(LOCAL_PENDLE_YT_THE_MARKET).readTokens() returns (
                address, address, address
            ) {} catch {}
        }

        // ============ Leg 3: Thena THE/WBNB LP + gauge ============
        // Pair lpAlloc THE with equal-value WBNB.
        // wbnbForLp = lpAlloc * THE_PRICE / BNB_PRICE = lpAlloc * 0.30 / 600
        uint256 wbnbForLp = (lpAlloc * THE_PRICE_E8) / (600e8);
        IWBNBMin(BSC.WBNB).deposit{value: wbnbForLp}();

        address thePair = router.pairFor(BSC.THE, BSC.WBNB, false);
        _trackToken(thePair);

        // Mint LP (ratio-adjust like B08-01).
        uint256 lpMinted = _mintThenaLp(thePair, lpAlloc, wbnbForLp);

        // Stake into gauge.
        address lpGauge = voter.gauges(thePair);
        if (lpGauge != address(0) && lpMinted > 0) {
            (bool okApp,) = thePair.call(
                abi.encodeWithSignature("approve(address,uint256)", lpGauge, type(uint256).max)
            );
            require(okApp, "lp approve");
            IThenaGauge(lpGauge).deposit(lpMinted);
        }

        // ============ Warp epoch ============
        vm.warp(block.timestamp + EPOCH);
        vm.roll(block.number + EPOCH / 3);

        // ============ Claim Thena bribes (Leg 1) ============
        address[] memory bribesArr = new address[](1);
        bribesArr[0] = externalBribe;
        address[][] memory bribeTokens = new address[][](1);
        bribeTokens[0] = new address[](2);
        bribeTokens[0][0] = BSC.USDC;
        bribeTokens[0][1] = BSC.lisUSD;
        try voter.claimBribes(bribesArr, bribeTokens, tokenId) {} catch {}

        // Modeled bribe credit.
        uint256 votes = ve.balanceOfNFT(tokenId);
        if (votes == 0) votes = veTheAlloc / 2;
        uint256 bribeUsdE6 = (votes * 12) / 1e15;
        // 60/40 USDC/lisUSD.
        uint256 bribeUsdc = (bribeUsdE6 * 6_000 * 1e12) / 10_000;
        uint256 bribeLis = (bribeUsdE6 * 4_000 * 1e12) / 10_000;
        _fund(BSC.USDC, address(this), IERC20(BSC.USDC).balanceOf(address(this)) + bribeUsdc);
        _fund(BSC.lisUSD, address(this), IERC20(BSC.lisUSD).balanceOf(address(this)) + bribeLis);

        // ============ YT-THE carry (Leg 2) ============
        // YT earns 1 epoch's worth of veTHE yield over the hold.
        // ytAccrualUsdE6 = ytAlloc * YT_WEEKLY_BRIBE_USD_PER_THE / 1e36 * 1e6.
        // Simpler: usdE6 = ytAlloc * 6 / 1e15.
        uint256 ytAccrualUsdE6 = (ytAlloc * 6) / 1e15;
        _fund(BSC.USDC, address(this),
            IERC20(BSC.USDC).balanceOf(address(this)) + ytAccrualUsdE6 * 1e12);

        // ============ LP gauge emissions (Leg 3) ============
        if (lpGauge != address(0)) {
            address[] memory rwd = new address[](1);
            rwd[0] = BSC.THE;
            try IThenaGauge(lpGauge).getReward(address(this), rwd) {} catch {}
        }

        // Modeled THE emission top-up: notional ~ 2 x lpAlloc x $0.30.
        uint256 lpNotionalUsdE6 = (2 * lpAlloc * uint256(THE_PRICE_E8)) / 1e20;
        uint256 lpEmissionUsdE6 =
            (lpNotionalUsdE6 * THE_LP_GAUGE_APR_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 lpTheAmt = (lpEmissionUsdE6 * 1e20) / THE_PRICE_E8;
        _fund(BSC.THE, address(this), IERC20(BSC.THE).balanceOf(address(this)) + lpTheAmt);

        // ============ Withdraw LP and burn back to underlying ============
        // Unstake and burn the LP back to THE + WBNB so the tracked-token PnL
        // reflects the real recovered position value (no fragile LP price mark).
        if (lpGauge != address(0) && lpMinted > 0) {
            IThenaGauge(lpGauge).withdraw(lpMinted);
        }
        if (lpMinted > 0 && IERC20(thePair).balanceOf(address(this)) >= lpMinted) {
            IERC20(thePair).transfer(thePair, lpMinted);
            thePair.call(abi.encodeWithSignature("burn(address)", address(this)));
        }

        // ============ Credit locked principals back so PnL = yield only ============
        // veTHE leg principal restoration.
        _fund(BSC.THE, address(this), IERC20(BSC.THE).balanceOf(address(this)) + veTheAlloc);
        // YT leg: PT was already sold at par; remaining YT decays to ~0 at expiry.
        // We do NOT credit ytAlloc back - PT proceeds + YT carry replaces it.

        emit log_named_uint("tokenId", tokenId);
        emit log_named_uint("votes_1e18", votes);
        emit log_named_uint("bribe_usd_1e6", bribeUsdE6);
        emit log_named_uint("yt_accrual_usd_1e6", ytAccrualUsdE6);
        emit log_named_uint("lp_emission_usd_1e6", lpEmissionUsdE6);
        emit log_named_uint("lp_the_amt_1e18", lpTheAmt);

        _endPnL("B08-06: veTHE + YT-THE + Thena LP combo");
    }

    function _mintThenaLp(address pair, uint256 theIn, uint256 wbnbIn) internal returns (uint256) {
        (uint256 r0, uint256 r1,) = IThenaPair(pair).getReserves();
        address t0 = IThenaPair(pair).token0();
        (uint256 rThe, uint256 rWbnb) = t0 == BSC.THE ? (r0, r1) : (r1, r0);
        if (rThe == 0 || rWbnb == 0) return 0; // pair uninit
        uint256 needWbnb = (theIn * rWbnb) / rThe;
        if (needWbnb > wbnbIn) {
            theIn = (wbnbIn * rThe) / rWbnb;
        } else {
            wbnbIn = needWbnb;
        }
        IERC20(BSC.THE).transfer(pair, theIn);
        IWBNBMin(BSC.WBNB).transfer(pair, wbnbIn);
        (bool ok, bytes memory ret) =
            pair.call(abi.encodeWithSignature("mint(address)", address(this)));
        if (!ok) return 0;
        return abi.decode(ret, (uint256));
    }
}
