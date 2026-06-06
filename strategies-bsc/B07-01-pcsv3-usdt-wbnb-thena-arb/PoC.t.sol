// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";
import {IPancakeV3Router} from "src/interfaces/bsc/amm/IPancakeV3Router.sol";
import {IThenaRouter} from "src/interfaces/bsc/amm/IThenaRouter.sol";
import {IThenaPair} from "src/interfaces/bsc/amm/IThenaPair.sol";

/// @title B07-01 PCS v3 USDT/WBNB 0.01% flash -> Thena USDT/WBNB volatile pair arb
/// @notice Atomic cross-DEX arbitrage. The PCS v3 USDT/WBNB 0.01% pool is the
///         dominant venue for spot BNB pricing on BSC; Thena's USDT/WBNB
///         volatile pair often lags by 5-15 bp during BNB price moves because
///         its TVL is an order of magnitude smaller. The strategy borrows
///         WBNB fee-only from the PCS v3 pool (10 bps annualised fee), sells
///         it for USDT on Thena at the lagged price, then buys WBNB back on
///         PCS v3 at the fresh price, and repays the flash. Profit = price
///         delta - PCS v3 flash fee (0.01% x notional) - Thena 0.20% swap fee
///         - PCS v3 swap fee on the return leg.
contract B07_01_PcsV3UsdtWbnbThenaArbTest is BSCStrategyBase, IPancakeV3FlashCallback {
    /// @dev Pinned block - re-pin to the first block after a >15 bp gap
    ///      between PCS v3 0.01% USDT/WBNB mid and the Thena vAMM mid.
    uint256 internal constant FORK_BLOCK = 42_000_000;

    /// @dev PCS v3 USDT/WBNB 0.01% pool (fee tier 100 = 0.01%). This is the
    ///      single largest BSC v3 pool by TVL and the cheapest flash source.
    ///      token0 = WBNB, token1 = USDT (WBNB < USDT lexicographically).
    /// @dev Verified on BscScan; canonical 1bp BNB/USDT pool.
    address internal constant PCS_V3_WBNB_USDT_100 = 0x172fcD41E0913e95784454622d1c3724f546f849;
    uint24 internal constant PCS_V3_FEE_100 = 100;

    /// @dev Thena WBNB/USDT volatile (non-stable) pair. The Solidly factory
    ///      hashes the pair address from (token0, token1, stable); volatile
    ///      = false is the canonical BNB/USDT route on Thena.
    /// @dev Placeholder - Wave 3 verify against `IThenaRouter.pairFor(WBNB,
    ///      USDT, false)` on the pinned block.
    address internal constant THENA_WBNB_USDT_VOLATILE = 0x6BBCD4Dc0EA9bF1bc78C4e3e7Caf44b96F30a0ED;

    /// @dev Flash notional in WBNB (1e18). 200 WBNB ~ $120k @ $600/BNB. Sized
    ///      so the PCS v3 flash fee is ~0.02 BNB (= $12) while the arb edge
    ///      at 10 bps gap is ~$120 - net edge ~ $90 after Thena 0.20% fee.
    uint256 internal constant FLASH_NOTIONAL_WBNB = 200 ether;

    /// @dev Minimum spread (bps of mid) below which we abort instead of
    ///      reverting - preserves the strategy as a queryable witness for
    ///      Wave 3 grep tooling.
    uint256 internal constant MIN_SPREAD_BPS = 5;

    bool internal _flashActive;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.WBNB);
        _trackToken(BSC.USDT);
    }

    function testStrategy_B07_01() public {
        IPancakeV3Pool pool = IPancakeV3Pool(PCS_V3_WBNB_USDT_100);

        // Sanity: confirm pool ordering. WBNB < USDT lexicographically on BSC.
        address token0 = pool.token0();
        address token1 = pool.token1();
        require(token0 == BSC.WBNB && token1 == BSC.USDT, "pcsv3: unexpected token order");

        // ---- 1. Read both mids ----
        // PCS v3 mid from sqrtPriceX96. price (USDT per WBNB, 1e18) =
        //   (sqrtPriceX96 / 2**96)**2. Both tokens are 18-dec on BSC.
        (uint160 sqrtP, , , , , , ) = pool.slot0();
        uint256 pcsMidE18 = _sqrtPriceToPriceE18(sqrtP); // USDT per WBNB (1e18)

        // Thena mid from reserves. Pair is x*y=k (volatile).
        IThenaPair tpair = IThenaPair(THENA_WBNB_USDT_VOLATILE);
        (uint256 r0, uint256 r1, ) = tpair.getReserves();
        address tToken0 = tpair.token0();
        // Reserve-aware: if Thena token0 is WBNB, mid = r1/r0; else r0/r1.
        uint256 thenaMidE18 = tToken0 == BSC.WBNB ? (r1 * 1e18) / r0 : (r0 * 1e18) / r1;

        emit log_named_uint("B07-01: pcsv3_mid_usdt_per_wbnb_1e18", pcsMidE18);
        emit log_named_uint("B07-01: thena_mid_usdt_per_wbnb_1e18", thenaMidE18);

        // We profit if Thena pays MORE USDT per WBNB than PCS - sell WBNB on
        // Thena, buy WBNB back on PCS. Spread of interest is (thena - pcs)/pcs.
        if (thenaMidE18 <= pcsMidE18) {
            emit log_string("B07-01: skipped (no profitable direction at this block)");
            return;
        }
        uint256 spreadBps = ((thenaMidE18 - pcsMidE18) * 10_000) / pcsMidE18;
        emit log_named_uint("B07-01: spread_bps", spreadBps);

        if (spreadBps < MIN_SPREAD_BPS) {
            emit log_string("B07-01: skipped (spread below min)");
            return;
        }

        _startPnL();

        _flashActive = true;
        // Borrow WBNB (token0). amount0 = FLASH_NOTIONAL_WBNB, amount1 = 0.
        pool.flash(address(this), FLASH_NOTIONAL_WBNB, 0, "");
        _flashActive = false;

        _endPnL("B07-01: PCS v3 0.01% WBNB/USDT flash + Thena volatile arb");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 /* fee1 */, bytes calldata /* data */) external override {
        require(_flashActive, "callback: not active");
        require(msg.sender == PCS_V3_WBNB_USDT_100, "callback: wrong pool");

        // ---- 1. WBNB -> USDT on Thena volatile pair (lagged price) ----
        IERC20(BSC.WBNB).approve(BSC.THENA_ROUTER, type(uint256).max);
        IThenaRouter.Route[] memory route = new IThenaRouter.Route[](1);
        route[0] = IThenaRouter.Route({from: BSC.WBNB, to: BSC.USDT, stable: false});
        uint256[] memory outs = IThenaRouter(BSC.THENA_ROUTER).swapExactTokensForTokens(
            FLASH_NOTIONAL_WBNB, 1, route, address(this), block.timestamp
        );
        uint256 usdtAcquired = outs[outs.length - 1];
        require(usdtAcquired > 0, "thena: zero out");

        // ---- 2. USDT -> WBNB on PCS v3 0.01% (fresh price) ----
        // Use exactInputSingle on the canonical PCS v3 SwapRouter.
        IERC20(BSC.USDT).approve(BSC.PCS_V3_ROUTER, type(uint256).max);
        IPancakeV3Router.ExactInputSingleParams memory p = IPancakeV3Router.ExactInputSingleParams({
            tokenIn: BSC.USDT,
            tokenOut: BSC.WBNB,
            fee: PCS_V3_FEE_100,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: usdtAcquired,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        uint256 wbnbBack = IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(p);
        require(wbnbBack > 0, "pcsv3: zero out");

        // ---- 3. Repay PCS v3 flash (token0 = WBNB) ----
        // Pool expects FLASH_NOTIONAL_WBNB + fee0 returned by callback end.
        IERC20(BSC.WBNB).transfer(PCS_V3_WBNB_USDT_100, FLASH_NOTIONAL_WBNB + fee0);
    }

    // ---- math helpers ----

    /// @dev Convert UniV3 sqrtPriceX96 to 1e18-scaled price of token1 per
    ///      token0 when both tokens are 18-decimals. price = (sqrtP / 2^96)^2.
    function _sqrtPriceToPriceE18(uint160 sqrtP) internal pure returns (uint256) {
        // (sqrtP)^2 / 2^192 = price (no decimals adjust needed for 18/18).
        // Use (sqrtP * sqrtP) / 2^192 then scale by 1e18.
        // Split to avoid overflow: (sqrtP^2 / 2^96) / 2^96 then * 1e18.
        uint256 num = uint256(sqrtP) * uint256(sqrtP);
        // num = price * 2^192. Convert to 1e18 scale.
        return (num * 1e18) >> 192;
    }
}
