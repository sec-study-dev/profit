// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IUniswapV3Pool} from "src/interfaces/amm/IUniswapV3Pool.sol";
import {IUniswapV3Router} from "src/interfaces/amm/IUniswapV3Router.sol";

/// @dev Local UniV3 pool LP subset (mint/burn/collect) - same as F13-04.
interface IUniswapV3PoolLP {
    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1);

    function burn(int24 tickLower, int24 tickUpper, uint128 amount)
        external
        returns (uint256 amount0, uint256 amount1);

    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external returns (uint128 amount0, uint128 amount1);
}

interface IUniswapV3MintCallback {
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external;
}

/// @title F13-05: UniV3 wstETH/WETH 0.01% JIT (just-in-time) LP + same-block backrun
/// @notice Composes two UniV3 mechanics:
///   1. JIT concentrated-liquidity provision in the *same block* as an
///      observed large swap. A 1-tick band straddling the active tick
///      captures essentially 100% of the in-range fee on the JIT'd swap.
///   2. A backrun swap immediately after the victim swap pushes the price
///      slightly past the position upper edge (or holds it inside), then
///      burn+collect inside the same block. This is the canonical JIT
///      backrun pattern used by searchers since 2022.
///
/// In this PoC the "victim" trade is simulated by us routing a sizeable
/// `exactInputSingle` swap through the pool in the same atomic test
/// execution. The LP position is minted *before* the swap, burned+collected
/// *after*. Mainnet bots watch the mempool for the pending big swap.
///
/// Mechanism count: 2 (UniV3 LP + UniV3 swap, both on same pool).
contract F13_05_UniV3WstETHJITLPBackrunTest is StrategyBase, IUniswapV3MintCallback {
    uint256 constant FORK_BLOCK = 20_900_000;

    /// @dev UniV3 wstETH/WETH 0.01% (fee tier 100, tickSpacing = 1).
    ///      token0 = wstETH (0x7f...), token1 = WETH (0xC0...).
    ///      Verified via UniV3 factory getPool(wstETH, WETH, 100).
    address constant UNIV3_WSTETH_WETH_100 = 0x109830a1AAaD605BbF02a9dFA7B0B92EC2FB7dAa;
    uint24 constant FEE_TIER = 100;

    /// @dev JIT LP funding (each side, generously over-funded; mint pulls
    ///      what it needs).
    uint256 constant FUND_WSTETH = 200 ether;
    uint256 constant FUND_WETH = 200 ether;

    /// @dev "Victim" swap amount that we route through the pool *after*
    ///      minting JIT liquidity. 50 WETH is plausible: a swap of that
    ///      size on the wstETH/WETH 1bp pool fits inside a single tick
    ///      crossing for a normally-loaded pool.
    uint256 constant VICTIM_SWAP_WETH = 50 ether;

    /// @dev Target JIT liquidity. Sized to dominate a +/-1 tick band.
    ///      Roughly 5x typical resting liquidity at this pool's tightest tick.
    uint128 constant JIT_LIQUIDITY = 5e22;

    bool internal _mintActive;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.WSTETH);
    }

    function testStrategy_F13_05() public {
        // Fund both legs generously for the JIT mint and the victim swap.
        _fund(Mainnet.WETH, address(this), FUND_WETH + VICTIM_SWAP_WETH);
        _fund(Mainnet.WSTETH, address(this), FUND_WSTETH);

        // Sanity: token ordering & spacing.
        require(IUniswapV3Pool(UNIV3_WSTETH_WETH_100).token0() == Mainnet.WSTETH, "univ3: t0");
        require(IUniswapV3Pool(UNIV3_WSTETH_WETH_100).token1() == Mainnet.WETH, "univ3: t1");
        int24 spacing = IUniswapV3Pool(UNIV3_WSTETH_WETH_100).tickSpacing();
        require(spacing == 1, "univ3: unexpected tickSpacing for fee 100");

        (, int24 currentTick, , , , , ) = IUniswapV3Pool(UNIV3_WSTETH_WETH_100).slot0();
        emit log_named_int("F13-05: pre-mint tick", currentTick);

        // Centre a 3-tick-wide band around the active tick to ensure we stay
        // in range during the victim's swap (which will shift the tick down
        // since WETH->wstETH lifts price of wstETH but here we trade
        // WETH-in -> wstETH-out which means token1 in, token0 out, sqrtP up,
        // tick up for token0=wstETH).
        int24 tickLower = currentTick - spacing;
        int24 tickUpper = currentTick + (2 * spacing);
        emit log_named_int("F13-05: tickLower", tickLower);
        emit log_named_int("F13-05: tickUpper", tickUpper);

        _startPnL();

        // ---- 1. JIT mint: drop liquidity in front of the (about-to-happen) swap ----
        _mintActive = true;
        (uint256 a0, uint256 a1) = IUniswapV3PoolLP(UNIV3_WSTETH_WETH_100).mint(
            address(this),
            tickLower,
            tickUpper,
            JIT_LIQUIDITY,
            ""
        );
        _mintActive = false;
        emit log_named_uint("F13-05: JIT mint wstETH consumed", a0);
        emit log_named_uint("F13-05: JIT mint WETH consumed", a1);

        // ---- 2. "Victim" swap: large WETH -> wstETH through the pool ----
        // Bot would actually watch a third party's pending tx and backrun;
        // we simulate by issuing the swap ourselves.
        IERC20(Mainnet.WETH).approve(Mainnet.UNI_V3_ROUTER, type(uint256).max);
        IUniswapV3Router.ExactInputSingleParams memory p = IUniswapV3Router.ExactInputSingleParams({
            tokenIn: Mainnet.WETH,
            tokenOut: Mainnet.WSTETH,
            fee: FEE_TIER,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: VICTIM_SWAP_WETH,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        uint256 wstethBought = IUniswapV3Router(Mainnet.UNI_V3_ROUTER).exactInputSingle(p);
        emit log_named_uint("F13-05: victim WETH->wstETH bought", wstethBought);

        (, int24 postTick, , , , , ) = IUniswapV3Pool(UNIV3_WSTETH_WETH_100).slot0();
        emit log_named_int("F13-05: post-swap tick", postTick);

        // ---- 3. Burn + collect: capture earned fees + return principal ----
        (uint256 owed0, uint256 owed1) = IUniswapV3PoolLP(UNIV3_WSTETH_WETH_100).burn(
            tickLower,
            tickUpper,
            JIT_LIQUIDITY
        );
        emit log_named_uint("F13-05: burn owed wstETH", owed0);
        emit log_named_uint("F13-05: burn owed WETH", owed1);

        (uint128 col0, uint128 col1) = IUniswapV3PoolLP(UNIV3_WSTETH_WETH_100).collect(
            address(this),
            tickLower,
            tickUpper,
            type(uint128).max,
            type(uint128).max
        );
        emit log_named_uint("F13-05: collected wstETH", col0);
        emit log_named_uint("F13-05: collected WETH", col1);

        _endPnL("F13-05: UniV3 1bp JIT LP + same-block backrun");
    }

    /// @notice UniV3 mint callback.
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata /* data */
    ) external override {
        require(_mintActive, "callback: not active");
        require(msg.sender == UNIV3_WSTETH_WETH_100, "callback: wrong pool");
        if (amount0Owed > 0) IERC20(Mainnet.WSTETH).transfer(msg.sender, amount0Owed);
        if (amount1Owed > 0) IERC20(Mainnet.WETH).transfer(msg.sender, amount1Owed);
    }
}
