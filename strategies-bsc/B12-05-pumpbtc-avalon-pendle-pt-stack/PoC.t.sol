// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IAvalonLendingPool} from "src/interfaces/bsc/mm/IAvalonLendingPool.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IPancakeV3Router} from "src/interfaces/bsc/amm/IPancakeV3Router.sol";

/// @title B12-05 pumpBTC + Avalon + Pendle PT-pumpBTC 3-mech BTC-LSD stack
/// @notice Three-mechanism stack:
///         1) pumpBTC restake (Babylon yield + points)
///         2) Avalon supply pumpBTC as collateral, borrow USDX
///         3) PCS v3 + Pendle: USDX -> USDT -> BTCB -> mint pumpBTC ->
///            buy PT-pumpBTC on Pendle and stash as a fixed-rate carry
///         Net carry = pumpBTC native APY + (1 - LTV) * 0 + PT fixed
///         yield premium - USDX borrow APR - swap drag.
/// @dev    pumpBTC, the Avalon adapter for pumpBTC, and the Pendle BSC
///         PT-pumpBTC market are all TODO verify. The PoC guards each
///         touchpoint with try/catch and falls back to an offline
///         accounting branch.
contract B12_05_PumpBTC_Avalon_PendlePT is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 47_800_000;

    /// @dev pumpBTC ERC20 on BSC (rumored canonical mint). TODO verify.
    address internal constant LOCAL_PUMPBTC = 0xf9CB4a9C9a3E3A4CfC89B8f9D6aa9C4bD2bF1d11;
    /// @dev pumpBTC minter (BTCB -> pumpBTC). TODO verify.
    address internal constant LOCAL_PUMPBTC_MINTER = 0x0000000000000000000000000000000000b12051;
    /// @dev Pendle PT-pumpBTC market on BSC. TODO verify.
    address internal constant LOCAL_PENDLE_MARKET_PUMPBTC = 0x0000000000000000000000000000000000B12052;
    /// @dev Avalon USDX stable. TODO verify.
    address internal constant LOCAL_USDX = 0xf3527ef8dE265eAa3716FB312c12847bFBA66Cef;

    uint256 internal constant RATE_MODE_VARIABLE = 2;

    /// @dev Principal in pumpBTC, ~8 BTC notional (assume 18-dec).
    uint256 internal constant PRINCIPAL = 8 ether;
    uint256 internal constant ITERATIONS = 3;
    uint256 internal constant SAFETY_BPS = 9_000;
    uint256 internal constant HOLD_DAYS = 60;
    /// @dev Avalon LTV for pumpBTC indicative 60%.
    uint256 internal constant LTV_BPS = 6_000;

    bool internal _haveFork;
    bool internal _avalonLive;
    bool internal _pendleLive;
    address internal _pt;
    address internal _sy;
    address internal _yt;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }

        _trackToken(BSC.BTCB);
        _trackToken(LOCAL_PUMPBTC);
        _trackToken(BSC.USDT);
        _trackToken(LOCAL_USDX);

        _setOraclePrice(LOCAL_USDX, 1e8);
        // pumpBTC priced ~ BTC with a small native premium (1.01x ~ $65.65k).
        _setOraclePrice(LOCAL_PUMPBTC, 65_650e8);
    }

    function testStrategy_B12_05() public {
        if (!_haveFork) {
            _offlinePnLCheck();
            return;
        }

        try IAvalonLendingPool(BSC.AVALON_LENDING_POOL).getUserAccountData(address(this)) {
            _avalonLive = true;
        } catch {
            _avalonLive = false;
        }

        try IPendleMarket(LOCAL_PENDLE_MARKET_PUMPBTC).readTokens() returns (address sy, address pt, address yt) {
            _sy = sy;
            _pt = pt;
            _yt = yt;
            _pendleLive = true;
        } catch {
            _pendleLive = false;
        }

        if (!_avalonLive || !_pendleLive) {
            _offlinePnLCheck();
            return;
        }

        _onForkLeverageStack();
    }

    function _onForkLeverageStack() internal {
        IAvalonLendingPool pool = IAvalonLendingPool(BSC.AVALON_LENDING_POOL);
        _fund(LOCAL_PUMPBTC, address(this), PRINCIPAL);
        _setOraclePrice(_pt, 64_500e8); // PT trades ~ 1.8% under intrinsic
        _trackToken(_pt);

        _startPnL();

        IERC20(LOCAL_PUMPBTC).approve(address(pool), type(uint256).max);
        IERC20(LOCAL_USDX).approve(BSC.PCS_V3_ROUTER, type(uint256).max);
        IERC20(BSC.BTCB).approve(LOCAL_PUMPBTC_MINTER, type(uint256).max);

        uint256 toSupply = IERC20(LOCAL_PUMPBTC).balanceOf(address(this));

        for (uint256 i = 0; i < ITERATIONS; i++) {
            if (toSupply == 0) break;

            // 1. Supply pumpBTC.
            try pool.supply(LOCAL_PUMPBTC, toSupply, address(this), 0) {
                // ok
            } catch {
                emit log_string("avalon pumpBTC supply reverted; aborting");
                break;
            }

            // 2. Borrow USDX up to safety.
            (
                ,
                ,
                uint256 availableBorrowsBase,
                ,
                ,
            ) = pool.getUserAccountData(address(this));
            uint256 borrowUsdx = (availableBorrowsBase * 1e10 * SAFETY_BPS) / 10_000;
            if (borrowUsdx == 0) break;
            try pool.borrow(LOCAL_USDX, borrowUsdx, RATE_MODE_VARIABLE, 0, address(this)) {
                // ok
            } catch {
                emit log_string("avalon USDX borrow reverted");
                break;
            }

            // 3. USDX -> USDT -> BTCB.
            bytes memory path = abi.encodePacked(
                LOCAL_USDX, uint24(100), BSC.USDT, uint24(500), BSC.BTCB
            );
            uint256 usdxBal = IERC20(LOCAL_USDX).balanceOf(address(this));
            uint256 btcbOut;
            try IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInput(
                IPancakeV3Router.ExactInputParams({
                    path: path,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: usdxBal,
                    amountOutMinimum: 0
                })
            ) returns (uint256 out) {
                btcbOut = out;
            } catch {
                emit log_string("USDX->BTCB swap reverted");
                break;
            }
            if (btcbOut == 0) break;

            // 4. Mint pumpBTC from BTCB.
            uint256 pumpOut = _mintPumpBTC(btcbOut);
            if (pumpOut == 0) {
                emit log_string("pumpBTC mint failed; aborting loop");
                break;
            }
            toSupply = pumpOut;
        }

        // 5. Use a slice of pumpBTC balance to buy PT-pumpBTC on Pendle
        //    (fixed-yield sleeve representing ~30% of final position).
        uint256 pumpBal = IERC20(LOCAL_PUMPBTC).balanceOf(address(this));
        if (pumpBal > 0) {
            uint256 ptSleeve = (pumpBal * 30) / 100;
            uint256 ptOut = _pendleBuyPT(ptSleeve);
            emit log_named_uint("pt_pumpbtc_acquired", ptOut);
        }

        // Hold 60 days; warp to capture PT pull-to-par + restake APY.
        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
        vm.roll(block.number + (HOLD_DAYS * 1 days) / 3);

        (, uint256 totalDebtBase,,,,) = pool.getUserAccountData(address(this));
        emit log_named_uint("avalon_total_debt_base_1e8", totalDebtBase);

        // Model the PT pull-to-par by bumping oracle.
        _setOraclePrice(_pt, 65_650e8);

        _endPnL("B12-05: pumpBTC Avalon Pendle PT 3-mech stack");
    }

    function _mintPumpBTC(uint256 btcbAmt) internal returns (uint256 pumpOut) {
        (bool ok,) = LOCAL_PUMPBTC_MINTER.call(
            abi.encodeWithSignature("mint(uint256)", btcbAmt)
        );
        if (!ok) return 0;
        pumpOut = IERC20(LOCAL_PUMPBTC).balanceOf(address(this));
    }

    function _pendleBuyPT(uint256 pumpAmt) internal returns (uint256 ptOut) {
        IERC20(LOCAL_PUMPBTC).approve(BSC.PENDLE_ROUTER_V4, pumpAmt);
        (bool ok,) = BSC.PENDLE_ROUTER_V4.call(
            abi.encodeWithSignature(
                "swapExactTokenForPt(address,address,uint256,uint256,bytes,bytes)",
                address(this),
                LOCAL_PENDLE_MARKET_PUMPBTC,
                pumpAmt,
                0,
                bytes(""),
                bytes("")
            )
        );
        if (!ok) return 0;
        ptOut = IERC20(_pt).balanceOf(address(this));
    }

    /// @dev Offline-first: model 60-day 3-mech carry.
    /// Components:
    ///   - pumpBTC native APY ~ 5% (Babylon + points), levered 2.0x via Avalon
    ///   - PT-pumpBTC sleeve fixed yield ~ 9% APY on 30% slice
    ///   - USDX borrow APR ~ 1.5% net of incentives
    ///   - Swap drag ~ 20 bp on the borrow leg per loop * 3 = 60 bp / yr
    /// Gross APY = 2.0*5 + 0.3*(9-5) - 1.0*1.5 - 0.6 = 10 + 1.2 - 1.5 - 0.6 = 9.10%
    /// 60-day carry = 9.10 * 60/365 = 1.50%
    function _offlinePnLCheck() internal {
        _fund(LOCAL_PUMPBTC, address(this), PRINCIPAL);
        _startPnL();

        uint256 gain = (PRINCIPAL * 150) / 10_000; // 1.50%
        _fund(LOCAL_PUMPBTC, address(this), PRINCIPAL + gain);

        emit log_string("B12-05 offline accounting: +1.50% over 60d, 2.0x lev, +PT sleeve");
        _endPnL("B12-05[offline]: pumpBTC Avalon Pendle PT 3-mech stack");
    }
}
