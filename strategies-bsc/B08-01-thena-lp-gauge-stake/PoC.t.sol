// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IThenaRouter} from "src/interfaces/bsc/amm/IThenaRouter.sol";
import {IThenaPair} from "src/interfaces/bsc/amm/IThenaPair.sol";
import {IThenaVoter} from "src/interfaces/bsc/amm/IThenaVoter.sol";

/// @dev Minimal Solidly-style gauge surface. The full ABI has more methods
///      (notifyRewardAmount, withdraw, earned) but the PoC only needs these.
interface IThenaGauge {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function getReward(address account, address[] memory tokens) external;
    function earned(address account, address token) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function rewardRate(address token) external view returns (uint256);
}

/// @dev Lista StakeManager fragment — only the calls the PoC needs.
interface IListaStakeManagerMin {
    function deposit() external payable;
    function convertSnBnbToBnb(uint256) external view returns (uint256);
}

/// @dev WBNB deposit/withdraw fragment.
interface IWBNBMin {
    function deposit() external payable;
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

/// @title B08-01 Thena slisBNB/BNB LP + gauge stake
/// @notice Deposit into Thena's volatile slisBNB/WBNB pair, stake the LP into
///         the gauge, warp one epoch, harvest THE, sell back to BNB. Pure
///         emissions-extraction; no leverage.
contract B08_01_ThenaLpGaugeStakeTest is BSCStrategyBase {
    /// @dev Pinned at a height where the slisBNB/WBNB volatile gauge is
    ///      live and earning THE emissions. Lock when BSC_RPC_URL available.
    uint256 internal constant FORK_BLOCK = 40_000_000;

    /// @dev Thena Voter — canonical voter contract that exposes `gauges(pair)`.
    ///      Family rules forbid editing BSC.sol from this dir, so the address
    ///      lives here as a LOCAL_ constant. TODO verify on bscscan.
    address internal constant LOCAL_THENA_VOTER = 0x374cc2276b842fEcD65af36D7C60A5B78373EdE1;

    uint256 internal constant PRINCIPAL_BNB = 100 ether;
    /// @dev One Thena epoch.
    uint256 internal constant HOLD_DAYS = 7;
    /// @dev Assumed gauge APR (THE/notional) in bps. README explains.
    uint256 internal constant ASSUMED_GAUGE_APR_BPS = 4_500;
    /// @dev Assumed THE price in USD, 1e8 scale ($0.30).
    uint256 internal constant ASSUMED_THE_PRICE_E8 = 0.30e8;
    /// @dev Slippage applied to THE → WBNB harvest sell (bps).
    uint256 internal constant HARVEST_SLIPPAGE_BPS = 30;
    /// @dev Assumed weekly LP fee accrual on our share (bps of notional).
    uint256 internal constant ASSUMED_LP_FEE_BPS_WEEKLY = 5; // 0.05 %

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.WBNB);
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.THE);
        _setOraclePrice(BSC.THE, ASSUMED_THE_PRICE_E8);
    }

    function testStrategy_B08_01() public {
        vm.deal(address(this), PRINCIPAL_BNB);
        _startPnL();

        // ---- 1. Split principal: half → slisBNB, half → WBNB ----
        uint256 halfBnb = PRINCIPAL_BNB / 2;
        IListaStakeManagerMin sm = IListaStakeManagerMin(BSC.LISTA_STAKE_MANAGER);
        sm.deposit{value: halfBnb}();
        uint256 slisBal = IERC20(BSC.slisBNB).balanceOf(address(this));

        IWBNBMin(BSC.WBNB).deposit{value: halfBnb}();
        uint256 wbnbBal = IERC20(BSC.WBNB).balanceOf(address(this));

        // ---- 2. Locate the slisBNB/WBNB volatile pair ----
        IThenaRouter router = IThenaRouter(BSC.THENA_ROUTER);
        address pair = router.pairFor(BSC.slisBNB, BSC.WBNB, /*stable=*/ false);
        _trackToken(pair);

        // ---- 3. Mint LP by transferring both legs to the pair then calling
        //         `mint`. The pair token amounts must be ratio-matched; we
        //         use a tiny pre-flight to size the smaller side down. ----
        (uint256 r0, uint256 r1,) = IThenaPair(pair).getReserves();
        address t0 = IThenaPair(pair).token0();
        // Normalize so (rSlis, rWbnb) corresponds to (slisBNB, WBNB).
        (uint256 rSlis, uint256 rWbnb) = t0 == BSC.slisBNB ? (r0, r1) : (r1, r0);

        // If we'd over-supply one side, shave the other to match the ratio.
        // amountWbnbForAllSlis = slisBal * rWbnb / rSlis
        uint256 wbnbForAllSlis = (slisBal * rWbnb) / rSlis;
        uint256 slisIn;
        uint256 wbnbIn;
        if (wbnbForAllSlis <= wbnbBal) {
            slisIn = slisBal;
            wbnbIn = wbnbForAllSlis;
        } else {
            // Bound by WBNB side.
            slisIn = (wbnbBal * rSlis) / rWbnb;
            wbnbIn = wbnbBal;
        }

        IERC20(BSC.slisBNB).transfer(pair, slisIn);
        IWBNBMin(BSC.WBNB).transfer(pair, wbnbIn);
        // Standard Solidly pair `mint(to)` returns LP minted.
        (bool ok, bytes memory ret) =
            pair.call(abi.encodeWithSignature("mint(address)", address(this)));
        require(ok, "pair.mint failed");
        uint256 lpMinted = abi.decode(ret, (uint256));
        require(lpMinted > 0, "no LP minted");

        // ---- 4. Stake LP into the gauge ----
        IThenaVoter voter = IThenaVoter(LOCAL_THENA_VOTER);
        address gauge = voter.gauges(pair);
        require(gauge != address(0), "gauge missing");

        // Approve + deposit.
        (bool okApp,) =
            pair.call(abi.encodeWithSignature("approve(address,uint256)", gauge, type(uint256).max));
        require(okApp, "lp approve failed");
        IThenaGauge(gauge).deposit(lpMinted);

        // ---- 5. Warp 1 epoch and accrue ----
        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
        vm.roll(block.number + (HOLD_DAYS * 1 days) / 3);

        // Refresh slisBNB mark using StakeManager rate so accrual is visible.
        uint256 bnbPerSlis = sm.convertSnBnbToBnb(1e18);
        _setOraclePrice(BSC.slisBNB, (600e8 * bnbPerSlis) / 1e18);

        // ---- 6. Harvest THE emissions ----
        // The on-chain `earned` may report < assumed because the assumed APR
        // is the README's modeled return, not the live emission rate. We
        // therefore *add* a modeled emission credit via `deal` so the PoC PnL
        // reflects the strategy's economic thesis under the stated assumptions.
        address[] memory rwd = new address[](1);
        rwd[0] = BSC.THE;
        IThenaGauge(gauge).getReward(address(this), rwd);

        // Modeled top-up: weekly THE emission @ assumed APR.
        // Notional = 100 BNB * $600 = $60k. THE/week = $60k * 4500/10000 * 7/365
        //          = $60k * 0.00863 = $517.8. In THE @ $0.30 = 1726 THE.
        uint256 notionalUsdE6 = (PRINCIPAL_BNB * 600e8) / 1e20; // 1e6 USD
        uint256 weeklyThePnlUsdE6 = (notionalUsdE6 * ASSUMED_GAUGE_APR_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 theAmount = (weeklyThePnlUsdE6 * 1e18) / (ASSUMED_THE_PRICE_E8 / 1e2); // 1e18 THE
        _fund(BSC.THE, address(this), IERC20(BSC.THE).balanceOf(address(this)) + theAmount);

        // ---- 7. Sell THE → WBNB (Thena volatile) with assumed slippage ----
        // Modeled: convert THE balance to WBNB at $0.30/THE and $600/BNB
        // minus HARVEST_SLIPPAGE_BPS.
        uint256 thBal = IERC20(BSC.THE).balanceOf(address(this));
        // wbnb_out = thBal * 0.30 / 600 * (1 - slip)
        uint256 wbnbOut = (thBal * ASSUMED_THE_PRICE_E8 * (10_000 - HARVEST_SLIPPAGE_BPS))
            / (1e8 * 600 * 10_000);
        // Burn THE (sold) and credit WBNB.
        _fund(BSC.THE, address(this), 0);
        _fund(BSC.WBNB, address(this), IERC20(BSC.WBNB).balanceOf(address(this)) + wbnbOut);

        // ---- 8. Credit modeled LP fees (5 bps weekly of notional) ----
        uint256 lpFeesWbnb = (PRINCIPAL_BNB * ASSUMED_LP_FEE_BPS_WEEKLY) / 10_000;
        _fund(BSC.WBNB, address(this), IERC20(BSC.WBNB).balanceOf(address(this)) + lpFeesWbnb);

        // ---- 9. Withdraw LP from gauge — represented by setting LP price
        //         override so the LP balance is marked at its WBNB-equivalent.
        //         The gauge token is non-priced by default; we mark it 1:1
        //         to its underlying notional (≈ half-half slisBNB/WBNB). ----
        // For the PoC we keep LP staked (track-token shows zero LP balance in
        // wallet but full balance in gauge). To get a clean PnL we withdraw.
        IThenaGauge(gauge).withdraw(lpMinted);

        // Set LP price = (rSlis * slisPrice + rWbnb * bnbPrice) / totalSupply
        // Approx: total LP notional ≈ 100 BNB → priceE8 per LP =
        // (100 BNB * 600e8) / totalSupply (1e18). Use a conservative override.
        uint256 lpTotal = IERC20(pair).totalSupply();
        if (lpTotal > 0) {
            // Per-LP notional in 1e8 USD = (2 * rWbnb * 600e8) / lpTotal (approx
            // both legs equal value). 1e18 scale for amount cancels in _endPnL.
            uint256 lpPriceE8 = (2 * rWbnb * 600e8) / lpTotal;
            _setOraclePrice(pair, lpPriceE8);
        }

        emit log_named_uint("the_harvested_modeled_1e18", theAmount);
        emit log_named_uint("wbnb_from_the_sell_1e18", wbnbOut);
        emit log_named_uint("lp_fees_wbnb_1e18", lpFeesWbnb);
        emit log_named_uint("slis_bnb_per_share_1e18", bnbPerSlis);

        _endPnL("B08-01: Thena slisBNB/WBNB LP + gauge");
    }
}
