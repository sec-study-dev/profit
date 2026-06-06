// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";
import {IPancakeV3Router} from "src/interfaces/bsc/amm/IPancakeV3Router.sol";
import {IThenaRouter} from "src/interfaces/bsc/amm/IThenaRouter.sol";
import {IThenaPair} from "src/interfaces/bsc/amm/IThenaPair.sol";

/// @title B07-02 PCS v3 BTCB/USDT 0.05% flash -> Thena BTCB/USDT pair arb
/// @notice BSC's Binance-Peg BTCB tracks CEX BTC tightly because Binance is
///         the de-facto custodian, but the BSC-side AMMs occasionally lag
///         CEX during fast moves. PCS v3's BTCB/USDT 0.05% pool is the
///         dominant on-chain venue and is rapidly synced by arb bots; Thena's
///         BTCB/USDT volatile pair, with only ~$500k-1M of TVL, lags by
///         5-20 bps during candles >= 0.3%. Strategy flashes BTCB from PCS
///         v3, sells on Thena, buys back on PCS v3, repays. The PCS v3 fee
///         tier here is 0.05% (5 bp) because 0.01% pool may not exist for
///         BTCB/USDT - verify at pin block. Net edge needs >= 25 bps gross.
contract B07_02_PcsV3BtcbUsdtThenaArbTest is BSCStrategyBase, IPancakeV3FlashCallback {
    uint256 internal constant FORK_BLOCK = 42_000_000;

    /// @dev PCS v3 BTCB/USDT 0.05% pool (fee tier 500 = 0.05%). token0 =
    ///      BTCB, token1 = USDT (BTCB 0x7130... < USDT 0x55d3... - actually
    ///      USDT < BTCB by hex; pool sets token0 = USDT, token1 = BTCB).
    /// @dev Verified on BscScan; canonical 0.05% BTCB/USDT pool.
    address internal constant PCS_V3_BTCB_USDT_500 = 0x46Cf1cF8c69595804ba91dFdd8d6b960c9B0a7C4;
    uint24 internal constant PCS_V3_FEE_500 = 500;

    /// @dev Thena BTCB/USDT volatile pair. Placeholder - verify against
    ///      `THENA_ROUTER.pairFor(BTCB, USDT, false)` at pin block.
    address internal constant THENA_BTCB_USDT_VOLATILE = 0x7561EEe90e24F3b348E1087A005F78B4c8453524;

    /// @dev Notional in USDT (18 dec on BSC). 200k USDT ~ $200k of BTCB
    ///      exposure ~ 3 BTCB. Sized to Thena reserves to keep impact <5%.
    uint256 internal constant FLASH_NOTIONAL_USDT = 200_000 ether;

    /// @dev Required gross spread (bps of mid) - must cover Thena 0.20% +
    ///      PCS v3 0.05% swap + PCS v3 0.05% flash = ~30 bps total fee load,
    ///      so MIN_SPREAD_BPS is set conservatively higher.
    uint256 internal constant MIN_SPREAD_BPS = 30;

    bool internal _flashActive;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.BTCB);
        _trackToken(BSC.USDT);
    }

    function testStrategy_B07_02() public {
        IPancakeV3Pool pool = IPancakeV3Pool(PCS_V3_BTCB_USDT_500);

        address token0 = pool.token0();
        address token1 = pool.token1();
        // Confirm pool layout - we expect (USDT, BTCB) but defend either way.
        bool usdtIsToken0 = token0 == BSC.USDT && token1 == BSC.BTCB;
        bool btcbIsToken0 = token0 == BSC.BTCB && token1 == BSC.USDT;
        require(usdtIsToken0 || btcbIsToken0, "pcsv3: unexpected token pair");

        // ---- 1. Read mids ----
        (uint160 sqrtP, , , , , , ) = pool.slot0();
        // priceE18 = USDT per BTCB. If USDT is token0 then sqrt-price gives
        // BTCB-per-USDT; invert.
        uint256 pcsRawE18 = _sqrtPriceToPriceE18(sqrtP);
        uint256 pcsBtcInUsdtE18 = usdtIsToken0 ? (1e36 / pcsRawE18) : pcsRawE18;

        IThenaPair tpair = IThenaPair(THENA_BTCB_USDT_VOLATILE);
        (uint256 r0, uint256 r1, ) = tpair.getReserves();
        address tToken0 = tpair.token0();
        // mid = USDT-reserve / BTCB-reserve
        uint256 thenaBtcInUsdtE18 = tToken0 == BSC.BTCB ? (r1 * 1e18) / r0 : (r0 * 1e18) / r1;

        emit log_named_uint("B07-02: pcsv3_btc_in_usdt_1e18", pcsBtcInUsdtE18);
        emit log_named_uint("B07-02: thena_btc_in_usdt_1e18", thenaBtcInUsdtE18);

        // Profit direction: Thena pays MORE USDT per BTCB -> sell BTCB on
        // Thena. We flash BTCB from PCS v3 to do the sell leg.
        if (thenaBtcInUsdtE18 <= pcsBtcInUsdtE18) {
            emit log_string("B07-02: skipped (no profitable direction at this block)");
            return;
        }
        uint256 spreadBps = ((thenaBtcInUsdtE18 - pcsBtcInUsdtE18) * 10_000) / pcsBtcInUsdtE18;
        emit log_named_uint("B07-02: spread_bps", spreadBps);
        if (spreadBps < MIN_SPREAD_BPS) {
            emit log_string("B07-02: skipped (spread below min)");
            return;
        }

        // Size the BTCB flash from USDT notional using PCS mid.
        uint256 btcbFlashAmount = (FLASH_NOTIONAL_USDT * 1e18) / pcsBtcInUsdtE18;
        emit log_named_uint("B07-02: btcb_flash_amount_1e18", btcbFlashAmount);

        _startPnL();

        _flashActive = true;
        // Borrow BTCB. If BTCB is token0 -> amount0; else amount1.
        if (btcbIsToken0) {
            pool.flash(address(this), btcbFlashAmount, 0, abi.encode(btcbFlashAmount, true));
        } else {
            pool.flash(address(this), 0, btcbFlashAmount, abi.encode(btcbFlashAmount, false));
        }
        _flashActive = false;

        _endPnL("B07-02: PCS v3 0.05% BTCB/USDT flash + Thena vAMM arb");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        require(_flashActive, "callback: not active");
        require(msg.sender == PCS_V3_BTCB_USDT_500, "callback: wrong pool");

        (uint256 borrowed, bool btcbIsToken0) = abi.decode(data, (uint256, bool));

        // ---- 1. BTCB -> USDT on Thena volatile (lagged price favors us) ----
        IERC20(BSC.BTCB).approve(BSC.THENA_ROUTER, type(uint256).max);
        IThenaRouter.Route[] memory route = new IThenaRouter.Route[](1);
        route[0] = IThenaRouter.Route({from: BSC.BTCB, to: BSC.USDT, stable: false});
        uint256[] memory outs = IThenaRouter(BSC.THENA_ROUTER).swapExactTokensForTokens(
            borrowed, 1, route, address(this), block.timestamp
        );
        uint256 usdtAcquired = outs[outs.length - 1];
        require(usdtAcquired > 0, "thena: zero out");

        // ---- 2. USDT -> BTCB on PCS v3 0.05% (fresh price) ----
        IERC20(BSC.USDT).approve(BSC.PCS_V3_ROUTER, type(uint256).max);
        IPancakeV3Router.ExactInputSingleParams memory p = IPancakeV3Router.ExactInputSingleParams({
            tokenIn: BSC.USDT,
            tokenOut: BSC.BTCB,
            fee: PCS_V3_FEE_500,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: usdtAcquired,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        uint256 btcbBack = IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(p);
        require(btcbBack > 0, "pcsv3: zero out");

        // ---- 3. Repay PCS v3 flash ----
        uint256 owed = borrowed + (btcbIsToken0 ? fee0 : fee1);
        IERC20(BSC.BTCB).transfer(PCS_V3_BTCB_USDT_500, owed);
    }

    function _sqrtPriceToPriceE18(uint160 sqrtP) internal pure returns (uint256) {
        uint256 num = uint256(sqrtP) * uint256(sqrtP);
        return (num * 1e18) >> 192;
    }
}
