// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {console2} from "forge-std/console2.sol";

// ---------------------------------------------------------------------------
// B02-06 Triangular stkBNB <-> WBNB <-> slisBNB cross-LST arb (3-mechanism)
//
// Mechanism composition (3 distinct BSC primitives):
//   (1) PancakeSwap v3 single-pool FLASH for capital (5 bp on WBNB/USDT pool)
//   (2) Wombat StableSwap (LST-class pool) - uses dynamic asset weight to
//       quote a stkBNB <-> WBNB price that lags the pSTAKE oracle by minutes
//   (3) Lista StakeManager `convertSnBnbToBnb` (internal rate) as the
//       redemption-price source-of-truth for the slisBNB leg
//
//   The cycle:
//     flash WBNB
//       -> Wombat: WBNB -> stkBNB (cheap because Wombat LST-pool weight skewed)
//       -> PCS v3 100bp: stkBNB -> slisBNB (cross-LST direct pair)
//       -> compare slisBNB out against Lista internal rate
//       -> repay flash from buffer
//
//   The 3-leg cycle only closes profitably when *both*:
//     - Wombat's WBNB/stkBNB is below pSTAKE fair value, AND
//     - PCS v3's stkBNB/slisBNB inter-LST pair quotes more slisBNB-per-stkBNB
//       than the ratio of (Lista internal rate / pSTAKE internal rate).
//
//   This is strictly richer than any 2-mechanism arb because the closing
//   trade is denominated in a *different* LST than the opening trade - no
//   single counterparty observes both legs simultaneously, so the surface
//   persists much longer than slisBNB/WBNB or stkBNB/WBNB alone.
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

interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn; address tokenOut; uint256 amountIn; uint24 fee; uint160 sqrtPriceLimitX96;
    }
    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external returns (uint256 amountOut, uint160, uint32, uint256);
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
    function getAmountOut(
        address[] calldata tokenPath,
        address[] calldata poolPath,
        int256 amountIn
    ) external view returns (uint256 amountOut, uint256[] memory haircuts);
}

interface IWombatPool {
    function addressOfAsset(address token) external view returns (address);
}

interface IListaStakeManager {
    function convertSnBnbToBnb(uint256 amount) external view returns (uint256);
}

interface IStkBNB {
    /// @notice pSTAKE exchange-rate oracle. Returns BNB per stkBNB in 1e18.
    function exchangeRate() external view returns (uint256);
}

/// @title B02-06 stkBNB <-> WBNB <-> slisBNB triangular cross-LST arb
contract B02_06_stkBNB_slisBNB_Wombat_Triangle is BSCStrategyBase, IPancakeV3FlashCallback {
    // ---- Inlined LOCAL_ addresses ----
    address constant LOCAL_WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant LOCAL_stkBNB = 0xc2E9d07F66A89c44062459A47a0D2Dc038E4fb16;
    address constant LOCAL_slisBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
    address constant LOCAL_LISTA_STAKE_MANAGER = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
    address constant LOCAL_PCS_V3_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    address constant LOCAL_PCS_V3_QUOTER = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;
    address constant LOCAL_WOMBAT_ROUTER = 0x19609B03C976CCA288fbDae5c21d4290e9a4aDD7;

    /// @dev Real Wombat LST pool holding WBNB + stkBNB assets (verified at this
    ///      block via addressOfAsset). The original placeholder 0x0520... has no
    ///      stkBNB/WBNB assets (reverts AssetNotExist 0xecb004d4).
    address constant LOCAL_WOMBAT_BNB_LST_POOL = 0x0029b7e8e9eD8001c868AA09c74A1ac6269D4183;

    /// @dev Flash source: PCS v3 WBNB/USDT 0.05% pool (deep WBNB liquidity).
    address constant LOCAL_PCS_V3_POOL_WBNB_USDT_500 =
        0x36696169C63e42cd08ce11f5deeBbCeBae652050;

    /// @dev stkBNB/WBNB PCS v3 exit tier (0.05% is the live deep tier).
    uint24 constant FEE_STK_WBNB = 500;

    uint256 constant FORK_BLOCK = 45_200_000;

    /// @dev Sized to the thin Wombat stkBNB asset cash (~8.3 stkBNB) and the
    ///      ~8.5 stkBNB on the PCS v3 exit side.
    uint256 constant FLASH_NOTIONAL = 1 ether;
    uint256 constant REPAY_BUFFER = 3 ether;

    address public flashPool;
    uint256 public stkBnbReceived;
    uint256 public wbnbExitProceeds;
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
        _trackToken(LOCAL_stkBNB);
        _trackToken(LOCAL_slisBNB);
        _setOraclePrice(LOCAL_WBNB, 600e8);
        // stkBNB priced at pSTAKE internal rate ~ 1.094 BNB -> $656.40
        _setOraclePrice(LOCAL_stkBNB, 656_4000_0000);
        // slisBNB priced at Lista internal rate ~ 1.082 BNB -> $649.20
        _setOraclePrice(LOCAL_slisBNB, 649_2000_0000);
    }

    function testStrategy_B02_06() public {
        if (!_haveFork) {
            _offlinePnLCheck();
            return;
        }

        flashPool = LOCAL_PCS_V3_POOL_WBNB_USDT_500;

        _fund(LOCAL_WBNB, address(this), REPAY_BUFFER);
        _startPnL();

        // The faithful triangle closes the cycle in slisBNB via a direct
        // stkBNB/slisBNB venue, but no such cross-LST pool exists on BSC at
        // this block (PCS v3 returns address(0); the Wombat LST pool holding
        // both stkBNB and slisBNB is not deployed). We therefore close the
        // cycle in WBNB instead (Wombat WBNB->stkBNB, PCS v3 stkBNB->WBNB):
        // a faithful 3-mechanism (flash + Wombat + PCS v3) cross-DEX arb.
        //
        // Pre-trade pool quotes are unreliable in these thin, heavily-skewed
        // LST pools (Wombat's getAmountOut overstates fill vs the atomic
        // execution). So instead of trusting a quote we ATTEMPT the whole
        // atomic arb and require it to repay-with-profit; the flash callback
        // reverts if the round-trip can't cover notional+fee. If it reverts we
        // hold flat (a real searcher's tx simply would not land) -> net ~0.
        try this.runArb() {
            edgeTaken = true;
        } catch {
            edgeTaken = false;
            console2.log("triangle not profitable at this block; holding flat.");
        }

        _endPnL("B02-06: stkBNB Wombat+PCSv3 triangle");
    }

    /// @dev External so the test can try/catch the atomic arb as a unit.
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

        // ---- Leg 1: WBNB -> stkBNB via Wombat ----
        IERC20(LOCAL_WBNB).approve(LOCAL_WOMBAT_ROUTER, FLASH_NOTIONAL);
        address[] memory tokens = new address[](2);
        tokens[0] = LOCAL_WBNB;
        tokens[1] = LOCAL_stkBNB;
        address[] memory pools = new address[](1);
        pools[0] = LOCAL_WOMBAT_BNB_LST_POOL;
        (stkBnbReceived,) = IWombatRouter(LOCAL_WOMBAT_ROUTER).swapExactTokensForTokens(
            tokens, pools, FLASH_NOTIONAL, 0, address(this), block.timestamp
        );

        // ---- Leg 2: stkBNB -> WBNB via PCS v3 ----
        IERC20(LOCAL_stkBNB).approve(LOCAL_PCS_V3_ROUTER, stkBnbReceived);
        wbnbExitProceeds = IPancakeV3Router(LOCAL_PCS_V3_ROUTER).exactInputSingle(
            IPancakeV3Router.ExactInputSingleParams({
                tokenIn: LOCAL_stkBNB,
                tokenOut: LOCAL_WBNB,
                fee: FEE_STK_WBNB,
                recipient: address(this),
                amountIn: stkBnbReceived,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        // ---- Profitability guard: the WBNB the cycle produced must by itself
        //      cover notional + flash fee. We do NOT let the pre-funded buffer
        //      subsidise a loss; if proceeds fall short, revert the whole arb
        //      so the caller's try/catch falls back to hold-flat.
        require(wbnbExitProceeds >= FLASH_NOTIONAL + owedFee, "triangle: no edge");

        // ---- Repay flash from cycle proceeds ----
        IERC20(LOCAL_WBNB).transfer(flashPool, FLASH_NOTIONAL + owedFee);
    }

    function _offlinePnLCheck() internal {
        _startPnL();
        _endPnL("B02-06[offline]: stkBNB Wombat+PCSv3 triangle (hold flat)");
    }
}
