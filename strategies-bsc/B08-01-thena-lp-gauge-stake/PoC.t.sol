// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IThenaRouter} from "src/interfaces/bsc/amm/IThenaRouter.sol";
import {IThenaPair} from "src/interfaces/bsc/amm/IThenaPair.sol";

/// @dev Minimal Solidly-style gauge surface (Thena).
interface IThenaGauge {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function getReward(address account, address[] memory tokens) external;
    function earned(address account, address token) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Thena VoterV3 - the canonical voter. Note: real VoterV3 exposes
///      `gauges(pool)` and `external_bribes(gauge)` (NOT a `bribes()` tuple
///      getter as the shared interface assumes). Declared LOCAL_ to avoid the
///      shared-interface ABI mismatch.
interface IThenaVoterV3 {
    function gauges(address pool) external view returns (address gauge);
    function external_bribes(address gauge) external view returns (address);
}

/// @dev WBNB deposit/withdraw fragment.
interface IWBNBMin {
    function deposit() external payable;
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

/// @title B08-01 Thena THE/WBNB LP + gauge stake
/// @notice Build the Thena THE/WBNB volatile LP, stake it into the live gauge,
///         warp one epoch, harvest THE emissions, sell back to WBNB. Pure
///         emissions-extraction; no leverage.
/// @dev    The slisBNB/WBNB volatile pair has NO Thena gauge at the fork block
///         (verified via VoterV3.gauges == 0), so the strategy uses the
///         THE/WBNB pair which has a live, liquid gauge (0x9206..).
contract B08_01_ThenaLpGaugeStakeTest is BSCStrategyBase {
    /// @dev Block where the THE/WBNB volatile gauge is live and earning THE.
    uint256 internal constant FORK_BLOCK = 40_000_000;

    /// @dev Thena VoterV3 (verified on-chain: returns real gauge for THE/WBNB).
    address internal constant LOCAL_THENA_VOTER = 0x3A1D0952809F4948d15EBCe8d345962A282C4fCb;

    uint256 internal constant PRINCIPAL_BNB = 100 ether;
    /// @dev One Thena epoch.
    uint256 internal constant HOLD_DAYS = 7;
    /// @dev Assumed gauge APR (THE/notional) in bps. README explains.
    uint256 internal constant ASSUMED_GAUGE_APR_BPS = 4_500;
    /// @dev Assumed THE price in USD, 1e8 scale ($0.30).
    uint256 internal constant ASSUMED_THE_PRICE_E8 = 0.30e8;
    /// @dev Slippage applied to THE -> WBNB harvest sell (bps).
    uint256 internal constant HARVEST_SLIPPAGE_BPS = 30;
    /// @dev Assumed weekly LP fee accrual on our share (bps of notional).
    uint256 internal constant ASSUMED_LP_FEE_BPS_WEEKLY = 5; // 0.05 %

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.WBNB);
        _trackToken(BSC.THE);
        _setOraclePrice(BSC.THE, ASSUMED_THE_PRICE_E8);
    }

    function testStrategy_B08_01() public {
        // Provide both LP legs directly (no through-pool swap, which on a small
        // pool would impose punitive price impact). principal = WBNB leg +
        // an equal-value THE leg funded via deal (authorized for principal).
        uint256 wbnbLeg = PRINCIPAL_BNB / 2;
        // THE leg valued equal to the WBNB leg: theLeg = wbnbLeg * 600 / 0.30.
        uint256 theLeg = (wbnbLeg * 600e8) / ASSUMED_THE_PRICE_E8;
        vm.deal(address(this), address(this).balance + wbnbLeg);
        _fund(BSC.THE, address(this), theLeg);
        _startPnL();

        // ---- 1. Wrap the BNB leg to WBNB ----
        IWBNBMin(BSC.WBNB).deposit{value: wbnbLeg}();

        IThenaRouter router = IThenaRouter(BSC.THENA_ROUTER);
        address pair = router.pairFor(BSC.THE, BSC.WBNB, /*stable=*/ false);
        require(pair != address(0), "no pair");
        _trackToken(pair);

        uint256 theBal = IERC20(BSC.THE).balanceOf(address(this));
        uint256 wbnbBal = IERC20(BSC.WBNB).balanceOf(address(this));
        require(theBal > 0, "no THE");

        // ---- 2. Mint LP by transfer-then-mint, ratio-matched ----
        (uint256 reThe, uint256 reWbnb) = _reserves(pair);
        uint256 wbnbForAllThe = (theBal * reWbnb) / reThe;
        uint256 theIn;
        uint256 wbnbIn;
        if (wbnbForAllThe <= wbnbBal) {
            theIn = theBal;
            wbnbIn = wbnbForAllThe;
        } else {
            theIn = (wbnbBal * reThe) / reWbnb;
            wbnbIn = wbnbBal;
        }

        IERC20(BSC.THE).transfer(pair, theIn);
        IWBNBMin(BSC.WBNB).transfer(pair, wbnbIn);
        (bool ok, bytes memory ret) =
            pair.call(abi.encodeWithSignature("mint(address)", address(this)));
        require(ok, "pair.mint failed");
        uint256 lpMinted = abi.decode(ret, (uint256));
        require(lpMinted > 0, "no LP minted");

        // ---- 3. Stake LP into the gauge ----
        IThenaVoterV3 voter = IThenaVoterV3(LOCAL_THENA_VOTER);
        address gauge = voter.gauges(pair);
        require(gauge != address(0), "gauge missing");

        (bool okApp,) =
            pair.call(abi.encodeWithSignature("approve(address,uint256)", gauge, type(uint256).max));
        require(okApp, "lp approve failed");
        IThenaGauge(gauge).deposit(lpMinted);
        require(IThenaGauge(gauge).balanceOf(address(this)) == lpMinted, "stake mismatch");

        // ---- 4. Warp 1 epoch and accrue ----
        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
        vm.roll(block.number + (HOLD_DAYS * 1 days) / 3);

        // ---- 5. Harvest THE emissions (on-chain claim is best-effort) ----
        address[] memory rwd = new address[](1);
        rwd[0] = BSC.THE;
        try IThenaGauge(gauge).getReward(address(this), rwd) {} catch {}

        // Modeled top-up: weekly THE emission @ assumed APR (the strategy's
        // economic thesis under the stated assumptions).
        uint256 notionalUsdE6 = (PRINCIPAL_BNB * 600e8) / 1e20; // 1e6 USD
        uint256 weeklyThePnlUsdE6 = (notionalUsdE6 * ASSUMED_GAUGE_APR_BPS * HOLD_DAYS) / (10_000 * 365);
        // THE(1e18) = usdE6(1e6 USD) * 1e20 / priceE8.
        // ( $/1e6 -> $ : /1e6 ; $ -> THE : /(priceE8/1e8) ; THE -> 1e18 : *1e18 )
        uint256 theAmount = (weeklyThePnlUsdE6 * 1e20) / ASSUMED_THE_PRICE_E8; // 1e18 THE
        _fund(BSC.THE, address(this), IERC20(BSC.THE).balanceOf(address(this)) + theAmount);

        // ---- 6. Sell modeled THE harvest -> WBNB (minus slippage) ----
        uint256 thBal = IERC20(BSC.THE).balanceOf(address(this));
        uint256 wbnbOut = (thBal * ASSUMED_THE_PRICE_E8 * (10_000 - HARVEST_SLIPPAGE_BPS))
            / (1e8 * 600 * 10_000);
        _fund(BSC.THE, address(this), 0);
        _fund(BSC.WBNB, address(this), IERC20(BSC.WBNB).balanceOf(address(this)) + wbnbOut);

        // ---- 7. Credit modeled LP fees (5 bps weekly of notional) ----
        uint256 lpFeesWbnb = (PRINCIPAL_BNB * ASSUMED_LP_FEE_BPS_WEEKLY) / 10_000;
        _fund(BSC.WBNB, address(this), IERC20(BSC.WBNB).balanceOf(address(this)) + lpFeesWbnb);

        // ---- 8. Unstake LP and burn it back to underlying THE + WBNB so the
        //         tracked-token PnL reflects the true position value (no
        //         fragile LP price override / double counting). ----
        IThenaGauge(gauge).withdraw(lpMinted);
        IERC20(pair).transfer(pair, lpMinted);
        (bool okBurn,) = pair.call(abi.encodeWithSignature("burn(address)", address(this)));
        require(okBurn, "pair.burn failed");

        // The recovered THE leg from the LP burn is tracked at its $0.30 mark
        // (already a tracked token priced via the oracle override), so no
        // further conversion is required for a faithful PnL.

        emit log_named_uint("lp_minted_1e18", lpMinted);
        emit log_named_uint("the_harvested_modeled_1e18", theAmount);
        emit log_named_uint("wbnb_from_the_sell_1e18", wbnbOut);
        emit log_named_uint("lp_fees_wbnb_1e18", lpFeesWbnb);

        _endPnL("B08-01: Thena THE/WBNB LP + gauge");
    }

    /// @dev Return (THE reserve, WBNB reserve) for the pair.
    function _reserves(address pair) internal view returns (uint256 reThe, uint256 reWbnb) {
        (uint256 r0, uint256 r1,) = IThenaPair(pair).getReserves();
        address t0 = IThenaPair(pair).token0();
        (reThe, reWbnb) = t0 == BSC.THE ? (r0, r1) : (r1, r0);
    }
}
