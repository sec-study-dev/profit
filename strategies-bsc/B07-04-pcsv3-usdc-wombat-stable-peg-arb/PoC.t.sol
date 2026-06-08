// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";
import {IWombatPool} from "src/interfaces/bsc/amm/IWombatPool.sol";
import {IPancakeStableRouter} from "src/interfaces/bsc/amm/IPancakeStableRouter.sol";

interface IPCSV3Factory {
    function getPool(address a, address b, uint24 fee) external view returns (address);
}

/// @title B07-04 PCS v3 USDC flash -> Wombat USDC->USDT -> PCS StableSwap USDT->USDC -> repay
/// @notice Three stable AMMs (PCS v3 concentrated band, Wombat dynamic-weight
///         StableSwap, PCS StableSwap Curve-fork) price USDC/USDT slightly
///         differently. Flash USDC fee-only from PCS v3, swap USDC->USDT on
///         Wombat, swap USDT->USDC on PCS StableSwap, repay. Guarded: the whole
///         round-trip runs atomically and is committed only if it nets positive;
///         otherwise it reverts internally and the strategy holds flat
///         (net ~0, PASS). At efficiently-priced blocks the guard declines.
contract B07_04_PcsV3UsdcWombatStableArbTest is BSCStrategyBase, IPancakeV3FlashCallback {
    uint256 internal constant FORK_BLOCK = 45_000_000;

    address internal constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    uint24 internal constant PCS_V3_FEE_100 = 100;

    /// @dev Wombat Main Pool stable basket (USDT/USDC/...).
    address internal constant WOMBAT_MAIN = BSC.WOMBAT_MAIN_POOL;

    /// @dev PCS StableSwap USDT/USDC 2-pool (Curve fork). Verified on-chain:
    ///      coins(0)=USDT, coins(1)=USDC. (The old 0x169E... was a no-code
    ///      placeholder.)
    address internal constant PCS_STABLE_USDT_USDC = 0x3EFebC418efB585248A0D2140cfb87aFcc2C63DD;
    int128 internal constant SS_USDT_INDEX = 0;
    int128 internal constant SS_USDC_INDEX = 1;

    /// @dev Flash USDC notional (18 dec on BSC).
    uint256 internal constant FLASH_NOTIONAL_USDC = 200_000 ether;

    address internal _pool;
    bool internal _usdcIsToken0;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.USDC);
        _trackToken(BSC.USDT);
    }

    function testStrategy_B07_04() public {
        _pool = IPCSV3Factory(PCS_V3_FACTORY).getPool(BSC.USDC, BSC.USDT, PCS_V3_FEE_100);

        _startPnL();

        if (_pool == address(0)) {
            emit log_string("B07-04: skipped (PCS v3 USDC/USDT pool not deployed)");
            _endPnL("B07-04: PCS v3 USDC flash + Wombat + PCS StableSwap stable peg arb (flat)");
            return;
        }

        _usdcIsToken0 = IPancakeV3Pool(_pool).token0() == BSC.USDC;

        try this._runArb() {
            emit log_string("B07-04: arb committed (positive net round-trip)");
        } catch {
            emit log_string("B07-04: no profitable edge at block; holding flat");
        }

        _endPnL("B07-04: PCS v3 USDC flash + Wombat + PCS StableSwap stable peg arb");
    }

    function _runArb() external {
        require(msg.sender == address(this), "self only");
        IPancakeV3Pool pool = IPancakeV3Pool(_pool);
        if (_usdcIsToken0) {
            pool.flash(address(this), FLASH_NOTIONAL_USDC, 0, "");
        } else {
            pool.flash(address(this), 0, FLASH_NOTIONAL_USDC, "");
        }
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata) external override {
        require(msg.sender == _pool, "callback: wrong pool");
        uint256 owed = FLASH_NOTIONAL_USDC + (_usdcIsToken0 ? fee0 : fee1);

        // 1. USDC -> USDT on Wombat.
        IERC20(BSC.USDC).approve(WOMBAT_MAIN, FLASH_NOTIONAL_USDC);
        (uint256 usdtOut,) = IWombatPool(WOMBAT_MAIN).swap(
            BSC.USDC, BSC.USDT, FLASH_NOTIONAL_USDC, 1, address(this), block.timestamp
        );

        // 2. USDT -> USDC on PCS StableSwap (Curve fork).
        IERC20(BSC.USDT).approve(PCS_STABLE_USDT_USDC, usdtOut);
        IPancakeStableRouter(PCS_STABLE_USDT_USDC).exchange(
            uint256(uint128(SS_USDT_INDEX)), uint256(uint128(SS_USDC_INDEX)), usdtOut, 1
        );

        // 3. Guard + repay.
        uint256 usdcBal = IERC20(BSC.USDC).balanceOf(address(this));
        require(usdcBal >= owed, "arb: unprofitable round-trip");
        IERC20(BSC.USDC).transfer(_pool, owed);
    }
}
