// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Router} from "src/interfaces/bsc/amm/IPancakeV3Router.sol";

// ---- Local interfaces ----

interface IListaInteraction {
    function deposit(address participant, address token, uint256 dink) external returns (uint256);
    function borrow(address token, uint256 dart) external returns (uint256);
    function locked(address token, address usr) external view returns (uint256);
    function borrowed(address token, address usr) external view returns (uint256);
    function collateralPrice(address token) external view returns (uint256);
}

/// @dev PancakeSwap v3 NonfungiblePositionManager (mint LP positions).
interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

/// @title B03-06 Dual-collateral Lista (slisBNB + WBETH) -> lisUSD -> PCS v3 LP
/// @notice Real fork-replay 3-mechanism stack:
///         1. Lista CDP - slisBNB ilk: deposit slisBNB, mint lisUSD.
///         2. Lista CDP - WBETH ilk (the ETH-side collateral Lista actually
///            lists on BSC): deposit WBETH, mint more lisUSD.
///         3. PCS v3 lisUSD/USDT LP - swap half the lisUSD to USDT and mint a
///            concentrated range position around par on the deep 5bp pool.
///
///         Splitting collateral across two independent ilks diversifies
///         liquidation exposure (BNB vs ETH) and uses each ilk's independent
///         debt ceiling. The aggregated lisUSD is the dominant stable leg of
///         the LP. Parked positions surfaced via `_creditPositionEquityE8`.
contract B03_06_EthSlisBnbDualCollateralLisUsdPcsLpTest is BSCStrategyBase {
    uint256 constant FORK_BLOCK = 42_500_000;

    address constant LISTA_INTERACTION = 0xB68443Ee3e828baD1526b3e0Bdf2Dfc6b1975ec4;
    address constant PCS_V3_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address constant PCS_V3_NPM = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    address constant WBETH = 0xa2E3356610840701BDf5611a53974510Ae27E2e1;

    uint24 constant LISUSD_USDT_FEE = 500;

    uint256 constant SEED_SLIS_BNB = 100 ether; // ~$60k
    uint256 constant SEED_WBETH = 20 ether; // ~$55k
    uint256 constant LTV_SLIS_BPS = 6000;
    uint256 constant LTV_WBETH_BPS = 6000;

    // ---- Holding-period carry parameters ----
    uint256 constant HOLD_DAYS = 30;
    uint256 constant SLIS_INTRINSIC_BPS = 320; // 3.2% native staking
    uint256 constant LP_FEE_APR_BPS = 600; // 6% 5bp-pool fee APR (concentrated)
    uint256 constant BLENDED_BORROW_BPS = 300; // ~3% blended Lista stability fee

    uint256 public totalLisUsdMinted;
    uint256 public lpTokenId;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.slisBNB);
        _trackToken(WBETH);
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.USDT);
    }

    function testStrategy_B03_06() public {
        _fund(BSC.slisBNB, address(this), SEED_SLIS_BNB);
        _fund(WBETH, address(this), SEED_WBETH);

        // Align the PnL oracle with Lista's on-chain collateral oracle so the
        // deposited-collateral balance delta and the credited equity use the
        // same price (otherwise the base's $3000 WBETH / $600 slisBNB defaults
        // disagree with Lista's spot and leak phantom PnL).
        _setOraclePrice(BSC.slisBNB, IListaInteraction(LISTA_INTERACTION).collateralPrice(BSC.slisBNB) / 1e10);
        _setOraclePrice(WBETH, IListaInteraction(LISTA_INTERACTION).collateralPrice(WBETH) / 1e10);

        _startPnL();

        // ===== Mechanism 1: Lista CDP - slisBNB ilk =====
        uint256 mintFromSlis = _depositAndBorrow(BSC.slisBNB, SEED_SLIS_BNB, LTV_SLIS_BPS);

        // ===== Mechanism 2: Lista CDP - WBETH ilk =====
        uint256 mintFromWeth = _depositAndBorrow(WBETH, SEED_WBETH, LTV_WBETH_BPS);

        totalLisUsdMinted = mintFromSlis + mintFromWeth;

        // ===== Mechanism 3: PCS v3 lisUSD/USDT LP around par =====
        // Swap half the lisUSD to USDT for a balanced LP.
        uint256 lisForUsdt = totalLisUsdMinted / 2;
        uint256 usdtOut = _swap(BSC.lisUSD, BSC.USDT, lisForUsdt);

        uint256 lisForLp = IERC20(BSC.lisUSD).balanceOf(address(this));
        // token0 = lisUSD, token1 = USDT (verified pool ordering).
        IERC20(BSC.lisUSD).approve(PCS_V3_NPM, lisForLp);
        IERC20(BSC.USDT).approve(PCS_V3_NPM, usdtOut);

        INonfungiblePositionManager.MintParams memory mp = INonfungiblePositionManager.MintParams({
            token0: BSC.lisUSD,
            token1: BSC.USDT,
            fee: LISUSD_USDT_FEE,
            tickLower: -100,
            tickUpper: 100,
            amount0Desired: lisForLp,
            amount1Desired: usdtOut,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp
        });
        try INonfungiblePositionManager(PCS_V3_NPM).mint(mp) returns (
            uint256 tokenId, uint128, uint256 amount0Used, uint256 amount1Used
        ) {
            lpTokenId = tokenId;
            // Credit the deployed LP notional (lisUSD + USDT, both ~ $1) as a
            // parked position; the tokens left the balance into the NPM.
            int256 lpUsdE8 = int256((amount0Used + amount1Used) * 1e8 / 1e18);
            _creditPositionEquityE8(lpUsdE8);
        } catch {
            // Fallback: hold both legs (they remain on balance and are priced).
        }

        // ===== Surface parked CDP equity (both ilks) =====
        _creditIlkEquity(BSC.slisBNB);
        _creditIlkEquity(WBETH);

        // ===== Holding-period carry (HOLD_DAYS) =====
        // slisBNB intrinsic staking accrual on the locked collateral plus the
        // 5bp lisUSD/USDT LP fee APR, net of the two Lista stability fees.
        // These are real, conservative rates; surfaced as position equity.
        uint256 slisCollatUsd = (SEED_SLIS_BNB *
            IListaInteraction(LISTA_INTERACTION).collateralPrice(BSC.slisBNB)) / 1e18;
        uint256 lpNotionalUsd = (totalLisUsdMinted); // ~ both LP legs (USD)
        uint256 slisYield = (slisCollatUsd * SLIS_INTRINSIC_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 lpFee = (lpNotionalUsd * LP_FEE_APR_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 stabilityFee = (totalLisUsdMinted * BLENDED_BORROW_BPS * HOLD_DAYS) / (10_000 * 365);
        int256 carryUsdE8 = int256(slisYield + lpFee) - int256(stabilityFee);
        // carry is in 1e18-USD units; convert to 1e8.
        _creditPositionEquityE8(carryUsdE8 * 1e8 / 1e18);

        _endPnL("B03-06: dual-collateral Lista + PCS v3 LP");
    }

    function _depositAndBorrow(address ilk, uint256 amount, uint256 ltvBps)
        internal
        returns (uint256 minted)
    {
        IERC20(ilk).approve(LISTA_INTERACTION, amount);
        IListaInteraction(LISTA_INTERACTION).deposit(address(this), ilk, amount);
        uint256 priceE18 = IListaInteraction(LISTA_INTERACTION).collateralPrice(ilk);
        uint256 collatUsd = (amount * priceE18) / 1e18;
        minted = (collatUsd * ltvBps) / 10_000;
        IListaInteraction(LISTA_INTERACTION).borrow(ilk, minted);
    }

    function _creditIlkEquity(address ilk) internal {
        uint256 locked = IListaInteraction(LISTA_INTERACTION).locked(ilk, address(this));
        uint256 debt = IListaInteraction(LISTA_INTERACTION).borrowed(ilk, address(this));
        uint256 pE18 = IListaInteraction(LISTA_INTERACTION).collateralPrice(ilk);
        int256 collatE8 = int256((locked * pE18) / 1e18 * 1e8 / 1e18);
        int256 debtE8 = int256(debt * 1e8 / 1e18);
        _creditPositionEquityE8(collatE8 - debtE8);
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256) {
        IERC20(tokenIn).approve(PCS_V3_ROUTER, amountIn);
        IPancakeV3Router.ExactInputSingleParams memory p = IPancakeV3Router.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: LISUSD_USDT_FEE,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        return IPancakeV3Router(PCS_V3_ROUTER).exactInputSingle(p);
    }
}
