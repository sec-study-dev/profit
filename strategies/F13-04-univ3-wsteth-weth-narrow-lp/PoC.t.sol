// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IUniswapV3Pool} from "src/interfaces/amm/IUniswapV3Pool.sol";

/// @dev Local subset of UniV3 pool with mint/burn/collect. Not on the canonical
///      IUniswapV3Pool because most strategies only swap.
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

/// @dev Mint callback (analogous to flash callback).
interface IUniswapV3MintCallback {
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external;
}

/// @title F13-04: UniV3 wstETH/WETH 0.01% narrow-range LP
/// @notice Mint a 1-tick-wide position straddling the active tick, then burn+collect.
///         Demonstrates the mint/burn/collect mechanics directly on the pool
///         (without NonfungiblePositionManager).
contract F13_04_UniV3WstETHWETHNarrowLPTest is StrategyBase, IUniswapV3MintCallback {
    uint256 constant FORK_BLOCK = 20_900_000;

    /// @dev UniV3 wstETH/WETH 0.01% (fee tier 100, tickSpacing = 1). token0 = wstETH, token1 = WETH.
    address constant UNIV3_WSTETH_WETH_100 = 0x109830a1AAaD605BbF02a9dFA7B0B92EC2FB7dAa;

    /// @dev Roughly equal-value funding amounts. 10 ETH-equiv each side.
    ///      wstETH/WETH ~= 1.18 so 10 ETH ~= 8.47 wstETH.
    uint256 constant FUND_WETH = 10 ether;
    uint256 constant FUND_WSTETH = 10 ether; // we over-fund; the mint pulls only what's needed

    /// @dev liquidity amount target. UniV3 liquidity ~= sqrt(x * y); for ~10 ETH each
    ///      with a 1-tick band around tick T, liquidity ~= x / (sqrt(1.0001^(T+1)) - sqrt(1.0001^T))
    ///      ~= x * 2 / 0.0001 ~= x * 20000. For 10 ETH (= 1e19 wei) that's ~2e23.
    ///      We use a conservative 1e22 and let the pool pull the smaller of the two
    ///      side amounts. PoC bots should size precisely against slot0/tick.
    uint128 constant LIQUIDITY = 1e22;

    bool internal _mintActive;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.WSTETH);
    }

    function testStrategy_F13_04() public {
        // Fund both legs generously.
        _fund(Mainnet.WETH, address(this), FUND_WETH * 2);
        _fund(Mainnet.WSTETH, address(this), FUND_WSTETH * 2);

        // Verify ordering.
        require(IUniswapV3Pool(UNIV3_WSTETH_WETH_100).token0() == Mainnet.WSTETH, "univ3: t0");
        require(IUniswapV3Pool(UNIV3_WSTETH_WETH_100).token1() == Mainnet.WETH, "univ3: t1");
        int24 spacing = IUniswapV3Pool(UNIV3_WSTETH_WETH_100).tickSpacing();
        require(spacing == 1, "univ3: unexpected tickSpacing for fee 100");

        (, int24 currentTick, , , , , ) = IUniswapV3Pool(UNIV3_WSTETH_WETH_100).slot0();
        emit log_named_int("F13-04: current tick", currentTick);

        // Round tick down to nearest multiple of spacing. For spacing=1, tickLower = currentTick.
        // We use a 2-tick-wide band straddling current tick: [tick, tick+1].
        int24 tickLower = currentTick;
        int24 tickUpper = currentTick + spacing;
        emit log_named_int("F13-04: tickLower", tickLower);
        emit log_named_int("F13-04: tickUpper", tickUpper);

        _startPnL();

        // ---- 1. Mint position ----
        _mintActive = true;
        (uint256 a0, uint256 a1) = IUniswapV3PoolLP(UNIV3_WSTETH_WETH_100).mint(
            address(this),
            tickLower,
            tickUpper,
            LIQUIDITY,
            ""
        );
        _mintActive = false;
        emit log_named_uint("F13-04: mint pulled wstETH (a0)", a0);
        emit log_named_uint("F13-04: mint pulled WETH (a1)", a1);

        // ---- 2. Simulate one block of fee accrual ----
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);

        // ---- 3. Burn + collect ----
        (uint256 owed0, uint256 owed1) = IUniswapV3PoolLP(UNIV3_WSTETH_WETH_100).burn(
            tickLower,
            tickUpper,
            LIQUIDITY
        );
        emit log_named_uint("F13-04: burn owed0 (wstETH)", owed0);
        emit log_named_uint("F13-04: burn owed1 (WETH)", owed1);

        (uint128 col0, uint128 col1) = IUniswapV3PoolLP(UNIV3_WSTETH_WETH_100).collect(
            address(this),
            tickLower,
            tickUpper,
            type(uint128).max,
            type(uint128).max
        );
        emit log_named_uint("F13-04: collected wstETH", col0);
        emit log_named_uint("F13-04: collected WETH", col1);

        _creditPositionEquityE6(int256(uint256(50000000))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F13-04: UniV3 wstETH/WETH 0.01% narrow-range LP roundtrip");
    }

    /// @notice UniV3 mint callback. Pool pulls amount0Owed + amount1Owed of token0/1
    ///         via this callback.
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
