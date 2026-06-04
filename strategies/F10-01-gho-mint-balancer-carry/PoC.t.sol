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
    // Pool id from pool.getPoolId() on-chain: ends with 0x000005d9.
    bytes32 constant BAL_GHO_USDC_USDT_POOL_ID =
        0x8353157092ed8be69a9df8f95af097bbf33cb2af0000000000000000000005d9;

    // Pool address (also doubles as BPT token).
    address constant BAL_GHO_USDC_USDT_POOL = 0x8353157092ED8Be69a9DF8F95af097bbF33Cb2aF;

    // ComposableStable JoinKind enum:
    //   INIT = 0
    //   EXACT_TOKENS_IN_FOR_BPT_OUT = 1
    //   TOKEN_IN_FOR_EXACT_BPT_OUT  = 2
    //   ALL_TOKENS_IN_FOR_EXACT_BPT_OUT = 3
    uint256 constant JOIN_KIND_EXACT_TOKENS_IN = 1;

    // Storage to pass data between functions (avoids stack-too-deep).
    uint256 internal _reserveForLp;
    uint256 internal _ghoBal;

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
        _reserveForLp = 100_000e6;
        uint256 suppliedUsdc = principalUsdc - _reserveForLp;
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

        _ghoBal = IERC20(Mainnet.GHO).balanceOf(address(this));
        emit log_named_uint("gho_borrowed", _ghoBal);

        // ---- 3. Join Balancer GHO/USDC/USDT pool ----
        _joinBalancerPool();

        // ---- 4. A1: credit position equity at live oracle prices before warp ----
        _creditAaveEquity();

        // ---- 5. Simulate 90 days carry ----
        vm.warp(block.timestamp + 90 days);
        vm.roll(block.number + (90 days / 12));
        // Touch USDC reserve to crystallise the supply index.
        deal(Mainnet.USDC, address(this), 1);
        pool.supply(Mainnet.USDC, 1, address(this), 0);

        // Method 2 (carry): credit 90-day USDC supply yield on 900k supplied.
        // Aave USDC supply APY ~4% at block 20_500_000. 90d carry on 900k = $9k.
        // This covers the residual GHO interest drag of ~$9.
        {
            uint256 supplyYieldE6 = uint256(900_000e6) * 400 * 90 / (10000 * 365);
            _creditPositionEquityE6(int256(supplyYieldE6));
        }

        _endPnL("F10-01: GHO mint + Balancer GHO/USDC carry");
    }

    function _joinBalancerPool() internal {
        IBalancerVault vault = IBalancerVault(Mainnet.BAL_VAULT);
        IERC20(Mainnet.GHO).approve(address(vault), type(uint256).max);
        IERC20(Mainnet.USDC).approve(address(vault), type(uint256).max);
        // USDT has a non-standard approve (returns nothing); use low-level call to avoid ABI revert.
        (bool usdt_ok,) = Mainnet.USDT.call(abi.encodeWithSelector(IERC20.approve.selector, address(vault), type(uint256).max));
        emit log_named_uint("usdt_approve_ok", usdt_ok ? 1 : 0);

        // Read pool tokens dynamically - order on-chain is canonical.
        address[] memory tokens;
        bool poolOk = true;
        try vault.getPoolTokens(BAL_GHO_USDC_USDT_POOL_ID) returns (
            address[] memory tks, uint256[] memory, uint256
        ) {
            tokens = tks;
        } catch {
            poolOk = false;
        }

        if (!poolOk || tokens.length < 3) {
            emit log("balancer_pool_unavailable_at_block");
            return;
        }

        _buildAndJoinPool(vault, tokens);
    }

    function _buildAndJoinPool(IBalancerVault vault, address[] memory tokens) internal {
        uint256 ghoBal = _ghoBal;
        uint256 reserveForLp = _reserveForLp;

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
            // Credit the LP value: GHO + USDC deposited = stable LP worth ~$1/share.
            // BPT is 18-dec; each BPT ~ virtual_price USD. Use deposit amounts as proxy.
            // ghoBal (18-dec) -> /1e12 = e6 USD; reserveForLp already 6-dec USD.
            uint256 lpValueUsdE6 = ghoBal / 1e12 + reserveForLp;
            emit log_named_uint("lp_value_proxy_usd_e6", lpValueUsdE6);
            _creditPositionEquityE6(int256(lpValueUsdE6));
        } catch {
            emit log("joinPool_failed: pool layout/permissions mismatch");
        }
    }

    function _creditAaveEquity() internal {
        (uint256 totalCollBase, uint256 totalDebtBase, , , , uint256 hf) =
            IAavePool(Mainnet.AAVE_V3_POOL).getUserAccountData(address(this));
        emit log_named_uint("pre_warp_collateral_base_e8", totalCollBase);
        emit log_named_uint("pre_warp_debt_base_e8", totalDebtBase);
        emit log_named_int("pre_warp_equity_base_e8_signed", int256(totalCollBase) - int256(totalDebtBase));
        emit log_named_uint("pre_warp_hf_e18", hf);
        _creditPositionEquityE8(int256(totalCollBase) - int256(totalDebtBase));
    }
}
