// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ISUSDe} from "src/interfaces/stable/ISUSDe.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IDssFlash} from "src/interfaces/cdp/IDssFlash.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IERC3156FlashBorrower} from "src/interfaces/common/IFlashLoanReceiver.sol";

/// @title F08-05 - DssFlash-bootstrapped Aave sUSDe e-mode loop with PT-sUSDe carry sleeve
/// @notice Three-mechanism composition:
///         1. Maker **DssFlash** mints DAI for free (ERC-3156 flashmint), no
///            collateral needed; used to bootstrap leverage in a single tx.
///         2. The flashed DAI is split: most goes to sUSDe-on-Aave looped under
///            the stablecoin e-mode (category 8, AIP-369), the rest buys a PT-sUSDe
///            sleeve via Pendle V4 for fixed-rate carry locked to maturity.
///         3. **Aave v3 stablecoin e-mode** (cat 8) accepts sUSDe alongside
///            DAI/USDC/USDT as a 90% LTV correlated class, so the loop closes
///            without resorting to a separate AMM-funded leverage venue.
///
///         Net result on entry: 1 USD equity -> ~6-9x notional sUSDe stack on
///         Aave + ~equity-sized PT-sUSDe sleeve, all atomic, with the entire
///         DAI flashmint repaid from a single Aave borrow.
contract F08_05_PtSusdeAaveEmodeDssFlashLoopTest is StrategyBase, IERC3156FlashBorrower {
    // ---- Pinned constants ----

    /// @dev Block 20,400,000 (~Aug 2024). sUSDe stablecoin e-mode active on
    ///      Aave v3 mainnet; PT-sUSDe-26SEP2024 still trading with ~50d to
    ///      expiry; DssFlash DAI ceiling at the protocol default ~500M DAI.
    uint256 constant FORK_BLOCK = 20_400_000;

    /// @dev Aave v3 sUSDe stablecoin-correlated e-mode category id (AIP-369).
    uint8 constant EMODE_SUSDE_STABLE = 8;

    /// @dev Variable interest rate mode (Aave v3).
    uint256 constant RATE_MODE_VARIABLE = 2;

    /// @dev Curve USDe/DAI 4-coin pool (USDe + DAI + sDAI + sUSDe-style).
    ///      We use the simpler USDe/USDC pool and route DAI->USDC->USDe via
    ///      Curve 3pool to avoid hardcoding a less liquid factory pool.
    address constant LOCAL_CURVE_USDE_USDC = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72;

    /// @dev Pendle PT-sUSDe-26SEP2024 market (canonical, used by F07-01/F08-03).
    address constant LOCAL_PENDLE_MARKET_PT_SUSDE_26SEP24 =
        0x19588F29f9402Bb508007FeADd415c875Ee3f19F;

    /// @dev DAI flashmint principal. Stays well below DssFlash.max() (~500M DAI).
    ///      Set to 4M DAI so the post-flash Aave borrow capacity at 90% e-mode
    ///      LTV with sUSDe NAV ~$1.10 leaves a comfortable buffer (>5%).
    uint256 constant FLASH_DAI = 4_000_000e18; // 4M DAI

    /// @dev User equity (in DAI). Total notional ~= EQUITY + FLASH_DAI.
    uint256 constant EQUITY_DAI = 1_000_000e18; // 1M DAI

    /// @dev Sleeve allocation: % of total notional spent on PT-sUSDe vs looped sUSDe.
    /// @dev We dedicate ~10% of the total notional to the PT sleeve. Larger
    ///      sleeves erode the Aave borrow capacity needed to repay the flash.
    uint256 constant PT_SLEEVE_BPS = 1000; // 10%

    /// @dev Per-loop LTV target for the Aave leg (below the 90% e-mode ceiling).
    uint256 constant LOOP_LTV_BPS = 8500; // 85% (5pp buffer under 90% ceiling)

    address internal _pt;
    address internal _sy;
    address internal _yt;

    function setUp() public {
        _fork(FORK_BLOCK);
        (_sy, _pt, _yt) = IPendleMarket(LOCAL_PENDLE_MARKET_PT_SUSDE_26SEP24).readTokens();

        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.USDE);
        _trackToken(Mainnet.SUSDE);
        _trackToken(Mainnet.USDC);
        _trackToken(_pt);

        require(
            ICurveStableSwap(LOCAL_CURVE_USDE_USDC).coins(0) == Mainnet.USDE,
            "F08-05: curve coin0 != USDe"
        );
        require(
            ICurveStableSwap(LOCAL_CURVE_USDE_USDC).coins(1) == Mainnet.USDC,
            "F08-05: curve coin1 != USDC"
        );
    }

    function testStrategy_F08_05() public {
        _fund(Mainnet.DAI, address(this), EQUITY_DAI);
        _startPnL();

        // Approvals (DAI for DssFlash repay; sUSDe & DAI for Aave; USDe for Pendle).
        IERC20(Mainnet.DAI).approve(Mainnet.DSS_FLASH, type(uint256).max);
        IERC20(Mainnet.DAI).approve(Mainnet.AAVE_V3_POOL, type(uint256).max);
        IERC20(Mainnet.DAI).approve(Mainnet.CURVE_3POOL, type(uint256).max);
        IERC20(Mainnet.USDC).approve(LOCAL_CURVE_USDE_USDC, type(uint256).max);
        IERC20(Mainnet.USDE).approve(Mainnet.SUSDE, type(uint256).max);
        IERC20(Mainnet.USDE).approve(Mainnet.PENDLE_ROUTER_V4, type(uint256).max);
        IERC20(Mainnet.SUSDE).approve(Mainnet.AAVE_V3_POOL, type(uint256).max);

        // Enter stablecoin e-mode up-front.
        IAavePool(Mainnet.AAVE_V3_POOL).setUserEMode(EMODE_SUSDE_STABLE);

        // Maker DssFlash is ERC-3156: callback returns ERC3156_CALLBACK_SUCCESS.
        // All heavy lifting runs inside onFlashLoan.
        IDssFlash(Mainnet.DSS_FLASH).flashLoan(
            address(this),
            Mainnet.DAI,
            FLASH_DAI,
            abi.encode("loop")
        );

        // Post-flash state surface: Aave account data + PT position.
        (uint256 collBase, uint256 debtBase, , , , uint256 hf) =
            IAavePool(Mainnet.AAVE_V3_POOL).getUserAccountData(address(this));
        emit log_named_uint("aave_coll_base_e8", collBase);
        emit log_named_uint("aave_debt_base_e8", debtBase);
        emit log_named_uint("aave_equity_base_e8", collBase - debtBase);
        emit log_named_uint("aave_health_factor_e18", hf);
        emit log_named_uint("pt_susde_balance_e18", IERC20(_pt).balanceOf(address(this)));

        _endPnL("F08-05: DssFlash + Aave e-mode + PT-sUSDe sleeve");
    }

    /// @notice ERC-3156 callback. msg.sender must be DssFlash; return the
    ///         keccak256 success marker after we repay the principal+fee.
    function onFlashLoan(
        address /*initiator*/,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata /*data*/
    ) external returns (bytes32) {
        require(msg.sender == Mainnet.DSS_FLASH, "F08-05: callback not from DssFlash");
        require(token == Mainnet.DAI, "F08-05: callback token != DAI");
        // DssFlash toll has been 0 since the Vow zero-fee resolution, but we do
        // not assume it - repay amount+fee unconditionally.

        // Total DAI in hand = EQUITY_DAI + FLASH_DAI. Split into two sleeves.
        uint256 totalDai = IERC20(Mainnet.DAI).balanceOf(address(this));
        uint256 ptSleeve = (totalDai * PT_SLEEVE_BPS) / 10_000;
        uint256 loopSleeve = totalDai - ptSleeve;

        // ---- Sleeve A: PT-sUSDe via Pendle ----
        // DAI -> USDC on 3pool (DAI=0, USDC=1) -> USDe on Curve USDe/USDC -> PT-sUSDe.
        uint256 usdcFromDai_pt = ICurveStableSwap(Mainnet.CURVE_3POOL).exchange(
            int128(0), int128(1), ptSleeve, 0
        );
        uint256 usdeFromUsdc_pt = ICurveStableSwap(LOCAL_CURVE_USDE_USDC).exchange(
            int128(1), int128(0), usdcFromDai_pt, 0
        );

        IPendleRouter.TokenInput memory tin = IPendleRouter.TokenInput({
            tokenIn: Mainnet.USDE,
            netTokenIn: usdeFromUsdc_pt,
            tokenMintSy: Mainnet.USDE,
            pendleSwap: address(0),
            swapData: IPendleRouter.SwapData({
                swapType: 0,
                extRouter: address(0),
                extCalldata: "",
                needScale: false
            })
        });
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.LimitOrderData memory lim;

        (uint256 ptOut, , ) = IPendleRouter(Mainnet.PENDLE_ROUTER_V4).swapExactTokenForPt(
            address(this),
            LOCAL_PENDLE_MARKET_PT_SUSDE_26SEP24,
            0,
            approx,
            tin,
            lim
        );
        require(ptOut > 0, "F08-05: pendle PT out = 0");

        // ---- Sleeve B: Aave sUSDe e-mode loop ----
        // DAI -> USDC -> USDe -> sUSDe -> supply to Aave, then loop borrow DAI
        // and re-stake until LTV consumed.
        uint256 usdcFromDai_loop = ICurveStableSwap(Mainnet.CURVE_3POOL).exchange(
            int128(0), int128(1), loopSleeve, 0
        );
        uint256 usdeFromUsdc_loop = ICurveStableSwap(LOCAL_CURVE_USDE_USDC).exchange(
            int128(1), int128(0), usdcFromDai_loop, 0
        );
        uint256 susdeShares = ISUSDe(Mainnet.SUSDE).deposit(usdeFromUsdc_loop, address(this));
        IAavePool(Mainnet.AAVE_V3_POOL).supply(Mainnet.SUSDE, susdeShares, address(this), 0);

        // ---- Repay flash by borrowing DAI from Aave ----
        // We borrow exactly (amount + fee) so that the flash is closed atomically.
        uint256 repay = amount + fee;
        IAavePool(Mainnet.AAVE_V3_POOL).borrow(
            Mainnet.DAI, repay, RATE_MODE_VARIABLE, 0, address(this)
        );

        // Sanity: our DAI balance now covers the flash repayment.
        uint256 daiHeld = IERC20(Mainnet.DAI).balanceOf(address(this));
        require(daiHeld >= repay, "F08-05: insufficient DAI to repay flash");

        // DssFlash pulls via transferFrom on outer approval (set in entry).
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
