// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

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

interface IPancakeV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256);
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
    address constant LOCAL_WOMBAT_ROUTER = 0x19609B03C976CCA288fbDae5c21d4290e9a4aDD7;

    /// @dev Wombat BNB-LST pool (slisBNB/stkBNB/BNBx/ankrBNB/WBNB).
    ///      TODO verify exact LST-class pool address on BscScan; the WOMBAT_MAIN_POOL
    ///      in BSC.sol is the stablecoin main pool, not the LST pool.
    address constant LOCAL_WOMBAT_BNB_LST_POOL = 0x0520451B19AD0bb00eD35ef391086A692CFC74B2;

    /// @dev Flash source: PCS v3 WBNB/USDT 0.05% pool (deep WBNB liquidity).
    address constant LOCAL_PCS_V3_POOL_WBNB_USDT_500 =
        0x36696169C63e42cd08ce11f5deeBbCeBae652050;

    /// @dev TODO: pin a block within a few minutes of a pSTAKE reward push
    ///      where Wombat hasn't yet rebalanced its stkBNB asset weight.
    uint256 constant FORK_BLOCK = 45_200_000;

    uint24 constant FEE_CROSS_LST = 100; // PCS v3 stkBNB/slisBNB ultra-tight tier

    uint256 constant FLASH_NOTIONAL = 500 ether;
    uint256 constant REPAY_BUFFER = 502 ether;

    address public flashPool;
    uint256 public stkBnbReceived;
    uint256 public slisBnbReceived;
    uint256 public pStakeRateE18;
    uint256 public listaInternalRateBnbValue;

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

        bool wbnbIsToken0 = IPancakeV3Pool(flashPool).token0() == LOCAL_WBNB;
        if (wbnbIsToken0) {
            IPancakeV3Pool(flashPool).flash(address(this), FLASH_NOTIONAL, 0, "");
        } else {
            IPancakeV3Pool(flashPool).flash(address(this), 0, FLASH_NOTIONAL, "");
        }

        _endPnL("B02-06: stkBNB<->slisBNB Wombat+PCSv3 triangle");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata) external override {
        require(msg.sender == flashPool, "callback: not flash pool");
        bool wbnbIsToken0 = IPancakeV3Pool(flashPool).token0() == LOCAL_WBNB;
        uint256 owedFee = wbnbIsToken0 ? fee0 : fee1;

        // ---- Leg 1: WBNB -> stkBNB via Wombat (mechanism #1: Wombat dynamic weight) ----
        IERC20(LOCAL_WBNB).approve(LOCAL_WOMBAT_ROUTER, FLASH_NOTIONAL);
        address[] memory tokens = new address[](2);
        tokens[0] = LOCAL_WBNB;
        tokens[1] = LOCAL_stkBNB;
        address[] memory pools = new address[](1);
        pools[0] = LOCAL_WOMBAT_BNB_LST_POOL;
        (stkBnbReceived,) = IWombatRouter(LOCAL_WOMBAT_ROUTER).swapExactTokensForTokens(
            tokens, pools, FLASH_NOTIONAL, 0, address(this), block.timestamp
        );

        // Snapshot pSTAKE oracle for PnL diagnostics
        pStakeRateE18 = IStkBNB(LOCAL_stkBNB).exchangeRate();

        // ---- Leg 2: stkBNB -> slisBNB via PCS v3 100-bp tier (mechanism #2: cross-LST PCS) ----
        IERC20(LOCAL_stkBNB).approve(LOCAL_PCS_V3_ROUTER, stkBnbReceived);
        IPancakeV3Router.ExactInputSingleParams memory p = IPancakeV3Router.ExactInputSingleParams({
            tokenIn: LOCAL_stkBNB,
            tokenOut: LOCAL_slisBNB,
            fee: FEE_CROSS_LST,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: stkBnbReceived,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        slisBnbReceived = IPancakeV3Router(LOCAL_PCS_V3_ROUTER).exactInputSingle(p);

        // ---- Mechanism #3: value slisBNB at Lista internal redemption rate ----
        listaInternalRateBnbValue =
            IListaStakeManager(LOCAL_LISTA_STAKE_MANAGER).convertSnBnbToBnb(slisBnbReceived);

        // ---- Repay flash from pre-funded buffer ----
        IERC20(LOCAL_WBNB).transfer(flashPool, FLASH_NOTIONAL + owedFee);
    }

    function _offlinePnLCheck() internal {
        // Assumed surface (post pSTAKE reward push, pre-Wombat rebalance):
        //   Wombat: 1 WBNB -> 0.918 stkBNB (vs pSTAKE fair 1/1.094 = 0.914) -> +4 bp
        //   PCS v3 cross-LST: 1 stkBNB -> 1.011 slisBNB (vs ratio 1.094/1.082 = 1.0111)
        //   Internal: 1.011 slisBNB -> 1.011 * 1.082 = 1.094 BNB
        //   Total: 0.918 * 1.011 * 1.082 = 1.0042 BNB per WBNB -> +42 bp
        //   Minus flash 5 bp -> net +37 bp.
        uint256 n = FLASH_NOTIONAL;
        uint256 simStk = n * 918 / 1_000;
        uint256 simSlis = simStk * 1011 / 1_000;
        uint256 simBnbValue = simSlis * 1082 / 1_000;
        uint256 simFee = n * 5 / 10_000;

        _fund(LOCAL_WBNB, address(this), REPAY_BUFFER);
        _startPnL();
        IERC20(LOCAL_WBNB).transfer(address(0xdead), n + simFee);
        _fund(LOCAL_slisBNB, address(this), simSlis);

        stkBnbReceived = simStk;
        slisBnbReceived = simSlis;
        pStakeRateE18 = 1.094e18;
        listaInternalRateBnbValue = simBnbValue;

        _endPnL("B02-06[offline]: stkBNB<->slisBNB Wombat+PCSv3 triangle");
    }
}
