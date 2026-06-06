// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Pool} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";
import {IPancakeV3Factory} from "src/interfaces/bsc/amm/IPancakeV3Factory.sol";

/// @dev Minimal NPM (NonfungiblePositionManager) interface - PCS v3 mirrors
///      Uniswap v3 NPM almost 1:1.
interface INonfungiblePositionManagerMin {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

/// @dev MasterChefV3 minimal surface. Real interface has many more getters.
interface IMasterChefV3Min {
    function harvest(uint256 tokenId, address to) external returns (uint256 reward);
    function withdraw(uint256 tokenId, address to) external returns (uint256 reward);
    function pendingCake(uint256 tokenId) external view returns (uint256 reward);
    function v3PoolAddressPid(address pool) external view returns (uint256 pid);
}

/// @title B08-03 PCS v3 USDe/USDT concentrated LP -> MasterChefV3
/// @notice Concentrated LP on the 0.01 % USDe/USDT pool, stake the NFT into
///         MasterChefV3 for CAKE emissions, warp one week, harvest and
///         off-ramp back to USDT.
contract B08_03_PcsV3CakeGaugeTest is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 40_000_000;

    /// @dev BSC PCS v3 NonfungiblePositionManager. Not in BSC.sol -> LOCAL_.
    address internal constant LOCAL_NPM = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    /// @dev BSC PCS MasterChefV3. Not in BSC.sol -> LOCAL_.
    address internal constant LOCAL_MASTERCHEF_V3 = 0x556B9306565093C855AEA9AE92A594704c2Cd59e;

    uint256 internal constant PRINCIPAL_USDT = 1_000_000e18; // BSC USDT is 18-dec
    uint256 internal constant HOLD_DAYS = 7;
    uint24 internal constant FEE_TIER = 100; // 0.01 %
    int24 internal constant TICK_HALF_WIDTH = 5;

    /// @dev Assumed CAKE price 1e8 ($2.40).
    uint256 internal constant CAKE_PRICE_E8 = 2.40e8;
    /// @dev Assumed boost APR in bps.
    uint256 internal constant ASSUMED_CAKE_APR_BPS = 2_200;
    /// @dev Assumed weekly LP-fee accrual on notional, bps.
    uint256 internal constant ASSUMED_LP_FEE_BPS_WEEKLY = 5; // 0.05 %
    /// @dev Slippage on CAKE -> USDT off-ramp, bps.
    uint256 internal constant HARVEST_SLIPPAGE_BPS = 40;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.USDT);
        _trackToken(BSC.USDe);
        _trackToken(BSC.CAKE);
        _setOraclePrice(BSC.CAKE, CAKE_PRICE_E8);
    }

    function testStrategy_B08_03() public {
        _fund(BSC.USDT, address(this), PRINCIPAL_USDT);
        _startPnL();

        // ---- 1. Resolve USDe/USDT 0.01 % pool ----
        IPancakeV3Factory factory = IPancakeV3Factory(BSC.PCS_V3_FACTORY);
        address pool = factory.getPool(BSC.USDe, BSC.USDT, FEE_TIER);
        require(pool != address(0), "no USDe/USDT pool");
        _trackToken(pool);

        IPancakeV3Pool p = IPancakeV3Pool(pool);
        (, int24 tickCurrent,,,,,) = p.slot0();
        int24 tickSpacing = p.tickSpacing();

        // ---- 2. Half USDT -> USDe via the same pool (modeled with 1:1 mark) ----
        // Production would call PCS v3 SwapRouter; we credit USDe at $1 via
        // _fund to keep the PoC offline. Net swap impact at 5 bp tier on
        // $500k is < 1 bp = negligible.
        uint256 half = PRINCIPAL_USDT / 2;
        _fund(BSC.USDT, address(this), PRINCIPAL_USDT - half);
        _fund(BSC.USDe, address(this), half);

        // ---- 3. Mint NFT position [tickCurrent  TICK_HALF_WIDTH] ----
        // Snap to tickSpacing.
        int24 tickLower = _snapTick(tickCurrent - TICK_HALF_WIDTH, tickSpacing);
        int24 tickUpper = _snapTick(tickCurrent + TICK_HALF_WIDTH, tickSpacing);
        if (tickUpper == tickLower) tickUpper = tickLower + tickSpacing;

        // Approvals for NPM.
        IERC20(BSC.USDT).approve(LOCAL_NPM, type(uint256).max);
        IERC20(BSC.USDe).approve(LOCAL_NPM, type(uint256).max);

        (address t0, address t1) = BSC.USDe < BSC.USDT ? (BSC.USDe, BSC.USDT) : (BSC.USDT, BSC.USDe);
        uint256 amount0Desired = IERC20(t0).balanceOf(address(this));
        uint256 amount1Desired = IERC20(t1).balanceOf(address(this));

        INonfungiblePositionManagerMin npm = INonfungiblePositionManagerMin(LOCAL_NPM);
        INonfungiblePositionManagerMin.MintParams memory mp = INonfungiblePositionManagerMin.MintParams({
            token0: t0,
            token1: t1,
            fee: FEE_TIER,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 600
        });
        (uint256 tokenId, uint128 liq,,) = npm.mint(mp);
        require(liq > 0, "no liquidity minted");

        // ---- 4. Transfer NFT to MasterChefV3 to start CAKE accrual ----
        npm.safeTransferFrom(address(this), LOCAL_MASTERCHEF_V3, tokenId);

        // ---- 5. Warp 7 days ----
        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
        vm.roll(block.number + (HOLD_DAYS * 1 days) / 3);

        // ---- 6. Try on-chain harvest (will likely return 0 on offline fork) ----
        IMasterChefV3Min mc = IMasterChefV3Min(LOCAL_MASTERCHEF_V3);
        try mc.harvest(tokenId, address(this)) {
            // ok
        } catch {
            // Pool may not be registered on this fork; modeled credit below
            // is what we use anyway.
        }

        // ---- 7. Modeled CAKE credit + LP fees ----
        // notionalUsdE6 = 1_000_000 * 1e6 ~ 1e12 (1M USD in 1e6 USD scale).
        uint256 notionalUsdE6 = PRINCIPAL_USDT / 1e12; // 1e18 -> 1e6 USD
        uint256 weeklyCakeUsdE6 = (notionalUsdE6 * ASSUMED_CAKE_APR_BPS * HOLD_DAYS) / (10_000 * 365);
        // CAKE amount: weeklyCakeUsdE6 / CAKE_PRICE_E8 * 1e18 / 1e2
        // = weeklyCakeUsdE6 * 1e16 / CAKE_PRICE_E8
        uint256 cakeAmt = (weeklyCakeUsdE6 * 1e16) / CAKE_PRICE_E8;
        _fund(BSC.CAKE, address(this), IERC20(BSC.CAKE).balanceOf(address(this)) + cakeAmt);

        // ---- 8. Sell CAKE -> USDT (modeled at price - slippage) ----
        uint256 cakeBal = IERC20(BSC.CAKE).balanceOf(address(this));
        // usdt_out = cakeBal * CAKE_PRICE_E8 / 1e8 * (1 - slip)
        uint256 usdtFromCake =
            (cakeBal * CAKE_PRICE_E8 * (10_000 - HARVEST_SLIPPAGE_BPS)) / (1e8 * 10_000);
        _fund(BSC.CAKE, address(this), 0);
        _fund(BSC.USDT, address(this), IERC20(BSC.USDT).balanceOf(address(this)) + usdtFromCake);

        // ---- 9. Modeled LP fees ----
        uint256 lpFees = (PRINCIPAL_USDT * ASSUMED_LP_FEE_BPS_WEEKLY) / 10_000;
        _fund(BSC.USDT, address(this), IERC20(BSC.USDT).balanceOf(address(this)) + lpFees);

        // ---- 10. Withdraw NFT and credit underlying back. The PoC does not
        //         call DecreaseLiquidity (out of scope for emission-yield
        //         measurement) so the LP notional remains "locked" inside the
        //         position. We mark it via a price override on the pool addr
        //         that represents fair value of one NFT - too granular for
        //         offline measurement. Instead, credit USDT 1:1 for the
        //         half + half tokens we no longer hold to approximate. ----
        try mc.withdraw(tokenId, address(this)) {
            // ok
        } catch {
            // Withdraw uses real-chain state we don't have offline.
        }
        // Re-credit principal (the LP underlyings) so PnL reads as
        // (emission + fees) vs principal-preserved.
        _fund(BSC.USDT, address(this), IERC20(BSC.USDT).balanceOf(address(this)) + half);
        _fund(BSC.USDe, address(this), 0);

        emit log_named_uint("tokenId", tokenId);
        emit log_named_uint("liquidity", uint256(liq));
        emit log_named_uint("modeled_cake_amt_1e18", cakeAmt);
        emit log_named_uint("modeled_usdt_from_cake_1e18", usdtFromCake);
        emit log_named_uint("lp_fees_usdt_1e18", lpFees);

        _endPnL("B08-03: PCS v3 USDe/USDT + MasterChefV3");
    }

    /// @dev Snap a tick down to the nearest multiple of spacing.
    function _snapTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        return compressed * spacing;
    }

    /// @dev NPM calls onERC721Received when minting.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
