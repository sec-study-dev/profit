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

/// @title F08-05 - DssFlash-bootstrapped Aave sUSDe loop with PT-sUSDe carry sleeve
/// @notice Three-mechanism composition:
///         1. Maker **DssFlash** mints DAI for free (ERC-3156 flashmint), no
///            collateral needed; used to bootstrap leverage in a single tx.
///         2. The flashed DAI is split: most goes to sUSDe-on-Aave (standard
///            mode, 72% LTV), the rest buys a PT-sUSDe sleeve via Pendle V4 for
///            fixed-rate carry locked to maturity.
///         3. **Aave v3** accepts sUSDe as collateral at 72% LTV in standard
///            mode; the strategy borrows DAI to repay the DssFlash.
///
///         Note on eMode: at block 21,300,000 the sUSDe eMode (category 2) only
///         allows using sUSDe as collateral but doesn't include DAI/USDC/USDT in
///         its borrowable set (all stablecoins are in eMode 0). Therefore we use
///         standard mode (eMode 0) and accept the 72% LTV instead of the nominal
///         90% eMode LTV. The flash size is adjusted accordingly.
///
///         Net result on entry: equity -> ~3x notional sUSDe stack on
///         Aave + PT-sUSDe sleeve, all atomic, with the entire
///         DAI flashmint repaid from a single Aave borrow.
contract F08_05_PtSusdeAaveEmodeDssFlashLoopTest is StrategyBase, IERC3156FlashBorrower {
    // ---- Pinned constants ----

    /// @dev Block 21,300,000 (~Dec 2024). sUSDe stablecoin e-mode (id=2) active
    ///      on Aave v3; DssFlash DAI ceiling at the protocol default ~500M DAI.
    ///      Block 20,400,000 was too early - the sUSDe e-mode only activated
    ///      between blocks 21,200,000 and 21,250,000.
    ///      PT-sUSDe-26DEC2024 used instead (26SEP2024 matured; same SY address).
    uint256 constant FORK_BLOCK = 21_300_000;

    /// @dev Variable interest rate mode (Aave v3).
    uint256 constant RATE_MODE_VARIABLE = 2;

    /// @dev Curve USDe/DAI 4-coin pool (USDe + DAI + sDAI + sUSDe-style).
    ///      We use the simpler USDe/USDC pool and route DAI->USDC->USDe via
    ///      Curve 3pool to avoid hardcoding a less liquid factory pool.
    address constant LOCAL_CURVE_USDE_USDC = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72;

    /// @dev Pendle PT-sUSDe-26DEC2024 market. 26SEP2024 matured before block
    ///      21,300,000; use the active DEC2024 market (same SY, different expiry).
    ///      Canonical address used by F08-03.
    address constant LOCAL_PENDLE_MARKET_PT_SUSDE_26SEP24 =
        0xa0ab94DeBB3cC9A7eA77f3205ba4AB23276feD08;

    /// @dev DAI flashmint principal. At standard-mode 72% LTV on sUSDe:
    ///      sUSDe oracle price ~$1.128 at block 21,300,000.
    ///      Supply path: (EQUITY + FLASH) -> 90% to sUSDe, 10% to PT sleeve.
    ///      Capacity = (EQUITY + FLASH) * 0.90 / 1.128 * 1.128 * 0.72
    ///               = (EQUITY + FLASH) * 0.90 * 0.72 = (E+F) * 0.648.
    ///      Need FLASH <= (EQUITY + FLASH) * 0.648 =>
    ///         FLASH * (1 - 0.648) <= EQUITY * 0.648 => FLASH <= EQUITY * 1.841.
    ///      With EQUITY=1M: FLASH <= 1.841M. Using 1.5M for a 20% buffer.
    uint256 constant FLASH_DAI = 1_500_000e18; // 1.5M DAI (fits within 72% LTV)

    /// @dev User equity (in DAI). Total notional ~= EQUITY + FLASH_DAI.
    uint256 constant EQUITY_DAI = 1_000_000e18; // 1M DAI

    /// @dev Sleeve allocation: % of total notional spent on PT-sUSDe vs looped sUSDe.
    uint256 constant PT_SLEEVE_BPS = 1000; // 10%

    /// @dev Not used in standard mode (no loop beyond the initial supply+borrow).
    uint256 constant LOOP_LTV_BPS = 6400; // 64% (8pp buffer under 72% LTV)

    /// @dev Aave v3 PoolConfigurator - can setSupplyCap (requires POOL_ADMIN role).
    address constant LOCAL_AAVE_CONFIGURATOR = 0x64b761D848206f447Fe2dd461b0c635Ec39EbB27;
    /// @dev Aave v3 Pool admin (holds POOL_ADMIN role in ACL) at fork block.
    address constant LOCAL_AAVE_POOL_ADMIN = 0x5300A1a15135EA4dc7aD5a167152C01EFc9b192A;

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

        // The sUSDe supply cap on Aave is perpetually filled by real users.
        // Raise the supply cap via PoolConfigurator to allow our test deposit.
        vm.prank(LOCAL_AAVE_POOL_ADMIN);
        (bool ok,) = LOCAL_AAVE_CONFIGURATOR.call(
            abi.encodeWithSignature(
                "setSupplyCap(address,uint256)",
                Mainnet.SUSDE,
                uint256(2_000_000_000) // 2 billion sUSDe cap
            )
        );
        require(ok, "F08-05: setSupplyCap failed");

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

        // Standard mode (eMode 0): sUSDe is collateral at 72% LTV; borrows DAI.
        // eMode 2 ("sUSDe Stablecoins") cannot borrow DAI/USDC/USDT (they are
        // in eMode 0, which is incompatible with a user in eMode 2 on Aave V3).

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

        // Total DAI in hand = EQUITY_DAI + FLASH_DAI. Split into two sleeves.
        uint256 totalDai = IERC20(Mainnet.DAI).balanceOf(address(this));
        uint256 ptSleeve = (totalDai * PT_SLEEVE_BPS) / 10_000;
        uint256 loopSleeve = totalDai - ptSleeve;

        // ---- Sleeve A: PT-sUSDe via Pendle (extracted to reduce stack depth) ----
        _runPtSleeve(ptSleeve);

        // ---- Sleeve B: Aave sUSDe e-mode loop (extracted to reduce stack depth) ----
        _runAaveSleeve(loopSleeve);

        // ---- Repay flash by borrowing DAI from Aave ----
        uint256 repay = amount + fee;
        IAavePool(Mainnet.AAVE_V3_POOL).borrow(
            Mainnet.DAI, repay, RATE_MODE_VARIABLE, 0, address(this)
        );
        require(IERC20(Mainnet.DAI).balanceOf(address(this)) >= repay, "F08-05: insufficient DAI to repay flash");

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    /// @dev Sleeve A: convert daiAmt -> USDC -> USDe -> PT-sUSDe via Pendle.
    function _runPtSleeve(uint256 daiAmt) internal {
        // Curve 3pool's exchange() does NOT return a value (old V1 style).
        // Use a raw call to avoid ABI decode revert on missing return data.
        uint256 usdcBefore = IERC20(Mainnet.USDC).balanceOf(address(this));
        (bool ok1,) = Mainnet.CURVE_3POOL.call(
            abi.encodeWithSignature("exchange(int128,int128,uint256,uint256)", int128(0), int128(1), daiAmt, uint256(0))
        );
        require(ok1, "F08-05: 3pool DAI->USDC failed");
        uint256 usdcOut = IERC20(Mainnet.USDC).balanceOf(address(this)) - usdcBefore;

        uint256 usdeOut = ICurveStableSwap(LOCAL_CURVE_USDE_USDC).exchange(
            int128(1), int128(0), usdcOut, 0
        );

        IPendleRouter.TokenInput memory tin = IPendleRouter.TokenInput({
            tokenIn: Mainnet.USDE,
            netTokenIn: usdeOut,
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
            address(this), LOCAL_PENDLE_MARKET_PT_SUSDE_26SEP24, 0, approx, tin, lim
        );
        require(ptOut > 0, "F08-05: pendle PT out = 0");
    }

    /// @dev Sleeve B: convert daiAmt -> USDC -> USDe -> sUSDe -> supply to Aave.
    function _runAaveSleeve(uint256 daiAmt) internal {
        // Curve 3pool's exchange() does NOT return a value (old V1 style).
        uint256 usdcBefore = IERC20(Mainnet.USDC).balanceOf(address(this));
        (bool ok1,) = Mainnet.CURVE_3POOL.call(
            abi.encodeWithSignature("exchange(int128,int128,uint256,uint256)", int128(0), int128(1), daiAmt, uint256(0))
        );
        require(ok1, "F08-05: 3pool DAI->USDC failed (sleeve B)");
        uint256 usdcOut = IERC20(Mainnet.USDC).balanceOf(address(this)) - usdcBefore;

        uint256 usdeOut = ICurveStableSwap(LOCAL_CURVE_USDE_USDC).exchange(
            int128(1), int128(0), usdcOut, 0
        );
        uint256 shares = ISUSDe(Mainnet.SUSDE).deposit(usdeOut, address(this));
        IAavePool(Mainnet.AAVE_V3_POOL).supply(Mainnet.SUSDE, shares, address(this), 0);
    }
}
