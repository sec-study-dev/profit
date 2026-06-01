// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";
import {IPancakeV3Router} from "src/interfaces/bsc/amm/IPancakeV3Router.sol";
import {IThenaRouter} from "src/interfaces/bsc/amm/IThenaRouter.sol";
import {IThenaPair} from "src/interfaces/bsc/amm/IThenaPair.sol";

/// @title B07-03 PCS v3 CAKE/WBNB 0.25% flash → Thena CAKE/BNB pair arb
/// @notice CAKE is PancakeSwap's governance token; its price discovery is
///         dominated by PCS itself (v2 + v3 pools, plus the StableSwap
///         CAKE/WBNB tier) — but Thena's CAKE/BNB pair exists for veTHE
///         bribes and is often stale by 20–80 bps because Thena's CAKE LPs
///         farm THE emissions, not arb. PCS v3's CAKE/WBNB 0.25% pool is
///         the canonical 25-bp tier for mid-tail tokens; we flash CAKE
///         here and round-trip through Thena. Higher fee tier than B07-01
///         means the required spread is larger.
contract B07_03_PcsV3CakeWbnbThenaArbTest is BSCStrategyBase, IPancakeV3FlashCallback {
    uint256 internal constant FORK_BLOCK = 42_000_000;

    /// @dev PCS v3 CAKE/WBNB 0.25% pool (fee tier 2500 = 0.25%). token0 =
    ///      CAKE 0x0E09... < token1 = WBNB 0xbb4C... lexicographically.
    /// @dev Verified on BscScan; canonical 25-bp CAKE/WBNB v3 pool.
    address internal constant PCS_V3_CAKE_WBNB_2500 = 0x133B3D95bAD5405d14d53473671200e9342896BF;
    uint24 internal constant PCS_V3_FEE_2500 = 2500;

    /// @dev Thena CAKE/WBNB volatile pair (Solidly). Placeholder — Wave 3
    ///      verify via `Router.pairFor(CAKE, WBNB, false)`.
    address internal constant THENA_CAKE_WBNB_VOLATILE = 0xA5c6Cd0e73DA9F1ee0AE6e8b3Ad0ee0bf6BB7666;

    /// @dev Flash CAKE notional (1e18). 100k CAKE ≈ $250k @ $2.50/CAKE.
    uint256 internal constant FLASH_NOTIONAL_CAKE = 100_000 ether;

    /// @dev Required spread (bps of mid). Total fee load is ~95 bps
    ///      (0.20% Thena + 0.25% PCS swap + 0.25% PCS flash + slip).
    uint256 internal constant MIN_SPREAD_BPS = 100;

    bool internal _flashActive;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.CAKE);
        _trackToken(BSC.WBNB);
    }

    function testStrategy_B07_03() public {
        IPancakeV3Pool pool = IPancakeV3Pool(PCS_V3_CAKE_WBNB_2500);

        address token0 = pool.token0();
        address token1 = pool.token1();
        require(token0 == BSC.CAKE && token1 == BSC.WBNB, "pcsv3: unexpected token order");

        // ---- 1. Read mids: WBNB per CAKE (1e18) ----
        (uint160 sqrtP, , , , , , ) = pool.slot0();
        // Both 18-dec, so sqrtPriceX96 → WBNB per CAKE direct.
        uint256 pcsWbnbPerCakeE18 = _sqrtPriceToPriceE18(sqrtP);

        IThenaPair tpair = IThenaPair(THENA_CAKE_WBNB_VOLATILE);
        (uint256 r0, uint256 r1, ) = tpair.getReserves();
        address tToken0 = tpair.token0();
        uint256 thenaWbnbPerCakeE18 = tToken0 == BSC.CAKE ? (r1 * 1e18) / r0 : (r0 * 1e18) / r1;

        emit log_named_uint("B07-03: pcsv3_wbnb_per_cake_1e18", pcsWbnbPerCakeE18);
        emit log_named_uint("B07-03: thena_wbnb_per_cake_1e18", thenaWbnbPerCakeE18);

        // Profit direction: Thena pays MORE WBNB per CAKE → sell CAKE on Thena.
        if (thenaWbnbPerCakeE18 <= pcsWbnbPerCakeE18) {
            emit log_string("B07-03: skipped (no profitable direction at this block)");
            return;
        }
        uint256 spreadBps = ((thenaWbnbPerCakeE18 - pcsWbnbPerCakeE18) * 10_000) / pcsWbnbPerCakeE18;
        emit log_named_uint("B07-03: spread_bps", spreadBps);
        if (spreadBps < MIN_SPREAD_BPS) {
            emit log_string("B07-03: skipped (spread below min)");
            return;
        }

        _startPnL();

        _flashActive = true;
        // Borrow CAKE (token0). amount0 = N, amount1 = 0.
        pool.flash(address(this), FLASH_NOTIONAL_CAKE, 0, "");
        _flashActive = false;

        _endPnL("B07-03: PCS v3 0.25% CAKE/WBNB flash + Thena vAMM arb");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 /* fee1 */, bytes calldata /* data */) external override {
        require(_flashActive, "callback: not active");
        require(msg.sender == PCS_V3_CAKE_WBNB_2500, "callback: wrong pool");

        // ---- 1. CAKE -> WBNB on Thena volatile (lagged price favors us) ----
        IERC20(BSC.CAKE).approve(BSC.THENA_ROUTER, type(uint256).max);
        IThenaRouter.Route[] memory route = new IThenaRouter.Route[](1);
        route[0] = IThenaRouter.Route({from: BSC.CAKE, to: BSC.WBNB, stable: false});
        uint256[] memory outs = IThenaRouter(BSC.THENA_ROUTER).swapExactTokensForTokens(
            FLASH_NOTIONAL_CAKE, 1, route, address(this), block.timestamp
        );
        uint256 wbnbAcquired = outs[outs.length - 1];
        require(wbnbAcquired > 0, "thena: zero out");

        // ---- 2. WBNB -> CAKE on PCS v3 0.25% (fresh price) ----
        IERC20(BSC.WBNB).approve(BSC.PCS_V3_ROUTER, type(uint256).max);
        IPancakeV3Router.ExactInputSingleParams memory p = IPancakeV3Router.ExactInputSingleParams({
            tokenIn: BSC.WBNB,
            tokenOut: BSC.CAKE,
            fee: PCS_V3_FEE_2500,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: wbnbAcquired,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        uint256 cakeBack = IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(p);
        require(cakeBack > 0, "pcsv3: zero out");

        // ---- 3. Repay PCS v3 flash (CAKE = token0) ----
        IERC20(BSC.CAKE).transfer(PCS_V3_CAKE_WBNB_2500, FLASH_NOTIONAL_CAKE + fee0);
    }

    function _sqrtPriceToPriceE18(uint160 sqrtP) internal pure returns (uint256) {
        uint256 num = uint256(sqrtP) * uint256(sqrtP);
        return (num * 1e18) >> 192;
    }
}
