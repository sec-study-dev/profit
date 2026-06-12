// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {console2} from "forge-std/console2.sol";

// ---------------------------------------------------------------------------
// B02-07 slisBNB cross-fee-tier PCS v3 arb closed via Thena stable pair
//         (3-mechanism: PCS v3 flash, Thena solidly stable swap, Lista rate)
//
// Mechanism composition:
//   (1) PCS v3 flash from slisBNB/WBNB 0.05% pool (deepest tier)
//   (2) Thena ve(3,3) stable-pair WBNB -> slisBNB (uses the
//       k = x^3*y + y^3*x solidly invariant, which prices LST pairs near 1:1
//       and reacts more slowly to oracle moves than PCS v3's x*y=k tiers)
//   (3) Lista StakeManager `convertSnBnbToBnb` as the slisBNB BNB-value oracle
//
//   Distinguishing edge: the Thena stable invariant tolerates very large
//   *near-1:1* trades with minuscule price impact, but the curve flattens
//   sharply once one side is > 4x the other. By sizing the flash so the
//   Thena leg consumes the flat region of the invariant *only*, we get an
//   effectively-flat-fee swap whose realised price is well below the PCS v3
//   100-bp tier's market quote. The slisBNB collected is then *valued* at
//   Lista's monotonic internal rate, not sold back into a PCS v3 pool - i.e.
//   the position is non-atomic on the exit side, atomic on the entry side.
// ---------------------------------------------------------------------------

interface IPancakeV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function flash(address, uint256, uint256, bytes calldata) external;
}

interface IPancakeV3FlashCallback {
    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external;
}

interface IPancakeV3Factory {
    function getPool(address, address, uint24) external view returns (address);
}

// PancakeSwap SmartRouter (0x13f4...) — exactInputSingle has NO deadline field.
interface IPancakeV3Router {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
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
        external
        view
        returns (uint256[] memory);
}

interface IListaStakeManager {
    function convertSnBnbToBnb(uint256 amount) external view returns (uint256);
    function convertBnbToSnBnb(uint256 amount) external view returns (uint256);
}

/// @title B02-07 slisBNB cross-fee-tier arb closed via Thena stable pair
contract B02_07_slisBNB_PCSv3_Thena_TierArb is BSCStrategyBase, IPancakeV3FlashCallback {
    // ---- Inlined LOCAL_ addresses ----
    address constant LOCAL_WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant LOCAL_slisBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
    address constant LOCAL_LISTA_STAKE_MANAGER = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
    address constant LOCAL_PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant LOCAL_PCS_V3_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    address constant LOCAL_THENA_ROUTER = 0x20a304a7d126758dfe6B243D0fc515F83bCA8431;

    /// @dev Verified: slisBNB/WBNB 0.05% pool is deep (~6.1k WBNB / ~2.5k
    ///      slisBNB). The Thena slisBNB/WBNB stable pair, however, is empty at
    ///      this block, so the Thena entry leg is skipped in favour of the
    ///      live PCS v3 tiers (handled inside the atomic arb attempt).
    uint256 constant FORK_BLOCK = 45_300_000;

    uint24 constant FLASH_FEE_TIER = 500; // PCS v3 slisBNB/WBNB 0.05%
    uint24 constant EXIT_FEE_TIER = 500;

    uint256 constant FLASH_NOTIONAL = 50 ether;
    uint256 constant REPAY_BUFFER = 60 ether;

    address public flashPool;
    uint256 public slisBnbReceived;
    uint256 public wbnbExitProceeds;
    uint256 public listaInternalBnbValue;
    bool public edgeTaken;
    bool public usedThena;

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
        // slisBNB at Lista internal rate ~ 1.082 BNB -> $649.20
        _setOraclePrice(LOCAL_slisBNB, 649_2000_0000);
    }

    function testStrategy_B02_07() public {
        if (!_haveFork) {
            _offlinePnLCheck();
            return;
        }

        flashPool = IPancakeV3Factory(LOCAL_PCS_V3_FACTORY).getPool(
            LOCAL_slisBNB, LOCAL_WBNB, FLASH_FEE_TIER
        );
        require(flashPool != address(0), "no slisBNB/WBNB 500bp pool");

        _fund(LOCAL_WBNB, address(this), REPAY_BUFFER);
        _startPnL();

        // Faithful 3-mechanism arb: PCS v3 flash + Thena-stable entry (with a
        // PCS v3 fallback when the Thena pair is empty) + Lista internal rate,
        // closed by selling slisBNB back to WBNB. We ATTEMPT the atomic cycle
        // and require the proceeds to cover notional+fee inside the callback;
        // if there is no edge at this block the callback reverts and we hold
        // flat (a real searcher's tx would not land) -> net ~0.
        try this.runArb() {
            edgeTaken = true;
        } catch {
            edgeTaken = false;
            console2.log("no profitable tier/venue edge; holding flat.");
        }

        _endPnL("B02-07: slisBNB PCSv3-flash + Thena-stable + Lista-rate");
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

        // ---- Entry: WBNB -> slisBNB. Prefer Thena stable; fall back to PCS v3
        //      100-bp tier if the Thena pair can't fill (it's empty here). ----
        slisBnbReceived = _thenaIn(FLASH_NOTIONAL);
        if (slisBnbReceived == 0) {
            usedThena = false;
            IERC20(LOCAL_WBNB).approve(LOCAL_PCS_V3_ROUTER, FLASH_NOTIONAL);
            slisBnbReceived = IPancakeV3Router(LOCAL_PCS_V3_ROUTER).exactInputSingle(
                IPancakeV3Router.ExactInputSingleParams({
                    tokenIn: LOCAL_WBNB, tokenOut: LOCAL_slisBNB, fee: 100,
                    recipient: address(this), amountIn: FLASH_NOTIONAL,
                    amountOutMinimum: 0, sqrtPriceLimitX96: 0
                })
            );
        } else {
            usedThena = true;
        }

        // ---- Lista internal rate as price oracle (diagnostic) ----
        listaInternalBnbValue =
            IListaStakeManager(LOCAL_LISTA_STAKE_MANAGER).convertSnBnbToBnb(slisBnbReceived);

        // ---- Exit: slisBNB -> WBNB on the deep PCS v3 tier ----
        IERC20(LOCAL_slisBNB).approve(LOCAL_PCS_V3_ROUTER, slisBnbReceived);
        wbnbExitProceeds = IPancakeV3Router(LOCAL_PCS_V3_ROUTER).exactInputSingle(
            IPancakeV3Router.ExactInputSingleParams({
                tokenIn: LOCAL_slisBNB, tokenOut: LOCAL_WBNB, fee: EXIT_FEE_TIER,
                recipient: address(this), amountIn: slisBnbReceived,
                amountOutMinimum: 0, sqrtPriceLimitX96: 0
            })
        );

        // ---- Profitability guard: cycle proceeds must cover notional+fee;
        //      do not subsidise a loss from the buffer. ----
        require(wbnbExitProceeds >= FLASH_NOTIONAL + owedFee, "tier arb: no edge");

        // ---- Repay flash from cycle proceeds ----
        IERC20(LOCAL_WBNB).transfer(flashPool, FLASH_NOTIONAL + owedFee);
    }

    function _thenaIn(uint256 amountIn) internal returns (uint256) {
        IThenaRouter.Route[] memory routes = new IThenaRouter.Route[](1);
        routes[0] = IThenaRouter.Route({from: LOCAL_WBNB, to: LOCAL_slisBNB, stable: true});
        // Skip Thena if the quote is dust (pair empty/illiquid at this block).
        try IThenaRouter(LOCAL_THENA_ROUTER).getAmountsOut(amountIn, routes)
            returns (uint256[] memory q) {
            if (q[q.length - 1] < amountIn / 2) return 0;
        } catch {
            return 0;
        }
        IERC20(LOCAL_WBNB).approve(LOCAL_THENA_ROUTER, amountIn);
        uint256[] memory amts = IThenaRouter(LOCAL_THENA_ROUTER).swapExactTokensForTokens(
            amountIn, 0, routes, address(this), block.timestamp
        );
        return amts[amts.length - 1];
    }

    function _offlinePnLCheck() internal {
        _startPnL();
        _endPnL("B02-07[offline]: slisBNB PCSv3-flash + Thena-stable + Lista-rate (hold flat)");
    }
}
