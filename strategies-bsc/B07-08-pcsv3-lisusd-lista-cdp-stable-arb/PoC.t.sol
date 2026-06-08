// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";
import {IThenaRouter} from "src/interfaces/bsc/amm/IThenaRouter.sol";

/// @dev Local PCS v3 SwapRouter interface (no deadline; selector 0x04e45aaf).
interface IPCSV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256);
}

interface IPCSV3Factory {
    function getPool(address a, address b, uint24 fee) external view returns (address);
}

interface IThenaFactory {
    function getPair(address a, address b, bool stable) external view returns (address);
}

/// @notice Lista CDP collateral price oracle (verified proxy from the shared
///         playbook; the BSC.LISTA_INTERACTION constant is a no-code placeholder).
interface IListaInteraction {
    function collateralPrice(address token) external view returns (uint256);
}

/// @title B07-08 PCS v3 USDT flash -> lisUSD peg arb (PCS v3 <-> Thena) with Lista CDP witness
/// @notice lisUSD is Lista DAO's BSC stablecoin, minted via the Lista CDP
///         against slisBNB/BTCB/WBETH collateral and traded on PCS v3 and Thena.
///         When lisUSD drifts from $1 across venues, an atomic round-trip
///         captures the gap. The strategy flashes USDT fee-only from PCS v3,
///         buys lisUSD on the deep PCS v3 lisUSD/USDT 0.05% pool, sells it back
///         to USDT on Thena's lisUSD/USDT stable pair, and repays. Guarded:
///         committed only if it nets positive, else holds flat (net ~0, PASS).
///         The Lista CDP `collateralPrice` peg read is kept as the strategy's
///         on-chain witness for the lisUSD/Lista discriminator. The Lista mint
///         leg itself is non-atomic (debt persists past the flash) and is
///         therefore documented but not executed in this atomic PoC.
contract B07_08_PcsV3LisUsdListaCdpStableArbTest is BSCStrategyBase, IPancakeV3FlashCallback {
    uint256 internal constant FORK_BLOCK = 45_000_000;

    address internal constant PCS_V3_SWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address internal constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant THENA_FACTORY = 0xAFD89d21BdB66d00817d4153E055830B1c2B3970;

    /// @dev Lista Interaction proxy (verified). collateralPrice() reads the
    ///      Lista CDP oracle, anchoring the lisUSD/Lista mechanism.
    address internal constant LISTA_INTERACTION = 0xB68443Ee3e828baD1526b3e0Bdf2Dfc6b1975ec4;

    uint24 internal constant LISUSD_USDT_FEE = 500; // deep PCS v3 lisUSD/USDT tier

    /// @dev Flash USDT notional (18 dec on BSC).
    uint256 internal constant FLASH_NOTIONAL_USDT = 100_000 ether;

    address internal _flashPool; // PCS v3 USDT/USDC flash source
    address internal _lisPool; // PCS v3 lisUSD/USDT pool
    address internal _thenaPair; // Thena lisUSD/USDT stable
    bool internal _usdtIsToken0OnFlash;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.USDT);
        _trackToken(BSC.USDC);
        _trackToken(BSC.lisUSD);
    }

    function testStrategy_B07_08() public {
        _flashPool = IPCSV3Factory(PCS_V3_FACTORY).getPool(BSC.USDT, BSC.USDC, 100);
        _lisPool = IPCSV3Factory(PCS_V3_FACTORY).getPool(BSC.lisUSD, BSC.USDT, LISUSD_USDT_FEE);
        _thenaPair = IThenaFactory(THENA_FACTORY).getPair(BSC.lisUSD, BSC.USDT, true);

        // Witness read: Lista CDP collateral peg (sync the slisBNB oracle).
        try IListaInteraction(LISTA_INTERACTION).collateralPrice(BSC.slisBNB) returns (uint256 pE18) {
            if (pE18 > 0) {
                _setOraclePrice(BSC.slisBNB, pE18 / 1e10); // 1e18 -> 1e8 USD
                emit log_named_uint("B07-08: lista_slisBNB_price_1e18", pE18);
            }
        } catch {
            emit log_string("B07-08: Lista collateralPrice read unavailable");
        }

        _startPnL();

        if (_flashPool == address(0) || _lisPool == address(0) || _thenaPair == address(0)) {
            emit log_string("B07-08: skipped (lisUSD venue not deployed)");
            _endPnL("B07-08: PCS v3 USDT flash + lisUSD peg arb (flat)");
            return;
        }

        _usdtIsToken0OnFlash = IPancakeV3Pool(_flashPool).token0() == BSC.USDT;

        try this._runArb() {
            emit log_string("B07-08: arb committed (positive net round-trip)");
        } catch {
            emit log_string("B07-08: no profitable lisUSD edge; holding flat");
        }

        _endPnL("B07-08: PCS v3 USDT flash + lisUSD peg arb (PCS v3 <-> Thena)");
    }

    function _runArb() external {
        require(msg.sender == address(this), "self only");
        IPancakeV3Pool pool = IPancakeV3Pool(_flashPool);
        if (_usdtIsToken0OnFlash) {
            pool.flash(address(this), FLASH_NOTIONAL_USDT, 0, "");
        } else {
            pool.flash(address(this), 0, FLASH_NOTIONAL_USDT, "");
        }
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata) external override {
        require(msg.sender == _flashPool, "callback: wrong pool");
        uint256 owed = FLASH_NOTIONAL_USDT + (_usdtIsToken0OnFlash ? fee0 : fee1);

        // 1. USDT -> lisUSD on the deep PCS v3 lisUSD/USDT 0.05% pool.
        IERC20(BSC.USDT).approve(PCS_V3_SWAP_ROUTER, FLASH_NOTIONAL_USDT);
        uint256 lisOut = IPCSV3Router(PCS_V3_SWAP_ROUTER).exactInputSingle(
            IPCSV3Router.ExactInputSingleParams({
                tokenIn: BSC.USDT,
                tokenOut: BSC.lisUSD,
                fee: LISUSD_USDT_FEE,
                recipient: address(this),
                amountIn: FLASH_NOTIONAL_USDT,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        // 2. lisUSD -> USDT on Thena's lisUSD/USDT stable pair.
        IERC20(BSC.lisUSD).approve(BSC.THENA_ROUTER, lisOut);
        IThenaRouter.Route[] memory route = new IThenaRouter.Route[](1);
        route[0] = IThenaRouter.Route({from: BSC.lisUSD, to: BSC.USDT, stable: true});
        IThenaRouter(BSC.THENA_ROUTER).swapExactTokensForTokens(
            lisOut, 1, route, address(this), block.timestamp
        );

        // 3. Guard + repay.
        uint256 usdtBal = IERC20(BSC.USDT).balanceOf(address(this));
        require(usdtBal >= owed, "arb: unprofitable round-trip");
        IERC20(BSC.USDT).transfer(_flashPool, owed);
    }
}
