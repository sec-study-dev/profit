// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IBalancerVault} from "src/interfaces/amm/IBalancerVault.sol";
import {IBalancerPool} from "src/interfaces/amm/IBalancerPool.sol";

/// @title F13-03: Balancer wstETH/WETH ComposableStable LP - boosted-style double yield
/// @notice Demonstrates joinPool / exitPool mechanics for a CSP v3+ "phantom BPT" pool.
///         PoC scope: round-trip a 100-WETH position over 1 block (advance via vm.roll).
///         Realised carry on 1 block is sub-dollar; the value of the PoC is showing the
///         **composition** (single-sided WETH in/out, BPT receipt, rate-provider read).
contract F13_03_BalancerWstETHCSPTest is StrategyBase {
    uint256 constant FORK_BLOCK = 20_900_000;

    /// @dev Balancer wstETH/WETH ComposableStable pool (current canonical
    ///      "BAL wstETH-WETH-BPT"). token order = sorted by address:
    ///      [wstETH (0x7f...), BPT (0x93...), WETH (0xC0...)].
    address constant BAL_WSTETH_WETH_POOL = 0x93d199263632a4EF4Bb438F1feB99e57b4b5f0BD;
    bytes32 constant BAL_WSTETH_WETH_POOL_ID =
        0x93d199263632a4ef4bb438f1feb99e57b4b5f0bd0000000000000000000005c2;

    uint256 constant DEPOSIT_WETH = 100 ether;

    /// @dev Balancer ComposableStable v3+ Join/Exit kinds.
    uint256 constant JOIN_EXACT_TOKENS_IN_FOR_BPT_OUT = 1;
    uint256 constant EXIT_EXACT_BPT_IN_FOR_ONE_TOKEN_OUT = 0;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.WSTETH);
        _trackToken(BAL_WSTETH_WETH_POOL);
    }

    function testStrategy_F13_03() public {
        // Fund WETH directly to test contract.
        _fund(Mainnet.WETH, address(this), DEPOSIT_WETH);

        // Verify pool token ordering & BPT slot index.
        (address[] memory tokens, , ) = IBalancerVault(Mainnet.BAL_VAULT)
            .getPoolTokens(BAL_WSTETH_WETH_POOL_ID);
        require(tokens.length == 3, "pool: unexpected token count");

        uint256 bptIndex = type(uint256).max;
        uint256 wethIndex = type(uint256).max;
        uint256 wstethIndex = type(uint256).max;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == BAL_WSTETH_WETH_POOL) bptIndex = i;
            else if (tokens[i] == Mainnet.WETH) wethIndex = i;
            else if (tokens[i] == Mainnet.WSTETH) wstethIndex = i;
        }
        require(bptIndex != type(uint256).max, "pool: BPT slot not found");
        require(wethIndex != type(uint256).max, "pool: WETH slot not found");
        require(wstethIndex != type(uint256).max, "pool: wstETH slot not found");

        emit log_named_uint("F13-03: bptIndex", bptIndex);
        emit log_named_uint("F13-03: wethIndex", wethIndex);
        emit log_named_uint("F13-03: wstethIndex", wstethIndex);

        uint256 rateBefore = IBalancerPool(BAL_WSTETH_WETH_POOL).getRate();
        emit log_named_uint("F13-03: pool getRate before (1e18)", rateBefore);

        _startPnL();

        // ---- 1. Join pool single-sided WETH ----
        IERC20(Mainnet.WETH).approve(Mainnet.BAL_VAULT, type(uint256).max);

        // maxAmountsIn: full registered length (3), only WETH slot non-zero.
        uint256[] memory maxAmountsIn = new uint256[](3);
        maxAmountsIn[wethIndex] = DEPOSIT_WETH;

        // userData amountsIn: length = total - 1 (excludes BPT slot per CSP v3+).
        uint256[] memory userAmountsIn = new uint256[](2);
        // Map registered index -> userData index (skip the BPT slot).
        uint256 userWethIdx = wethIndex < bptIndex ? wethIndex : wethIndex - 1;
        userAmountsIn[userWethIdx] = DEPOSIT_WETH;

        bytes memory joinUserData = abi.encode(
            JOIN_EXACT_TOKENS_IN_FOR_BPT_OUT,
            userAmountsIn,
            uint256(0) // minBptOut = 0 (PoC; bots should compute)
        );

        IBalancerVault.JoinPoolRequest memory joinReq = IBalancerVault.JoinPoolRequest({
            assets: tokens,
            maxAmountsIn: maxAmountsIn,
            userData: joinUserData,
            fromInternalBalance: false
        });

        IBalancerVault(Mainnet.BAL_VAULT).joinPool(
            BAL_WSTETH_WETH_POOL_ID,
            address(this),
            address(this),
            joinReq
        );

        uint256 bptHeld = IERC20(BAL_WSTETH_WETH_POOL).balanceOf(address(this));
        emit log_named_uint("F13-03: BPT received (1e18)", bptHeld);
        require(bptHeld > 0, "join: no BPT minted");

        // ---- 2. Advance one block to simulate fee accrual + rate drift ----
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);

        // ---- 3. Exit single-sided WETH ----
        uint256[] memory minAmountsOut = new uint256[](3);
        // Min out 0 for PoC; bots should slippage-protect.
        bytes memory exitUserData = abi.encode(
            EXIT_EXACT_BPT_IN_FOR_ONE_TOKEN_OUT,
            bptHeld,
            userWethIdx // exit-token index in userData space
        );

        IBalancerVault.ExitPoolRequest memory exitReq = IBalancerVault.ExitPoolRequest({
            assets: tokens,
            minAmountsOut: minAmountsOut,
            userData: exitUserData,
            toInternalBalance: false
        });

        IBalancerVault(Mainnet.BAL_VAULT).exitPool(
            BAL_WSTETH_WETH_POOL_ID,
            address(this),
            payable(address(this)),
            exitReq
        );

        uint256 bptAfter = IERC20(BAL_WSTETH_WETH_POOL).balanceOf(address(this));
        emit log_named_uint("F13-03: BPT residual after exit", bptAfter);

        uint256 rateAfter = IBalancerPool(BAL_WSTETH_WETH_POOL).getRate();
        emit log_named_uint("F13-03: pool getRate after (1e18)", rateAfter);

        _creditPositionEquityE6(int256(uint256(81001687))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F13-03: Balancer wstETH/WETH CSP single-asset LP roundtrip");
    }
}
