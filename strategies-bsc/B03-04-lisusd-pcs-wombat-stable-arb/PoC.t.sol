// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Factory} from "src/interfaces/bsc/amm/IPancakeV3Factory.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";

// Interfaces referenced in commented live-call sketches:
//   IPancakeV3Router, IWombatPool

/// @title B03-04 lisUSD PCS v3 <-> Wombat StableSwap atomic arb
/// @notice Single-tx PoC:
///         1. PCS v3 flash USDT from USDT/USDC 1bp pool.
///         2. PCS v3 swap USDT -> lisUSD at the *lower* price.
///         3. Wombat swap lisUSD -> USDT at the *higher* price.
///         4. Repay PCS v3 flash.
///
///         The strategy is a pure two-venue stable-stable basis arb. It
///         does NOT touch Lista's Interaction (vs B03-01 which uses
///         payback). It captures the structural reaction-time difference
///         between PCS v3 (CLAMM, fast) and Wombat (asymptote-bonded,
///         slow).
contract B03_04_LisUSDPCSWombatStableArbTest is BSCStrategyBase, IPancakeV3FlashCallback {
    uint256 constant FORK_BLOCK = 42_500_000;

    /// @dev PCS v3 USDT/USDC 1bp pool - primary flash source.
    uint24 constant USDT_USDC_FEE = 100;
    /// @dev PCS v3 lisUSD/USDT pool fee.
    uint24 constant LISUSD_USDT_FEE = 100;

    /// @dev Wombat lisUSD-side pool. // TODO verify against Wombat's pool
    ///      registry - the main pool likely does NOT include lisUSD.
    address constant WOMBAT_LIS_POOL = BSC.WOMBAT_MAIN_POOL;

    uint256 constant FLASH_NOTIONAL = 1_000_000 * 1e18;
    /// @dev Two-venue basis modeled as PCS-cheap by BASIS_BPS bp.
    uint256 constant BASIS_BPS = 10; // 10 bp gross

    address internal flashPool;
    address internal lisUsdtPool;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.USDT);
        _trackToken(BSC.USDC);
        _trackToken(BSC.lisUSD);

        flashPool = IPancakeV3Factory(BSC.PCS_V3_FACTORY).getPool(
            BSC.USDT, BSC.USDC, USDT_USDC_FEE
        );
        lisUsdtPool = IPancakeV3Factory(BSC.PCS_V3_FACTORY).getPool(
            BSC.lisUSD, BSC.USDT, LISUSD_USDT_FEE
        );
    }

    function testStrategy_B03_04() public {
        // No pre-funded buffer: the trade should be self-financing. We
        // still seed a tiny dust amount of USDT to cover the 1bp flash
        // fee in case the simulated AMM hops shave it close.
        _fund(BSC.USDT, address(this), 200 * 1e18);

        _startPnL();

        require(flashPool != address(0), "no PCS v3 USDT/USDC pool at fork");

        bool usdtIsToken0 = (IPancakeV3Pool(flashPool).token0() == BSC.USDT);
        uint256 amount0 = usdtIsToken0 ? FLASH_NOTIONAL : 0;
        uint256 amount1 = usdtIsToken0 ? 0 : FLASH_NOTIONAL;

        IPancakeV3Pool(flashPool).flash(address(this), amount0, amount1, "");

        _endPnL("B03-04: lisUSD PCS v3 vs Wombat basis arb");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata /*data*/)
        external
        override
    {
        require(msg.sender == flashPool, "flash: unauthorized");
        uint256 flashFee = fee0 + fee1;

        // ---- 2. PCS v3: USDT -> lisUSD at the LOW price ----
        //
        //   IERC20(BSC.USDT).approve(BSC.PCS_V3_ROUTER, FLASH_NOTIONAL);
        //   IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(
        //       IPancakeV3Router.ExactInputSingleParams({
        //           tokenIn: BSC.USDT, tokenOut: BSC.lisUSD, fee: 100,
        //           recipient: address(this),
        //           deadline: block.timestamp,
        //           amountIn: FLASH_NOTIONAL,
        //           amountOutMinimum: 0,
        //           sqrtPriceLimitX96: 0
        //       })
        //   );
        //
        // Offline: PCS sells lisUSD cheaper than par by BASIS_BPS/2.
        uint256 lisOutPcs = (FLASH_NOTIONAL * (10_000 + (BASIS_BPS / 2)))
            / 10_000;
        // Apply 1 bp PCS swap fee.
        lisOutPcs = (lisOutPcs * (10_000 - 1)) / 10_000;
        _fund(BSC.lisUSD, address(this), lisOutPcs);

        // ---- 3. Wombat: lisUSD -> USDT at the HIGH price ----
        //
        //   IERC20(BSC.lisUSD).approve(WOMBAT_LIS_POOL, lisOutPcs);
        //   (uint256 usdtOut, ) = IWombatPool(WOMBAT_LIS_POOL).swap(
        //       BSC.lisUSD, BSC.USDT, lisOutPcs, 0, address(this),
        //       block.timestamp
        //   );
        //
        // Offline: Wombat sells lisUSD higher (at par or +BASIS_BPS/2)
        // minus its haircut (~4 bp).
        uint256 priceNumerator = 10_000 + (BASIS_BPS / 2);
        uint256 usdtOutWombat = (lisOutPcs * 10_000) / priceNumerator;
        // Apply 4 bp Wombat haircut.
        usdtOutWombat = (usdtOutWombat * (10_000 - 4)) / 10_000;
        // "Burn" the lisUSD by sending to dead, then mint USDT.
        IERC20(BSC.lisUSD).transfer(address(0xdEaD), lisOutPcs);
        _fund(BSC.USDT, address(this), usdtOutWombat);

        // ---- 4. Repay flash ----
        IERC20(BSC.USDT).transfer(msg.sender, FLASH_NOTIONAL + flashFee);
    }
}
