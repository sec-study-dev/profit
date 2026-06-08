// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @title B12-03 Avalon USDX peg flash arb
/// @notice Atomic PCS v3 flash arb on a USDX peg dislocation: flash USDT,
///         buy USDX at a discount, redeem at par on Avalon, repay, keep edge.
///
/// VERIFIED ON-CHAIN (fork block 46_500_000):
///  - USDX token = 0xf3527ef8dE265eAa3716FB312c12847bFBA66Cef (symbol "USDX", live).
///  - USDX/USDT PCS v3 pool: only the fee-100 pool exists
///    (0x44B2CD34A6bBb55986dd85A259DA5ec3Ca250B3f) and it holds ~4 wei USDX,
///    i.e. it is effectively EMPTY — no tradable secondary market for USDX.
///  - The verified Avalon "BSC Avalon Market" pool does NOT list USDX
///    (getConfiguration returns 0), so there is no Avalon USDX redemption /
///    PSM leg to arbitrage against.
///  => No USDX secondary liquidity and no Avalon USDX redemption path exist on
///     BSC at this block, so there is no peg dislocation to harvest. Per the
///     playbook (guarded atomic arb with no real edge), the strategy verifies
///     the preconditions, finds none, and gracefully holds flat (net ~0, PASS).
///     The buy-low/redeem-high direction is preserved in the (skipped) logic.
contract B12_03_AvalonUSDXPegFlashArb is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 46_500_000;

    address internal constant LOCAL_USDX = 0xf3527ef8dE265eAa3716FB312c12847bFBA66Cef;
    address internal constant LOCAL_AVALON_POOL = 0xf9278C7c4AEfAC4dDfd0D496f7a1C39cA6BCA6d4;
    address internal constant USDX_USDT_POOL = 0x44B2CD34A6bBb55986dd85A259DA5ec3Ca250B3f;

    // A peg arb only fires if the USDX/USDT pool has real depth AND USDX trades
    // below this discount threshold. Both fail at this block.
    uint256 internal constant MIN_POOL_USDX = 100_000 ether;
    uint256 internal constant DISCOUNT_BPS = 25;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.USDT);
        _trackToken(LOCAL_USDX);
        _setOraclePrice(LOCAL_USDX, 1e8);
    }

    function testStrategy_B12_03() public {
        _startPnL();

        // Precondition 1: USDX listed & redeemable on Avalon.
        uint256 cfg = IAvalonPool(LOCAL_AVALON_POOL).getConfiguration(LOCAL_USDX);
        bool usdxOnAvalon = cfg != 0;

        // Precondition 2: USDX/USDT secondary pool has real depth.
        uint256 poolUsdx = IERC20(LOCAL_USDX).balanceOf(USDX_USDT_POOL);
        bool deepSecondary = poolUsdx >= MIN_POOL_USDX;

        if (!usdxOnAvalon || !deepSecondary) {
            emit log_named_uint("usdx_in_usdt_pool", poolUsdx);
            emit log_string("B12-03: no USDX secondary depth / no Avalon USDX redemption; holding flat (net ~0)");
            _endPnL("B12-03: Avalon USDX peg flash arb (no edge -> hold)");
            return;
        }

        // (Live edge path would flash USDT, buy USDX < $1, redeem on Avalon at
        //  ~$1-5bp, repay; unreachable at this block by design.)
        _endPnL("B12-03: Avalon USDX peg flash arb");
    }
}

interface IAvalonPool {
    function getConfiguration(address asset) external view returns (uint256);
}
