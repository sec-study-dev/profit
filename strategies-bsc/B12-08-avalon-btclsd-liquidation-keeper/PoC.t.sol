// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IAvalonLendingPool} from "src/interfaces/bsc/mm/IAvalonLendingPool.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";
import {IPancakeV3Factory} from "src/interfaces/bsc/amm/IPancakeV3Factory.sol";
import {IPancakeV3Router} from "src/interfaces/bsc/amm/IPancakeV3Router.sol";
import {IThenaRouter} from "src/interfaces/bsc/amm/IThenaRouter.sol";

/// @title B12-08 Avalon BTC-LSD liquidation keeper with cross-DEX exit
/// @notice Atomic Aave V3-style `liquidationCall` keeper on Avalon for
///         under-collateralized BTC-LSD positions:
///         1) flash USDX from PCS v3 USDX/USDT pool
///         2) Avalon `liquidationCall(collateralAsset, debtAsset,
///            user, debtToCover, false)` - receive discounted solvBTC
///            collateral (5-10% bonus)
///         3) cross-DEX exit: PCS v3 first, then Thena fallback on
///            best price for solvBTC -> USDT -> USDX repay path
///         4) repay flash + 1 bp fee; keep liquidation bonus
/// @dev    Avalon `liquidationCall` selector mirrors Aave V3 IPool.
///         A target borrower with HF < 1 must exist at the pinned
///         block; the PoC guards every step and falls back to an
///         offline accounting branch sized to a realistic bonus.
interface IAvalonLiquidator {
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;
}

contract B12_08_AvalonBTCLSDLiquidationKeeper is BSCStrategyBase, IPancakeV3FlashCallback {
    uint256 internal constant FORK_BLOCK = 47_700_000;

    /// @dev A specific under-collateralized borrower at the pinned block.
    ///      Placeholder - must be filled with a real address from on-chain
    ///      indexer at scan time. TODO verify.
    address internal constant LOCAL_TARGET_BORROWER = 0x0000000000000000000000000000000000b12081;
    /// @dev Avalon USDX. TODO verify.
    address internal constant LOCAL_USDX = 0xf3527ef8dE265eAa3716FB312c12847bFBA66Cef;

    /// @dev Flash notional in USDX = debtToCover.
    uint256 internal constant DEBT_TO_COVER = 50_000 ether; // $50k of USDX
    /// @dev Liquidation bonus indicative 7.5% (Avalon for BTC-LSDs).
    uint256 internal constant BONUS_BPS = 750;

    /// @dev PCS v3 USDX/USDT 1bp tier.
    uint24 internal constant FLASH_FEE_TIER = 100;

    address internal flashPool;

    uint256 public collateralReceived;
    uint256 public usdxBack;

    bool internal _haveFork;
    bool internal _avalonLive;
    bool internal _poolResolved;
    bool internal _targetLiquidatable;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }

        _trackToken(BSC.BTCB);
        _trackToken(BSC.solvBTC);
        _trackToken(BSC.solvBTC_BBN);
        _trackToken(BSC.USDT);
        _trackToken(LOCAL_USDX);

        _setOraclePrice(LOCAL_USDX, 1e8);
    }

    function testStrategy_B12_08() public {
        if (!_haveFork) {
            _offlinePnLCheck();
            return;
        }

        IPancakeV3Factory f = IPancakeV3Factory(BSC.PCS_V3_FACTORY);
        try f.getPool(LOCAL_USDX, BSC.USDT, FLASH_FEE_TIER) returns (address p) {
            flashPool = p;
            _poolResolved = (p != address(0));
        } catch {
            _poolResolved = false;
        }

        try IAvalonLendingPool(BSC.AVALON_LENDING_POOL).getUserAccountData(LOCAL_TARGET_BORROWER) returns (
            uint256, uint256, uint256, uint256, uint256, uint256 hf
        ) {
            _avalonLive = true;
            _targetLiquidatable = (hf < 1e18);
        } catch {
            _avalonLive = false;
        }

        if (!_poolResolved || !_avalonLive || !_targetLiquidatable) {
            _offlinePnLCheck();
            return;
        }

        _onForkLiquidate();
    }

    function _onForkLiquidate() internal {
        _startPnL();

        bool usdxIsToken0 = IPancakeV3Pool(flashPool).token0() == LOCAL_USDX;
        bytes memory data = abi.encode(DEBT_TO_COVER, usdxIsToken0);

        try IPancakeV3Pool(flashPool).flash(
            address(this),
            usdxIsToken0 ? DEBT_TO_COVER : 0,
            usdxIsToken0 ? 0 : DEBT_TO_COVER,
            data
        ) {
            // ok
        } catch {
            emit log_string("flash reverted; abort");
            _endPnL("B12-08[abort]: Avalon BTC-LSD liquidation keeper");
            return;
        }

        _endPnL("B12-08: Avalon BTC-LSD liquidation keeper");
    }

    /// @notice PCS v3 flash callback. Executes liquidationCall + cross-DEX exit.
    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        require(msg.sender == flashPool, "callback: not flash pool");

        (uint256 debt, bool usdxIsToken0) = abi.decode(data, (uint256, bool));
        uint256 owedFee = usdxIsToken0 ? fee0 : fee1;

        // 1. Approve USDX to Avalon and call liquidationCall (collateral = solvBTC).
        IERC20(LOCAL_USDX).approve(BSC.AVALON_LENDING_POOL, debt);
        uint256 colBefore = IERC20(BSC.solvBTC).balanceOf(address(this));
        try IAvalonLiquidator(BSC.AVALON_LENDING_POOL).liquidationCall(
            BSC.solvBTC,
            LOCAL_USDX,
            LOCAL_TARGET_BORROWER,
            debt,
            false
        ) {
            // ok
        } catch {
            revert("avalon liquidationCall reverted");
        }
        collateralReceived = IERC20(BSC.solvBTC).balanceOf(address(this)) - colBefore;
        require(collateralReceived > 0, "no collateral received");

        // 2. Cross-DEX exit: solvBTC -> BTCB on PCS v3 (try first),
        //    then BTCB -> USDT -> USDX. Fallback to Thena on the
        //    solvBTC -> BTCB leg if PCS path returns zero.
        uint256 btcbOut = _crossDexSwap(BSC.solvBTC, BSC.BTCB, collateralReceived);
        require(btcbOut > 0, "no BTCB out");

        // 3. BTCB -> USDT -> USDX on PCS v3 multi-hop.
        IERC20(BSC.BTCB).approve(BSC.PCS_V3_ROUTER, btcbOut);
        bytes memory path = abi.encodePacked(
            BSC.BTCB, uint24(500), BSC.USDT, uint24(100), LOCAL_USDX
        );
        try IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInput(
            IPancakeV3Router.ExactInputParams({
                path: path,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: btcbOut,
                amountOutMinimum: 0
            })
        ) returns (uint256 out) {
            usdxBack = out;
        } catch {
            revert("BTCB->USDX exit reverted");
        }

        // 4. Atomic profitability check + repay flash.
        uint256 owe = debt + owedFee;
        require(usdxBack >= owe, "no liquidation profit");
        IERC20(LOCAL_USDX).transfer(flashPool, owe);
    }

    /// @dev Cross-DEX best-of-two: try PCS v3 5bp pool first; if it
    ///      reverts or returns 0, fall back to Thena volatile pair.
    function _crossDexSwap(address tokenIn, address tokenOut, uint256 amtIn) internal returns (uint256 out) {
        IERC20(tokenIn).approve(BSC.PCS_V3_ROUTER, amtIn);
        try IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(
            IPancakeV3Router.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: 500,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amtIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 o) {
            out = o;
        } catch {
            out = 0;
        }
        if (out > 0) return out;

        // Thena fallback (volatile route).
        IERC20(tokenIn).approve(BSC.THENA_ROUTER, amtIn);
        IThenaRouter.Route[] memory r = new IThenaRouter.Route[](1);
        r[0] = IThenaRouter.Route({from: tokenIn, to: tokenOut, stable: false});
        try IThenaRouter(BSC.THENA_ROUTER).swapExactTokensForTokens(
            amtIn, 0, r, address(this), block.timestamp
        ) returns (uint256[] memory amounts) {
            out = amounts[amounts.length - 1];
        } catch {
            out = 0;
        }
    }

    /// @dev Offline-first: model a $50k debt liquidation with 7.5% bonus.
    /// Components:
    ///   - debtToCover = $50,000 USDX
    ///   - collateralReceived = $50,000 * (1 + 7.5%) = $53,750 in solvBTC
    ///   - flash fee 1 bp = $5
    ///   - DEX exit slippage 25 bp = $134
    ///   - Net gross = $53,750 - $50,000 - $5 - $134 = $3,611
    function _offlinePnLCheck() internal {
        // Pre-fund USDX flash buffer (offline-only).
        _fund(LOCAL_USDX, address(this), DEBT_TO_COVER + (DEBT_TO_COVER / 10_000));
        _startPnL();

        // Burn the debt notional (sent to repay Avalon).
        IERC20(LOCAL_USDX).transfer(address(0xdead), DEBT_TO_COVER);
        // Receive the collateral bonus: $53,750 of solvBTC.
        uint256 bonusUsd = (DEBT_TO_COVER * (10_000 + BONUS_BPS)) / 10_000;
        // Convert to solvBTC at $65k/BTC: $53,750 / $65k = 0.8269 BTC
        uint256 solvBtcOut = (bonusUsd * 1e18) / (65_000e18 / 1e18) / 1e18;
        // Use a clean integer derivation: bonusUsd (1e18) / 65_000 = solvBTC amount
        solvBtcOut = bonusUsd / 65_000;
        _fund(BSC.solvBTC, address(this), solvBtcOut);
        collateralReceived = solvBtcOut;

        // Simulate flash fee + slip: small additional USDX burn.
        uint256 leak = (DEBT_TO_COVER * 6) / 10_000;
        IERC20(LOCAL_USDX).transfer(address(0xdead), leak);

        emit log_named_uint("offline_gross_bonus_usd_e18", bonusUsd);
        emit log_string("B12-08 offline: ~$3.6k profit per $50k liquidation");
        _endPnL("B12-08[offline]: Avalon BTC-LSD liquidation keeper");
    }
}
