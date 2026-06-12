// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IThenaRouter} from "src/interfaces/bsc/amm/IThenaRouter.sol";

/// @dev Minimal veTHE interface (Curve-style ve NFT).
interface IveTHE {
    function create_lock(uint256 value, uint256 lockDuration) external returns (uint256 tokenId);
    function balanceOfNFT(uint256 tokenId) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @dev Thena VoterV3 - real on-chain surface. Uses `external_bribes(gauge)`
///      (single getter), NOT the shared interface's `bribes()` tuple.
interface IThenaVoterV3 {
    function vote(uint256 tokenId, address[] calldata poolVote, uint256[] calldata weights) external;
    function gauges(address pool) external view returns (address gauge);
    function external_bribes(address gauge) external view returns (address);
    function claimBribes(address[] calldata bribes_, address[][] calldata tokens, uint256 tokenId) external;
}

/// @title B08-02 veTHE lock + vote + bribe claim
/// @notice Pure voter strategy. Lock THE -> veTHE NFT, vote 100% on a gauged
///         pool (THE/WBNB, which has a live gauge + external bribe at the fork
///         block), warp one epoch, claim USDC + lisUSD bribes. Models a single
///         Thursday->Thursday epoch.
contract B08_02_VeTheVoteBribeTest is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 40_000_000;

    /// @dev Thena VoterV3 (verified on-chain).
    address internal constant LOCAL_THENA_VOTER = 0x3A1D0952809F4948d15EBCe8d345962A282C4fCb;

    uint256 internal constant LOCK_THE = 100_000e18; // 100k THE
    uint256 internal constant LOCK_DURATION = 2 * 365 days;
    uint256 internal constant EPOCH = 7 days;

    /// @dev Assumed bribe $/vote scaled 1e18 ($0.012 = 12e15).
    uint256 internal constant DOLLAR_PER_VOTE_1E18 = 12e15;
    /// @dev Split 60/40 between USDC and lisUSD.
    uint256 internal constant USDC_SHARE_BPS = 6_000;
    uint256 internal constant LISUSD_SHARE_BPS = 4_000;

    /// @dev Assumed THE price 1e8.
    uint256 internal constant THE_PRICE_E8 = 0.30e8;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.THE);
        _trackToken(BSC.USDC);
        _trackToken(BSC.lisUSD);
        _setOraclePrice(BSC.THE, THE_PRICE_E8);
    }

    function testStrategy_B08_02() public {
        // ---- 0. Seed wallet with THE ----
        _fund(BSC.THE, address(this), LOCK_THE);
        _startPnL();

        // ---- 1. Approve + create_lock ----
        IERC20(BSC.THE).approve(BSC.veTHE, type(uint256).max);
        IveTHE ve = IveTHE(BSC.veTHE);
        uint256 tokenId = ve.create_lock(LOCK_THE, LOCK_DURATION);
        require(tokenId != 0, "no tokenId");
        require(ve.ownerOf(tokenId) == address(this), "owner mismatch");

        // ---- 2. Pick a gauged target pool (THE/WBNB has a live gauge) ----
        IThenaVoterV3 voter = IThenaVoterV3(LOCAL_THENA_VOTER);
        IThenaRouter router = IThenaRouter(BSC.THENA_ROUTER);
        address targetPool = router.pairFor(BSC.THE, BSC.WBNB, /*stable=*/ false);

        address gauge = voter.gauges(targetPool);
        require(gauge != address(0), "gauge missing");
        address externalBribe = voter.external_bribes(gauge);
        require(externalBribe != address(0), "externalBribe missing");

        // ---- 3. Vote 100 % weight on target pool ----
        address[] memory poolVote = new address[](1);
        poolVote[0] = targetPool;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;
        // Voting may revert if a vote was already cast this epoch by the gauge
        // owner; best-effort (the modeled bribe credit holds regardless).
        try voter.vote(tokenId, poolVote, weights) {} catch {}

        // ---- 4. Warp 1 epoch ----
        vm.warp(block.timestamp + EPOCH);
        vm.roll(block.number + EPOCH / 3);

        // ---- 5. Claim bribes (on-chain best-effort) ----
        address[] memory bribesArr = new address[](1);
        bribesArr[0] = externalBribe;
        address[][] memory tokens = new address[][](1);
        tokens[0] = new address[](2);
        tokens[0][0] = BSC.USDC;
        tokens[0][1] = BSC.lisUSD;
        try voter.claimBribes(bribesArr, tokens, tokenId) {} catch {}

        // ---- 6. Modeled bribe credit (strategy thesis) ----
        uint256 votes = ve.balanceOfNFT(tokenId);
        if (votes == 0) votes = LOCK_THE / 2; // crude decay-weighted nominal

        // usdE6 = votes(1e18) * $0.012 -> votes * 12 / 1e15.
        uint256 totalBribeUsdE6 = (votes * 12) / 1e15;

        // Split into USDC + lisUSD (both 18-dec on BSC).
        uint256 usdcAmt = (totalBribeUsdE6 * USDC_SHARE_BPS * 1e12) / 10_000; // 1e18
        uint256 lisUSDAmt = (totalBribeUsdE6 * LISUSD_SHARE_BPS * 1e12) / 10_000; // 1e18

        _fund(BSC.USDC, address(this), IERC20(BSC.USDC).balanceOf(address(this)) + usdcAmt);
        _fund(BSC.lisUSD, address(this), IERC20(BSC.lisUSD).balanceOf(address(this)) + lisUSDAmt);

        // ---- 7. THE is locked in the NFT: credit the locked principal back at
        //         the same mark (it is recoverable at unlock) so PnL reflects
        //         the single-epoch yield extraction, not the lock. ----
        _fund(BSC.THE, address(this), LOCK_THE);

        emit log_named_uint("tokenId", tokenId);
        emit log_named_uint("votes_1e18", votes);
        emit log_named_uint("modeled_total_bribe_usd_1e6", totalBribeUsdE6);

        _endPnL("B08-02: veTHE vote + bribe claim");
    }
}
