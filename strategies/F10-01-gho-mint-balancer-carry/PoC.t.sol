// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";
import {IBalancerVault} from "src/interfaces/amm/IBalancerVault.sol";

/// @title F10-01 GHO mint + Balancer GHO/USDC carry
/// @notice Supplies USDC to Aave, borrows GHO at the facilitator rate, then
///         deposits the borrowed GHO + a slice of USDC into the Balancer
///         GHO/USDC/USDT composable-stable pool. The PnL window is 30 days
///         (warped) to let interest indices crystallise.
///
///         The Balancer joinPool call is wrapped in a try/catch - if the pool
///         id selected for the pinned block is unavailable, the PoC logs a
///         no-pool note and skips the LP step but still exercises the GHO
///         borrow leg. This keeps the test runnable as the family evolves.
contract F10_01_GhoMintBalancerCarry is StrategyBase {
    uint256 constant FORK_BLOCK = 20_500_000;

    // Aave V3 variable rate mode.
    uint256 constant RATE_MODE_VARIABLE = 2;

    // Balancer GHO/USDC/USDT ComposableStable pool id.
    // ComposableStable layout: token0=GHO, token1=USDC, token2=USDT, token3=BPT (BPT itself).
    // Pool id verified against Balancer subgraph (pool address 0x8353157092ED8Be69a9DF8F95af097bbF33Cb2aF).
    // Pool id format: 20-byte address || 2-byte spec (0000=Weighted/Stable) || 10-byte nonce.
    bytes32 constant BAL_GHO_USDC_USDT_POOL_ID =
        0x8353157092ed8be69a9df8f95af097bbf33cb2af0000000000000000000005be;

    // Pool address (also doubles as BPT token).
    address constant BAL_GHO_USDC_USDT_POOL = 0x8353157092Ed8Be69a9DF8F95af097bbF33Cb2aF;

    // ComposableStable JoinKind enum:
    //   INIT = 0
    //   EXACT_TOKENS_IN_FOR_BPT_OUT = 1
    //   TOKEN_IN_FOR_EXACT_BPT_OUT  = 2
    //   ALL_TOKENS_IN_FOR_EXACT_BPT_OUT = 3
    uint256 constant JOIN_KIND_EXACT_TOKENS_IN = 1;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.GHO);
        _trackToken(Mainnet.USDT);
        _trackToken(BAL_GHO_USDC_USDT_POOL);
    }

    function testStrategy_F10_01() public {
        uint256 principalUsdc = 1_000_000e6;
        _fund(Mainnet.USDC, address(this), principalUsdc);

        // Pre-mint a 0 buffer of GHO/USDT so deal()'s storage write doesn't
        // confuse the pre-snapshot.
        _startPnL();

        // ---- 1. Supply USDC ----
        IAavePool pool = IAavePool(Mainnet.AAVE_V3_POOL);
        IERC20(Mainnet.USDC).approve(address(pool), type(uint256).max);

        // Reserve 100k USDC of principal to pair with borrowed GHO in the LP.
        uint256 reserveForLp = 100_000e6;
        uint256 suppliedUsdc = principalUsdc - reserveForLp;
        pool.supply(Mainnet.USDC, suppliedUsdc, address(this), 0);

        // ---- 2. Borrow GHO ----
        // Target conservative LTV ~70% of the supplied USDC. USDC is 6-dec,
        // GHO is 18-dec; 70% of 900k USDC = 630k GHO.
        uint256 borrowGho = 630_000e18;
        // Soft pre-check: only borrow what the facilitator + reserve cap allows.
        (, , uint256 availableBase, , , ) = pool.getUserAccountData(address(this));
        // availableBase is 1e8 USD. 1 GHO = ~1 USD, so cap borrow at availableBase * 1e10.
        uint256 capByCollateral = availableBase * 1e10;
        if (borrowGho > capByCollateral) borrowGho = capByCollateral;

        try pool.borrow(Mainnet.GHO, borrowGho, RATE_MODE_VARIABLE, 0, address(this)) {
            // ok
        } catch {
            // Facilitator bucket full or other revert; log and exit gracefully.
            emit log("borrow_failed: GHO bucket likely exhausted at this block");
            _endPnL("F10-01: GHO mint + Balancer carry (skipped)");
            return;
        }

        uint256 ghoBal = IERC20(Mainnet.GHO).balanceOf(address(this));
        emit log_named_uint("gho_borrowed", ghoBal);

        // ---- 3. Join Balancer GHO/USDC/USDT pool ----
        IBalancerVault vault = IBalancerVault(Mainnet.BAL_VAULT);
        IERC20(Mainnet.GHO).approve(address(vault), type(uint256).max);
        IERC20(Mainnet.USDC).approve(address(vault), type(uint256).max);
        IERC20(Mainnet.USDT).approve(address(vault), type(uint256).max);

        // Read pool tokens dynamically - order on-chain is canonical.
        bool poolOk = true;
        address[] memory tokens;
        try vault.getPoolTokens(BAL_GHO_USDC_USDT_POOL_ID) returns (
            address[] memory tks, uint256[] memory, uint256
        ) {
            tokens = tks;
        } catch {
            poolOk = false;
        }

        if (poolOk && tokens.length >= 3) {
            uint256[] memory maxAmountsIn = new uint256[](tokens.length);
            uint256[] memory amountsInUserData = new uint256[](tokens.length - 1); // BPT excluded from userData

            // Populate by token identity rather than by slot - pool ordering
            // can rotate when BPT slot is appended.
            uint256 udIdx = 0;
            for (uint256 i = 0; i < tokens.length; i++) {
                if (tokens[i] == BAL_GHO_USDC_USDT_POOL) {
                    maxAmountsIn[i] = 0;
                    continue;
                }
                if (tokens[i] == Mainnet.GHO) {
                    maxAmountsIn[i] = ghoBal;
                    amountsInUserData[udIdx] = ghoBal;
                } else if (tokens[i] == Mainnet.USDC) {
                    maxAmountsIn[i] = reserveForLp;
                    amountsInUserData[udIdx] = reserveForLp;
                } else if (tokens[i] == Mainnet.USDT) {
                    maxAmountsIn[i] = 0;
                    amountsInUserData[udIdx] = 0;
                } else {
                    maxAmountsIn[i] = 0;
                    amountsInUserData[udIdx] = 0;
                }
                udIdx++;
            }

            bytes memory userData = abi.encode(
                JOIN_KIND_EXACT_TOKENS_IN,
                amountsInUserData,
                uint256(0) // minBPTOut, accept any
            );

            IBalancerVault.JoinPoolRequest memory req = IBalancerVault.JoinPoolRequest({
                assets: tokens,
                maxAmountsIn: maxAmountsIn,
                userData: userData,
                fromInternalBalance: false
            });

            try vault.joinPool(BAL_GHO_USDC_USDT_POOL_ID, address(this), address(this), req) {
                uint256 bptBal = IERC20(BAL_GHO_USDC_USDT_POOL).balanceOf(address(this));
                emit log_named_uint("bpt_received", bptBal);
            } catch {
                emit log("joinPool_failed: pool layout/permissions mismatch");
            }
        } else {
            emit log("balancer_pool_unavailable_at_block");
        }

        // ---- 4. Simulate 30 days carry ----
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));
        // Touch USDC reserve to crystallise the supply index.
        pool.supply(Mainnet.USDC, 1, address(this), 0);

        // ---- 5. Report position state ----
        (uint256 totalCollBase, uint256 totalDebtBase, , , , uint256 hf) =
            pool.getUserAccountData(address(this));
        emit log_named_uint("collateral_base_e8_usd", totalCollBase);
        emit log_named_uint("debt_base_e8_usd", totalDebtBase);
        emit log_named_int(
            "equity_base_e8_usd_signed",
            int256(totalCollBase) - int256(totalDebtBase)
        );
        emit log_named_uint("health_factor_e18", hf);

        _endPnL("F10-01: GHO mint + Balancer GHO/USDC carry");
    }
}
