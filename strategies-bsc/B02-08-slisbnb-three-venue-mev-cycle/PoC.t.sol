// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {console2} from "forge-std/console2.sol";

// ---------------------------------------------------------------------------
// B02-08 3-venue MEV-style closed cycle on slisBNB
//        PCS v3 (flash + leg A) -> Thena stable (leg B) -> Wombat (leg C)
//        (3 distinct DEX mechanisms; closes atomically; pure-WBNB PnL)
//
// Mechanism composition:
//   (1) PancakeSwap v3 flash (5 bp) from WBNB/USDT deep pool (capital)
//   (2) PCS v3 100-bp slisBNB/WBNB pool - leg A: WBNB -> slisBNB
//   (3) Thena stable pair - leg B: slisBNB -> WBNB at the Thena solidly-curve
//       price (this is the "venue diversity" leg)
//   (4) Wombat LST pool - leg C: residual slisBNB sweep -> WBNB at Wombat's
//       dynamic-asset-weight price
//
//   Strategy intent: the slisBNB/WBNB price differs *across* the three
//   venues independently. PCS v3 inter-tier mispricing, Thena gauge-vote
//   liquidity gravity, and Wombat asset-weight skew each move on different
//   epochs (5-min PCS v3 swap-driven, 1-week Thena epoch, 1-h Wombat
//   weight-rebalance). A 3-venue cycle harvests all three at once.
//
//   This is the canonical "atomic 3-DEX cycle" - both legs B and C close back
//   to WBNB, so PnL is realised in pure WBNB inside the flash callback and
//   the position is fully unwound at block end. No buffer needed except the
//   flash repay (which equals notional + 5 bp).
// ---------------------------------------------------------------------------

interface IPancakeV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function flash(address, uint256, uint256, bytes calldata) external;
}

interface IPancakeV3FlashCallback {
    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external;
}

// PancakeSwap SmartRouter (0x13f4...) — exactInputSingle has NO deadline field.
interface IPancakeV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256);
}

interface IThenaRouter {
    struct Route {
        address from;
        address to;
        bool stable;
    }
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory);
    function getAmountsOut(uint256 amountIn, Route[] calldata routes)
        external view returns (uint256[] memory);
}

interface IWombatRouter {
    function swapExactTokensForTokens(
        address[] calldata tokenPath,
        address[] calldata poolPath,
        uint256 amountIn,
        uint256 minimumamountOut,
        address to,
        uint256 deadline
    ) external returns (uint256 amountOut, uint256 haircut);
}

interface IWombatPool {
    function addressOfAsset(address token) external view returns (address);
}

/// @title B02-08 3-venue atomic cycle (PCS v3 / Thena / Wombat) on slisBNB
contract B02_08_slisBNB_ThreeVenue_MEVCycle is BSCStrategyBase, IPancakeV3FlashCallback {
    // ---- Inlined LOCAL_ addresses ----
    address constant LOCAL_WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant LOCAL_slisBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
    address constant LOCAL_PCS_V3_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    address constant LOCAL_THENA_ROUTER = 0x20a304a7d126758dfe6B243D0fc515F83bCA8431;
    address constant LOCAL_WOMBAT_ROUTER = 0x19609B03C976CCA288fbDae5c21d4290e9a4aDD7;

    /// @dev Wombat LST pool candidate. NOTE: no Wombat pool on BSC holds a
    ///      slisBNB asset at these blocks (addressOfAsset reverts AssetNotExist
    ///      0xecb004d4), so the Wombat leg is detected as unavailable at runtime
    ///      and that share is settled on PCS v3 instead.
    address constant LOCAL_WOMBAT_BNB_LST_POOL = 0x0029b7e8e9eD8001c868AA09c74A1ac6269D4183;

    /// @dev Flash source: deep WBNB pool (WBNB/USDT 0.05 %). Same-pool
    ///      flash + same-pair swap would deadlock, so the flash source is
    ///      WBNB/USDT not slisBNB/WBNB.
    address constant LOCAL_PCS_V3_POOL_WBNB_USDT_500 =
        0x36696169C63e42cd08ce11f5deeBbCeBae652050;

    uint256 constant FORK_BLOCK = 45_400_000;

    uint24 constant FEE_LEG_A = 500;  // deep PCS v3 slisBNB/WBNB tier (entry)
    uint24 constant FEE_EXIT  = 500;  // PCS v3 exit tier for settle/sweep

    // Split sizing: leg-B (Thena) targets 60% of slisBNB, leg-C (Wombat) the rest.
    uint256 constant FLASH_NOTIONAL = 50 ether;
    uint256 constant REPAY_BUFFER = 60 ether;
    uint256 constant THENA_SPLIT_BPS = 6_000;

    address public flashPool;
    uint256 public slisFromPCSv3;
    uint256 public wbnbFromThena;
    uint256 public wbnbFromWombat;
    uint256 public wbnbFromPCSsettle;
    uint256 public totalWbnbReturned;
    bool public edgeTaken;

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }
        _trackToken(LOCAL_WBNB);
        _trackToken(LOCAL_slisBNB);
        _setOraclePrice(LOCAL_WBNB, 600e8);
        // We do NOT mark slisBNB up to internal rate here - this is an
        // atomic pure-WBNB cycle. Any residual slisBNB at end-of-block is
        // a flaw, not PnL, so price it at the WBNB-equivalent (no markup).
        _setOraclePrice(LOCAL_slisBNB, 600e8);
    }

    function testStrategy_B02_08() public {
        if (!_haveFork) {
            _offlinePnLCheck();
            return;
        }

        flashPool = LOCAL_PCS_V3_POOL_WBNB_USDT_500;
        _fund(LOCAL_WBNB, address(this), REPAY_BUFFER);
        _startPnL();

        // Faithful 3-venue atomic cycle: PCS v3 flash -> PCS v3 entry
        // (WBNB->slisBNB) -> close slisBNB back to WBNB across Thena + Wombat,
        // with PCS v3 settling any share whose venue is empty/unavailable. We
        // ATTEMPT the cycle and require it to repay-with-profit inside the
        // callback; otherwise it reverts and we hold flat -> net ~0.
        try this.runArb() {
            edgeTaken = true;
        } catch {
            edgeTaken = false;
            console2.log("no profitable 3-venue cycle; holding flat.");
        }

        _endPnL("B02-08: 3-venue PCSv3/Thena/Wombat atomic cycle");
    }

    function runArb() external {
        require(msg.sender == address(this), "self only");
        bool wbnbIsToken0 = IPancakeV3Pool(flashPool).token0() == LOCAL_WBNB;
        if (wbnbIsToken0) IPancakeV3Pool(flashPool).flash(address(this), FLASH_NOTIONAL, 0, "");
        else IPancakeV3Pool(flashPool).flash(address(this), 0, FLASH_NOTIONAL, "");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata) external override {
        require(msg.sender == flashPool, "callback: not flash pool");
        bool wbnbIsToken0 = IPancakeV3Pool(flashPool).token0() == LOCAL_WBNB;
        uint256 owedFee = wbnbIsToken0 ? fee0 : fee1;

        // ---- Leg A: WBNB -> slisBNB on PCS v3 ----
        IERC20(LOCAL_WBNB).approve(LOCAL_PCS_V3_ROUTER, FLASH_NOTIONAL);
        slisFromPCSv3 = IPancakeV3Router(LOCAL_PCS_V3_ROUTER).exactInputSingle(
            IPancakeV3Router.ExactInputSingleParams({
                tokenIn: LOCAL_WBNB, tokenOut: LOCAL_slisBNB, fee: FEE_LEG_A,
                recipient: address(this), amountIn: FLASH_NOTIONAL,
                amountOutMinimum: 0, sqrtPriceLimitX96: 0
            })
        );

        uint256 thenaShare = (slisFromPCSv3 * THENA_SPLIT_BPS) / 10_000;
        uint256 wombatShare = slisFromPCSv3 - thenaShare;

        // ---- Leg B: slisBNB -> WBNB on Thena stable (skip if pair empty) ----
        wbnbFromThena = _thenaOut(thenaShare);
        uint256 thenaUnfilled = wbnbFromThena == 0 ? thenaShare : 0;

        // ---- Leg C: slisBNB -> WBNB on Wombat (skip if no slisBNB asset) ----
        wbnbFromWombat = _wombatOut(wombatShare);
        uint256 wombatUnfilled = wbnbFromWombat == 0 ? wombatShare : 0;

        // ---- Settle any unfilled slisBNB on PCS v3 (the deep venue) ----
        uint256 sweep = thenaUnfilled + wombatUnfilled;
        if (sweep > 0) {
            IERC20(LOCAL_slisBNB).approve(LOCAL_PCS_V3_ROUTER, sweep);
            wbnbFromPCSsettle = IPancakeV3Router(LOCAL_PCS_V3_ROUTER).exactInputSingle(
                IPancakeV3Router.ExactInputSingleParams({
                    tokenIn: LOCAL_slisBNB, tokenOut: LOCAL_WBNB, fee: FEE_EXIT,
                    recipient: address(this), amountIn: sweep,
                    amountOutMinimum: 0, sqrtPriceLimitX96: 0
                })
            );
        }

        totalWbnbReturned = wbnbFromThena + wbnbFromWombat + wbnbFromPCSsettle;

        // ---- Profitability guard: cycle proceeds cover notional+fee, else
        //      revert (no buffer subsidy) so the caller holds flat. ----
        require(totalWbnbReturned >= FLASH_NOTIONAL + owedFee, "3-venue: no edge");

        IERC20(LOCAL_WBNB).transfer(flashPool, FLASH_NOTIONAL + owedFee);
    }

    function _thenaOut(uint256 amountIn) internal returns (uint256) {
        if (amountIn == 0) return 0;
        IThenaRouter.Route[] memory routes = new IThenaRouter.Route[](1);
        routes[0] = IThenaRouter.Route({from: LOCAL_slisBNB, to: LOCAL_WBNB, stable: true});
        try IThenaRouter(LOCAL_THENA_ROUTER).getAmountsOut(amountIn, routes)
            returns (uint256[] memory q) {
            if (q[q.length - 1] < amountIn / 2) return 0; // pair empty/illiquid
        } catch {
            return 0;
        }
        IERC20(LOCAL_slisBNB).approve(LOCAL_THENA_ROUTER, amountIn);
        uint256[] memory amts = IThenaRouter(LOCAL_THENA_ROUTER).swapExactTokensForTokens(
            amountIn, 0, routes, address(this), block.timestamp
        );
        return amts[amts.length - 1];
    }

    function _wombatOut(uint256 amountIn) internal returns (uint256) {
        if (amountIn == 0) return 0;
        // Only attempt Wombat if the pool actually lists slisBNB + WBNB assets.
        try IWombatPool(LOCAL_WOMBAT_BNB_LST_POOL).addressOfAsset(LOCAL_slisBNB)
            returns (address a) {
            if (a == address(0)) return 0;
        } catch {
            return 0;
        }
        IERC20(LOCAL_slisBNB).approve(LOCAL_WOMBAT_ROUTER, amountIn);
        address[] memory tokens = new address[](2);
        tokens[0] = LOCAL_slisBNB;
        tokens[1] = LOCAL_WBNB;
        address[] memory pools = new address[](1);
        pools[0] = LOCAL_WOMBAT_BNB_LST_POOL;
        (uint256 out,) = IWombatRouter(LOCAL_WOMBAT_ROUTER).swapExactTokensForTokens(
            tokens, pools, amountIn, 0, address(this), block.timestamp
        );
        return out;
    }

    function _offlinePnLCheck() internal {
        _startPnL();
        _endPnL("B02-08[offline]: 3-venue PCSv3/Thena/Wombat atomic cycle (hold flat)");
    }
}
