// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";
import {IPancakeV3Router} from "src/interfaces/bsc/amm/IPancakeV3Router.sol";
import {IThenaRouter} from "src/interfaces/bsc/amm/IThenaRouter.sol";
import {IThenaPair} from "src/interfaces/bsc/amm/IThenaPair.sol";

/// @title B07-05 PCS v3 ETH/WBNB 0.05% flash -> Thena ETH/BNB volatile pair arb
/// @notice Binance-Peg ETH (BSC.WETH, 0x2170...) trades on BSC as a cross-rate
///         of ETH/USD against BNB/USD; the on-chain ETH/BNB pair is a
///         secondary market because most flow goes through ETH/USDT or
///         WBNB/USDT independently. PCS v3 hosts the canonical 0.05%
///         ETH/WBNB pool with ~$3-8M TVL; Thena's volatile ETH/BNB pair
///         has ~$0.3-0.8M and lags by 15-60 bps during ETH-relative-to-BNB
///         moves because its LPs farm THE rewards rather than rebalance.
///         The strategy borrows WBNB from the PCS v3 ETH/WBNB 0.05% pool,
///         buys ETH on Thena at the lagged price, sells ETH for WBNB on
///         PCS v3 at the fresh price, repays. Net edge requires >= ~35 bps
///         gross to cover 0.20% Thena + 0.05% PCS swap + 0.05% PCS flash.
/// @dev    Mechanism count: 2 (PCS v3 flash + Thena vAMM). Same shape as
///         B07-01/02/03 but on a cross-rate (ETH/BNB) instead of a quote-
///         token pair, which gives a different mispricing distribution
///         driven by the ETH/BNB ratio rather than absolute BNB price.
contract B07_05_PcsV3EthWbnbThenaArbTest is BSCStrategyBase, IPancakeV3FlashCallback {
    /// @dev Pinned block - Wave 3: re-pin to the first block after an
    ///      ETH/BNB cross-rate move >= 0.5% where Thena pair has not synced.
    uint256 internal constant FORK_BLOCK = 42_000_000;

    /// @dev PCS v3 ETH/WBNB 0.05% pool (fee tier 500). ETH (0x2170...) <
    ///      WBNB (0xbb4C...) lexicographically, so token0 = ETH, token1 = WBNB.
    /// @dev Placeholder - Wave 3 verify via
    ///      `IPancakeV3Factory(BSC.PCS_V3_FACTORY).getPool(ETH, WBNB, 500)`.
    address internal constant PCS_V3_ETH_WBNB_500 = 0x9FCec0d29ad9c9b6C7Dda51Aa2cE1Db5fEDE9777;
    uint24 internal constant PCS_V3_FEE_500 = 500;

    /// @dev Thena ETH/WBNB volatile pair. Placeholder - Wave 3 verify via
    ///      `IThenaRouter.pairFor(BSC.WETH, BSC.WBNB, false)` at pin block.
    address internal constant THENA_ETH_WBNB_VOLATILE = 0x4bBa1018b967e59220B22cA03B68BB1FD72A371C;

    /// @dev Flash notional in WBNB (18 dec). 500 WBNB ~ $300k @ $600/BNB.
    ///      Sized so 0.05% flash fee = 0.25 WBNB ~ $150 and impact on a
    ///      $0.5M Thena pool stays within ~10%.
    uint256 internal constant FLASH_NOTIONAL_WBNB = 500 ether;

    /// @dev Required gross spread (bps) - must cover Thena 0.20% + PCS v3
    ///      0.05% swap + PCS v3 0.05% flash + slip ~ 35 bps.
    uint256 internal constant MIN_SPREAD_BPS = 35;

    bool internal _flashActive;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.WETH);
        _trackToken(BSC.WBNB);
    }

    function testStrategy_B07_05() public {
        IPancakeV3Pool pool = IPancakeV3Pool(PCS_V3_ETH_WBNB_500);

        address token0 = pool.token0();
        address token1 = pool.token1();
        // Accept either ordering. ETH < WBNB by hex, so expected (ETH, WBNB).
        bool ethIsToken0 = token0 == BSC.WETH && token1 == BSC.WBNB;
        bool wbnbIsToken0 = token0 == BSC.WBNB && token1 == BSC.WETH;
        require(ethIsToken0 || wbnbIsToken0, "pcsv3: unexpected token pair");

        // ---- 1. PCS v3 mid: WBNB per ETH (1e18) ----
        (uint160 sqrtP, , , , , , ) = pool.slot0();
        uint256 rawE18 = _sqrtPriceToPriceE18(sqrtP); // token1 per token0
        // If ETH is token0, sqrt-price gives WBNB per ETH directly.
        uint256 pcsWbnbPerEthE18 = ethIsToken0 ? rawE18 : (1e36 / rawE18);

        // ---- 2. Thena mid: WBNB per ETH from reserves ----
        IThenaPair tpair = IThenaPair(THENA_ETH_WBNB_VOLATILE);
        (uint256 r0, uint256 r1, ) = tpair.getReserves();
        address tToken0 = tpair.token0();
        // mid = r_WBNB / r_ETH (both 18-dec).
        uint256 thenaWbnbPerEthE18 = tToken0 == BSC.WETH ? (r1 * 1e18) / r0 : (r0 * 1e18) / r1;

        emit log_named_uint("B07-05: pcsv3_wbnb_per_eth_1e18", pcsWbnbPerEthE18);
        emit log_named_uint("B07-05: thena_wbnb_per_eth_1e18", thenaWbnbPerEthE18);

        // Profit direction: Thena CHARGES LESS WBNB per ETH (cheaper ETH
        // there) -> buy ETH on Thena, sell on PCS v3. Equivalently:
        //   thena_wbnb_per_eth < pcs_wbnb_per_eth.
        if (thenaWbnbPerEthE18 >= pcsWbnbPerEthE18) {
            emit log_string("B07-05: skipped (no profitable direction at this block)");
            return;
        }
        uint256 spreadBps = ((pcsWbnbPerEthE18 - thenaWbnbPerEthE18) * 10_000) / pcsWbnbPerEthE18;
        emit log_named_uint("B07-05: spread_bps", spreadBps);
        if (spreadBps < MIN_SPREAD_BPS) {
            emit log_string("B07-05: skipped (spread below min)");
            return;
        }

        _startPnL();

        _flashActive = true;
        // Borrow WBNB. If WBNB is token1 -> amount1 = N.
        if (wbnbIsToken0) {
            pool.flash(address(this), FLASH_NOTIONAL_WBNB, 0, abi.encode(true));
        } else {
            pool.flash(address(this), 0, FLASH_NOTIONAL_WBNB, abi.encode(false));
        }
        _flashActive = false;

        _endPnL("B07-05: PCS v3 0.05% ETH/WBNB flash + Thena ETH/BNB vAMM arb");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        require(_flashActive, "callback: not active");
        require(msg.sender == PCS_V3_ETH_WBNB_500, "callback: wrong pool");

        bool wbnbIsToken0 = abi.decode(data, (bool));
        uint256 owedFee = wbnbIsToken0 ? fee0 : fee1;

        // ---- 1. WBNB -> ETH on Thena (lagged: cheap ETH side) ----
        IERC20(BSC.WBNB).approve(BSC.THENA_ROUTER, type(uint256).max);
        IThenaRouter.Route[] memory route = new IThenaRouter.Route[](1);
        route[0] = IThenaRouter.Route({from: BSC.WBNB, to: BSC.WETH, stable: false});
        uint256[] memory outs = IThenaRouter(BSC.THENA_ROUTER).swapExactTokensForTokens(
            FLASH_NOTIONAL_WBNB, 1, route, address(this), block.timestamp
        );
        uint256 ethAcquired = outs[outs.length - 1];
        require(ethAcquired > 0, "thena: zero out");

        // ---- 2. ETH -> WBNB on PCS v3 0.05% (fresh price) ----
        IERC20(BSC.WETH).approve(BSC.PCS_V3_ROUTER, type(uint256).max);
        IPancakeV3Router.ExactInputSingleParams memory p = IPancakeV3Router.ExactInputSingleParams({
            tokenIn: BSC.WETH,
            tokenOut: BSC.WBNB,
            fee: PCS_V3_FEE_500,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: ethAcquired,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        uint256 wbnbBack = IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(p);
        require(wbnbBack > 0, "pcsv3: zero out");

        // ---- 3. Repay PCS v3 flash ----
        IERC20(BSC.WBNB).transfer(PCS_V3_ETH_WBNB_500, FLASH_NOTIONAL_WBNB + owedFee);
    }

    function _sqrtPriceToPriceE18(uint160 sqrtP) internal pure returns (uint256) {
        uint256 num = uint256(sqrtP) * uint256(sqrtP);
        return (num * 1e18) >> 192;
    }
}
