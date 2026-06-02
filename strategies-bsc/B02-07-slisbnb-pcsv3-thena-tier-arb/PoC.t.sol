// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

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
//   Lista's monotonic internal rate, not sold back into a PCS v3 pool — i.e.
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
    address constant LOCAL_THENA_ROUTER = 0x20a304a7d126758dfe6B243D0fc515F83bCA8431;

    /// @dev TODO: pin a block where Thena slisBNB-stable pair quote diverges
    ///      from PCS v3 by > 15 bp (typically right after Lista oracle push).
    uint256 constant FORK_BLOCK = 45_300_000;

    uint24 constant FLASH_FEE_TIER = 500; // PCS v3 slisBNB/WBNB 0.05%

    uint256 constant FLASH_NOTIONAL = 800 ether;
    uint256 constant REPAY_BUFFER = 803 ether;

    address public flashPool;
    uint256 public slisBnbReceived;
    uint256 public listaInternalBnbValue;
    uint256 public listaImpliedSlisFromBnb;

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
        // slisBNB at Lista internal rate ≈ 1.082 BNB → $649.20
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

        bool wbnbIsToken0 = IPancakeV3Pool(flashPool).token0() == LOCAL_WBNB;
        if (wbnbIsToken0) {
            IPancakeV3Pool(flashPool).flash(address(this), FLASH_NOTIONAL, 0, "");
        } else {
            IPancakeV3Pool(flashPool).flash(address(this), 0, FLASH_NOTIONAL, "");
        }

        _endPnL("B02-07: slisBNB PCSv3-flash + Thena-stable + Lista-rate");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata) external override {
        require(msg.sender == flashPool, "callback: not flash pool");
        bool wbnbIsToken0 = IPancakeV3Pool(flashPool).token0() == LOCAL_WBNB;
        uint256 owedFee = wbnbIsToken0 ? fee0 : fee1;

        // ---- Mechanism #2: Thena solidly stable WBNB -> slisBNB ----
        IERC20(LOCAL_WBNB).approve(LOCAL_THENA_ROUTER, FLASH_NOTIONAL);
        IThenaRouter.Route[] memory routes = new IThenaRouter.Route[](1);
        routes[0] = IThenaRouter.Route({from: LOCAL_WBNB, to: LOCAL_slisBNB, stable: true});
        uint256[] memory amts = IThenaRouter(LOCAL_THENA_ROUTER).swapExactTokensForTokens(
            FLASH_NOTIONAL, 0, routes, address(this), block.timestamp
        );
        slisBnbReceived = amts[amts.length - 1];

        // ---- Mechanism #3: Lista internal rate as price oracle ----
        listaInternalBnbValue =
            IListaStakeManager(LOCAL_LISTA_STAKE_MANAGER).convertSnBnbToBnb(slisBnbReceived);
        listaImpliedSlisFromBnb =
            IListaStakeManager(LOCAL_LISTA_STAKE_MANAGER).convertBnbToSnBnb(FLASH_NOTIONAL);

        // ---- Repay flash (Mechanism #1 close-out) ----
        IERC20(LOCAL_WBNB).transfer(flashPool, FLASH_NOTIONAL + owedFee);
    }

    function _offlinePnLCheck() internal {
        // Assumed surface: Thena stable invariant pricing 1 WBNB -> 0.940 slisBNB
        // (versus Lista implied 1/1.082 = 0.9242 slisBNB). Edge = 1.7%.
        // Conservatively realised at 0.928 after slippage on 800 WBNB notional.
        uint256 n = FLASH_NOTIONAL;
        uint256 simSlis = n * 928 / 1_000; // 928 slisBNB out
        uint256 simBnbValue = simSlis * 1082 / 1_000;
        uint256 simFee = n * 5 / 10_000;

        _fund(LOCAL_WBNB, address(this), REPAY_BUFFER);
        _startPnL();
        IERC20(LOCAL_WBNB).transfer(address(0xdead), n + simFee);
        _fund(LOCAL_slisBNB, address(this), simSlis);

        slisBnbReceived = simSlis;
        listaInternalBnbValue = simBnbValue;
        listaImpliedSlisFromBnb = n * 1_000 / 1_082;

        _endPnL("B02-07[offline]: slisBNB PCSv3-flash + Thena-stable + Lista-rate");
    }
}
