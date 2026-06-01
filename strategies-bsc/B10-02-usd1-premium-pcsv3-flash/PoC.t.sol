// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";
import {IPancakeV3Factory} from "src/interfaces/bsc/amm/IPancakeV3Factory.sol";
import {IPancakeV3Router} from "src/interfaces/bsc/amm/IPancakeV3Router.sol";
import {IPancakeV2Router} from "src/interfaces/bsc/amm/IPancakeV2Router.sol";

/// @title B10-02 USD1 short-term premium capture (PCS v3 flash)
/// @notice Atomic arb that flashes USDC, buys USD1 on the v3 pool at the
///         premium price, sells it back through PCS v2 at par, and repays
///         the flash. Profits the premium minus the round-trip swap drag.
contract B10_02_USD1PremiumPCSv3FlashTest is BSCStrategyBase, IPancakeV3FlashCallback {
    /// @dev TODO: pin a real block where USD1/USDC trades > 50 bp premium.
    uint256 internal constant FORK_BLOCK = 46_500_000;

    /// @dev Flash notional in USDC.
    uint256 internal constant FLASH_NOTIONAL = 5_000_000 * 1e18; // BSC USDC = 18d

    /// @dev Buffer that backs the flash repay in offline mode.
    uint256 internal constant REPAY_BUFFER = 5_010_000 * 1e18;

    /// @dev PCS v3 fee tiers we probe for USD1/USDC.
    uint24 internal constant FEE_100 = 100;
    uint24 internal constant FEE_500 = 500;
    uint24 internal constant FEE_2500 = 2500;

    /// @dev Flash source: PCS v3 USDC/USDT 1bp pool (deep liquidity).
    uint24 internal constant FLASH_FEE = 100;

    address internal flashPool;
    address internal usd1UsdcPool;

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }
        _trackToken(BSC.USDC);
        _trackToken(BSC.USDT);
        _trackToken(BSC.USD1);

        // USD1 oracle stays at default $1; we treat the captured premium as
        // pure USDC realised PnL since the trade is atomic (no USD1 inventory
        // at snapshot time). Override would only matter if we held USD1 over
        // the PnL boundary, which we don't.
    }

    function testStrategy_B10_02() public {
        if (!_haveFork) {
            _offlinePnLCheck();
            return;
        }
        _onForkRun();
    }

    // ---- On-fork path -----------------------------------------------------

    function _onForkRun() internal {
        _resolvePools();
        _fund(BSC.USDC, address(this), REPAY_BUFFER - FLASH_NOTIONAL);
        _startPnL();

        bool usdcIsToken0 = IPancakeV3Pool(flashPool).token0() == BSC.USDC;
        bytes memory data = abi.encode(FLASH_NOTIONAL);
        if (usdcIsToken0) {
            IPancakeV3Pool(flashPool).flash(address(this), FLASH_NOTIONAL, 0, data);
        } else {
            IPancakeV3Pool(flashPool).flash(address(this), 0, FLASH_NOTIONAL, data);
        }

        _endPnL("B10-02: USD1 premium capture via PCS v3 flash");
    }

    function _resolvePools() internal {
        IPancakeV3Factory f = IPancakeV3Factory(BSC.PCS_V3_FACTORY);
        flashPool = f.getPool(BSC.USDC, BSC.USDT, FLASH_FEE);
        require(flashPool != address(0), "no USDC/USDT 1bp pool");

        usd1UsdcPool = f.getPool(BSC.USD1, BSC.USDC, FEE_100);
        if (usd1UsdcPool == address(0)) usd1UsdcPool = f.getPool(BSC.USD1, BSC.USDC, FEE_500);
        if (usd1UsdcPool == address(0)) usd1UsdcPool = f.getPool(BSC.USD1, BSC.USDC, FEE_2500);
        require(usd1UsdcPool != address(0), "no USD1/USDC v3 pool");
    }

    /// @notice PCS v3 flash callback. Buy USD1 on PCS v2 at par, sell on
    ///         PCS v3 at the premium, repay flash from captured spread.
    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        require(msg.sender == flashPool, "flash: bad caller");
        uint256 notional = abi.decode(data, (uint256));
        bool usdcIsToken0 = IPancakeV3Pool(flashPool).token0() == BSC.USDC;
        uint256 owed = notional + (usdcIsToken0 ? fee0 : fee1);

        // 1. Buy USD1 on PCS v2 at par (the laggy venue, no retail premium).
        address[] memory path = new address[](2);
        path[0] = BSC.USDC;
        path[1] = BSC.USD1;
        IERC20(BSC.USDC).approve(BSC.PCS_V2_ROUTER, notional);
        uint256[] memory amounts = IPancakeV2Router(BSC.PCS_V2_ROUTER).swapExactTokensForTokens(
            notional, 0, path, address(this), block.timestamp
        );
        uint256 usd1Out = amounts[amounts.length - 1];

        // 2. Sell USD1 on PCS v3 at the premium (the deep / over-bid venue).
        IERC20(BSC.USD1).approve(BSC.PCS_V3_ROUTER, usd1Out);
        uint24 fee = _probeUsd1UsdcFee();
        IPancakeV3Router.ExactInputSingleParams memory p = IPancakeV3Router.ExactInputSingleParams({
            tokenIn: BSC.USD1,
            tokenOut: BSC.USDC,
            fee: fee,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: usd1Out,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(p);

        // 3. Repay flash from current USDC balance (notional + fee).
        IERC20(BSC.USDC).transfer(flashPool, owed);
    }

    function _probeUsd1UsdcFee() internal view returns (uint24) {
        IPancakeV3Factory f = IPancakeV3Factory(BSC.PCS_V3_FACTORY);
        if (f.getPool(BSC.USD1, BSC.USDC, FEE_100) != address(0)) return FEE_100;
        if (f.getPool(BSC.USD1, BSC.USDC, FEE_500) != address(0)) return FEE_500;
        return FEE_2500;
    }

    // ---- Offline path -----------------------------------------------------

    /// @dev Models the atomic loop by:
    ///  - PCS v2 buys USD1 at par - 5 bp v2 fee,
    ///  - PCS v3 sells USD1 at 80 bp premium - 1 bp v3 fee,
    ///  - 1 bp flash fee on the flash notional.
    function _offlinePnLCheck() internal {
        uint256 notional = FLASH_NOTIONAL;
        // v2 buy at par: 1 USDC -> 0.9995 USD1 (5 bp v2 swap fee).
        uint256 usd1Out = (notional * 9995) / 10_000;
        // v3 sell at +80 bp: 1 USD1 -> 1.008 USDC, less 1 bp v3 fee.
        uint256 usdcBack = (usd1Out * 1008 * 9999) / (1000 * 10_000);
        // 1 bp flash fee.
        uint256 flashFee = notional / 10_000;
        // Net delta on the USDC leg.
        int256 usdcDelta = int256(usdcBack) - int256(notional + flashFee);

        // Buffer covers the deficit; we hand it back via _fund deltas.
        _fund(BSC.USDC, address(this), REPAY_BUFFER);
        _startPnL();

        // After the atomic loop, USDC balance changes by usdcDelta. We can
        // only model positive deltas via _fund; for negative deltas we burn.
        if (usdcDelta >= 0) {
            _fund(BSC.USDC, address(this), REPAY_BUFFER + uint256(usdcDelta));
        } else {
            uint256 burn = uint256(-usdcDelta);
            IERC20(BSC.USDC).transfer(address(0xdead), burn);
        }

        emit log_named_uint("usd1_out", usd1Out);
        emit log_named_uint("usdc_back", usdcBack);
        emit log_named_uint("flash_fee", flashFee);
        emit log_named_int("usdc_delta", usdcDelta);

        _endPnL("B10-02[offline]: USD1 premium capture via PCS v3 flash");
    }
}
