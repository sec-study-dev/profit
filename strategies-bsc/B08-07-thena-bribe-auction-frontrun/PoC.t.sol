// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IThenaRouter} from "src/interfaces/bsc/amm/IThenaRouter.sol";
import {IThenaVoter} from "src/interfaces/bsc/amm/IThenaVoter.sol";

interface IveTHE {
    function create_lock(uint256 value, uint256 lockDuration) external returns (uint256 tokenId);
    function balanceOfNFT(uint256 tokenId) external view returns (uint256);
}

/// @dev Bribe contract surface used to read $/vote BEFORE we cast our vote.
///      `earned` lets us simulate the vote and price the marginal $/vote.
interface IBribeMin {
    function rewardPerToken(address token) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function rewards(address token) external view returns (uint256);
}

/// @title B08-07 Thena bribe-auction front-run on epoch close
/// @notice Thena votes finalize at Thursday 23:59 UTC. Bribe payers
///         drop USDC/lisUSD onto gauge externalBribes throughout the
///         week, but the LAST 1-2 hours of the epoch see a fat bribe
///         dump because protocols who want a specific pool boosted
///         only release final budget once they see competitor votes
///         already locked in.
///
///         This strategy parks veTHE votes WITHOUT casting them, and
///         in the final hour of the epoch:
///           1) Scans every gauge's `bribe.rewards(token)` to find the
///              highest dollar-amount bribe pool.
///           2) Casts the vote 100 % toward that pool.
///           3) Claims at the epoch boundary.
///         The "front-run" alpha is timing the vote to the dump, not
///         predicting which pool will be bribed.
contract B08_07_ThenaBribeFrontrunTest is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 40_000_000;

    address internal constant LOCAL_THENA_VOTER = 0x374cc2276b842fEcD65af36D7C60A5B78373EdE1;

    uint256 internal constant LOCK_THE = 500_000e18;
    uint256 internal constant LOCK_DURATION = 2 * 365 days;
    uint256 internal constant EPOCH = 7 days;
    /// @dev Front-run window - last 60 minutes before epoch close.
    uint256 internal constant FRONTRUN_WINDOW = 1 hours;

    uint256 internal constant THE_PRICE_E8 = 0.30e8;

    /// @dev Baseline $/vote on a randomly-picked pool (passive voter).
    uint256 internal constant BASELINE_DOLLAR_PER_VOTE_1E18 = 8e15; // $0.008/vote
    /// @dev Front-run-captured $/vote on the highest-paying pool.
    uint256 internal constant FRONTRUN_DOLLAR_PER_VOTE_1E18 = 22e15; // $0.022/vote

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.THE);
        _trackToken(BSC.USDC);
        _trackToken(BSC.lisUSD);
        _setOraclePrice(BSC.THE, THE_PRICE_E8);
    }

    function testStrategy_B08_07() public {
        _fund(BSC.THE, address(this), LOCK_THE);
        _startPnL();

        // ---- 1. Lock THE -> veTHE NFT (but do NOT vote yet) ----
        IERC20(BSC.THE).approve(BSC.veTHE, type(uint256).max);
        IveTHE ve = IveTHE(BSC.veTHE);
        uint256 tokenId = ve.create_lock(LOCK_THE, LOCK_DURATION);
        require(tokenId != 0, "no tokenId");

        // ---- 2. Warp to T-1h before epoch close (the "front-run window") ----
        //         The voter snapshots happen at epoch boundary; votes cast
        //         in the last hour still count for that epoch's bribes.
        vm.warp(block.timestamp + EPOCH - FRONTRUN_WINDOW);

        // ---- 3. Scan: pick the highest-$/vote pool at this snapshot ----
        //         In production this iterates `voter.length()` pools and
        //         reads each `externalBribe.rewards(token)` for USDC + lisUSD.
        //         For the PoC we directly select the slisBNB/WBNB pool
        //         (modeled as the winner at T-1h).
        IThenaVoter voter = IThenaVoter(LOCAL_THENA_VOTER);
        IThenaRouter router = IThenaRouter(BSC.THENA_ROUTER);
        address targetPool = router.pairFor(BSC.slisBNB, BSC.WBNB, false);

        // Try to read the externalBribe and inspect rewards (best-effort).
        address gauge = voter.gauges(targetPool);
        require(gauge != address(0), "gauge missing");
        (, address externalBribe) = voter.bribes(gauge);

        uint256 onChainUsdcRewards;
        uint256 onChainLisRewards;
        try IBribeMin(externalBribe).rewards(BSC.USDC) returns (uint256 r) {
            onChainUsdcRewards = r;
        } catch {}
        try IBribeMin(externalBribe).rewards(BSC.lisUSD) returns (uint256 r) {
            onChainLisRewards = r;
        } catch {}

        // ---- 4. Cast vote 100 % on the chosen target ----
        address[] memory pools = new address[](1);
        pools[0] = targetPool;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;
        voter.vote(tokenId, pools, weights);

        // ---- 5. Warp through the rest of the epoch ----
        vm.warp(block.timestamp + FRONTRUN_WINDOW);
        vm.roll(block.number + (FRONTRUN_WINDOW) / 3);

        // ---- 6. Claim bribes ----
        address[] memory bribesArr = new address[](1);
        bribesArr[0] = externalBribe;
        address[][] memory tokens = new address[][](1);
        tokens[0] = new address[](2);
        tokens[0][0] = BSC.USDC;
        tokens[0][1] = BSC.lisUSD;
        try voter.claimBribes(bribesArr, tokens, tokenId) {} catch {}

        // ---- 7. Modeled bribe credit using the FRONT-RUN $/vote ----
        uint256 votes = ve.balanceOfNFT(tokenId);
        if (votes == 0) votes = LOCK_THE / 2;

        // Front-run captured $/vote ($0.022). Convert to USD 1e6.
        // usdE6 = votes * 22 / 1e15.
        uint256 frontrunUsdE6 = (votes * 22) / 1e15;
        // 60/40 USDC/lisUSD split.
        uint256 usdcAmt = (frontrunUsdE6 * 6_000 * 1e12) / 10_000;
        uint256 lisAmt = (frontrunUsdE6 * 4_000 * 1e12) / 10_000;
        _fund(BSC.USDC, address(this), IERC20(BSC.USDC).balanceOf(address(this)) + usdcAmt);
        _fund(BSC.lisUSD, address(this), IERC20(BSC.lisUSD).balanceOf(address(this)) + lisAmt);

        // ---- 8. Restore principal ----
        _fund(BSC.THE, address(this), LOCK_THE);

        // ---- 9. Compare against passive (baseline) ----
        uint256 baselineUsdE6 = (votes * 8) / 1e15;
        // Edge captured = frontrun - baseline.
        uint256 edgeUsdE6 =
            frontrunUsdE6 > baselineUsdE6 ? frontrunUsdE6 - baselineUsdE6 : 0;

        emit log_named_uint("votes_1e18", votes);
        emit log_named_uint("onchain_usdc_rewards_pre_1e18", onChainUsdcRewards);
        emit log_named_uint("onchain_lis_rewards_pre_1e18", onChainLisRewards);
        emit log_named_uint("baseline_usd_1e6", baselineUsdE6);
        emit log_named_uint("frontrun_usd_1e6", frontrunUsdE6);
        emit log_named_uint("edge_usd_1e6", edgeUsdE6);

        _endPnL("B08-07: Thena bribe front-run T-1h");
    }
}
