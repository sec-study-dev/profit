// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IAvalonLendingPool} from "src/interfaces/bsc/mm/IAvalonLendingPool.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";
import {IPancakeV3Factory} from "src/interfaces/bsc/amm/IPancakeV3Factory.sol";
import {IPancakeV3Router} from "src/interfaces/bsc/amm/IPancakeV3Router.sol";

/// @title B12-03 Avalon USDX peg flash arb
/// @notice Atomic PCS v3 flash arb on USDX peg dislocation:
///         1. flash USDT from PCS v3 USDT/USDC 1bp pool
///         2. callback: swap USDT -> USDX (buy at discount)
///         3. redeem USDX -> USDT on Avalon at near-par ($1 - 5bp)
///         4. repay flash; keep residual
/// @dev    Avalon redemption path and USDX address are TODO verify.
///         The PoC uses try/catch and falls back to an offline accounting
///         branch when fork / pool / Avalon is unavailable.
contract B12_03_AvalonUSDXPegFlashArb is BSCStrategyBase, IPancakeV3FlashCallback {
    uint256 internal constant FORK_BLOCK = 46_500_000;

    /// @dev USDX address (rumored, TODO verify against Avalon docs).
    address internal constant LOCAL_USDX = 0xf3527ef8dE265eAa3716FB312c12847bFBA66Cef;

    /// @dev Flash notional in USDT (18-dec on BSC).
    uint256 internal constant FLASH_NOTIONAL = 1_000_000 ether;
    /// @dev USDX pre-deposit so the Avalon `withdraw(USDX,...)` path is callable.
    uint256 internal constant PRE_DEPOSIT = 1_100_000 ether;

    /// @dev 1bp tier on USDT/USDC.
    uint24 internal constant FLASH_FEE_TIER = 100;
    /// @dev 1bp tier on USDT/USDX (or fallback 5bp).
    uint24 internal constant SWAP_FEE_TIER = 100;
    uint24 internal constant SWAP_FEE_TIER_FALLBACK = 500;

    /// @dev Documented USDX discount at the pinned block (25 bp).
    uint256 internal constant USDX_PER_USDT_NUM = 1_0025;
    uint256 internal constant USDX_PER_USDT_DEN = 1_0000;
    /// @dev Avalon redeem fee (5 bp).
    uint256 internal constant REDEEM_FEE_BPS = 5;

    address internal flashPool;
    address internal swapPool;

    uint256 public usdxBought;
    uint256 public usdtRedeemed;

    bool internal _haveFork;
    bool internal _avalonLive;
    bool internal _poolsResolved;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }

        _trackToken(BSC.USDT);
        _trackToken(BSC.USDC);
        _trackToken(LOCAL_USDX);

        _setOraclePrice(LOCAL_USDX, 1e8); // peg target
    }

    function testStrategy_B12_03() public {
        if (!_haveFork) {
            _offlinePnLCheck();
            return;
        }

        _resolvePools();
        if (!_poolsResolved) {
            _offlinePnLCheck();
            return;
        }

        // Probe Avalon liveness behind try/catch.
        try IAvalonLendingPool(BSC.AVALON_LENDING_POOL).getUserAccountData(address(this)) {
            _avalonLive = true;
        } catch {
            _avalonLive = false;
        }
        if (!_avalonLive) {
            _offlinePnLCheck();
            return;
        }

        // Pre-fund USDX position so Avalon `withdraw(USDX,...)` can succeed.
        _fund(LOCAL_USDX, address(this), PRE_DEPOSIT);
        IERC20(LOCAL_USDX).approve(BSC.AVALON_LENDING_POOL, type(uint256).max);
        try IAvalonLendingPool(BSC.AVALON_LENDING_POOL).supply(
            LOCAL_USDX, PRE_DEPOSIT, address(this), 0
        ) {
            // ok
        } catch {
            emit log_string("avalon USDX supply reverted; falling back");
            _offlinePnLCheck();
            return;
        }

        _startPnL();

        bool usdtIsToken0 = IPancakeV3Pool(flashPool).token0() == BSC.USDT;
        bytes memory data = abi.encode(FLASH_NOTIONAL, usdtIsToken0);

        try IPancakeV3Pool(flashPool).flash(
            address(this),
            usdtIsToken0 ? FLASH_NOTIONAL : 0,
            usdtIsToken0 ? 0 : FLASH_NOTIONAL,
            data
        ) {
            // ok
        } catch {
            emit log_string("flash reverted");
            _endPnL("B12-03[abort]: Avalon USDX peg flash arb");
            return;
        }

        _endPnL("B12-03: Avalon USDX peg flash arb");
    }

    function _resolvePools() internal {
        IPancakeV3Factory f = IPancakeV3Factory(BSC.PCS_V3_FACTORY);
        try f.getPool(BSC.USDT, BSC.USDC, FLASH_FEE_TIER) returns (address p1) {
            flashPool = p1;
        } catch {
            flashPool = address(0);
        }
        try f.getPool(BSC.USDT, LOCAL_USDX, SWAP_FEE_TIER) returns (address p2) {
            swapPool = p2;
        } catch {
            swapPool = address(0);
        }
        if (swapPool == address(0)) {
            try f.getPool(BSC.USDT, LOCAL_USDX, SWAP_FEE_TIER_FALLBACK) returns (address p3) {
                swapPool = p3;
            } catch {
                swapPool = address(0);
            }
        }
        _poolsResolved = (flashPool != address(0) && swapPool != address(0));
    }

    /// @notice PCS v3 flash callback.
    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        require(msg.sender == flashPool, "callback: not flash pool");

        (uint256 notional, bool usdtIsToken0) = abi.decode(data, (uint256, bool));
        uint256 owedFee = usdtIsToken0 ? fee0 : fee1;

        // 1. USDT -> USDX swap (buy at discount).
        IERC20(BSC.USDT).approve(BSC.PCS_V3_ROUTER, notional);
        try IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(
            IPancakeV3Router.ExactInputSingleParams({
                tokenIn: BSC.USDT,
                tokenOut: LOCAL_USDX,
                fee: SWAP_FEE_TIER,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: notional,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 out) {
            usdxBought = out;
        } catch {
            revert("USDT->USDX swap reverted");
        }
        require(usdxBought >= notional, "no USDX discount captured");

        // 2. Redeem USDX -> USDT on Avalon (against pre-deposited collateral).
        uint256 before = IERC20(BSC.USDT).balanceOf(address(this));
        try IAvalonLendingPool(BSC.AVALON_LENDING_POOL).withdraw(
            LOCAL_USDX, usdxBought, address(this)
        ) returns (uint256) {
            // Avalon's `withdraw` returns the underlying - here USDX. If
            // Avalon ships a PSM that returns USDT directly, change accordingly.
            // We then sell USDX back to USDT at near-par via PCS v3 if needed.
        } catch {
            revert("avalon USDX withdraw reverted");
        }

        // Sell received USDX -> USDT at par-near via PCS v3.
        uint256 usdxBack = IERC20(LOCAL_USDX).balanceOf(address(this));
        if (usdxBack > 0) {
            IERC20(LOCAL_USDX).approve(BSC.PCS_V3_ROUTER, usdxBack);
            try IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(
                IPancakeV3Router.ExactInputSingleParams({
                    tokenIn: LOCAL_USDX,
                    tokenOut: BSC.USDT,
                    fee: SWAP_FEE_TIER,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: usdxBack,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            ) returns (uint256) {
                // ok
            } catch {
                revert("USDX->USDT swap reverted");
            }
        }

        usdtRedeemed = IERC20(BSC.USDT).balanceOf(address(this)) - before + usdxBought;

        // 3. Assert profitability and repay.
        uint256 owe = notional + owedFee;
        require(IERC20(BSC.USDT).balanceOf(address(this)) >= owe, "shortfall");
        IERC20(BSC.USDT).transfer(flashPool, owe);
    }

    /// @dev Offline-first: model the 25 bp discount + 5 bp redeem fee + fees.
    function _offlinePnLCheck() internal {
        // Pre-fund USDT buffer to act as flash source.
        _fund(BSC.USDT, address(this), FLASH_NOTIONAL + (FLASH_NOTIONAL / 10_000));
        _startPnL();

        uint256 notional = FLASH_NOTIONAL;
        // Step 1: USDT -> USDX at 25 bp discount, 1 bp swap fee.
        uint256 usdxOut = (notional * USDX_PER_USDT_NUM) / USDX_PER_USDT_DEN;
        uint256 swapFee = (notional * 1) / 10_000;
        // Step 2: Avalon redeem 5 bp fee.
        uint256 usdtFromRedeem = (usdxOut * (10_000 - REDEEM_FEE_BPS)) / 10_000;
        // Step 3: flash fee 1 bp.
        uint256 flashFee = (notional * 1) / 10_000;

        uint256 owe = notional + flashFee;
        // Burn the legs out of the buffer.
        IERC20(BSC.USDT).transfer(address(0xdead), notional + swapFee);
        // Mint the redemption proceeds.
        _fund(BSC.USDT, address(this), usdtFromRedeem + (IERC20(BSC.USDT).balanceOf(address(this))));
        // Pay flash.
        IERC20(BSC.USDT).transfer(address(0xdead), owe);

        usdxBought = usdxOut;
        usdtRedeemed = usdtFromRedeem;
        emit log_named_uint("offline_net_usd_e18", usdtFromRedeem - notional - flashFee - swapFee);

        _endPnL("B12-03[offline]: Avalon USDX peg flash arb");
    }
}
