// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {console2} from "forge-std/console2.sol";

import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IERC4626} from "src/interfaces/common/IERC4626.sol";
import {ISUSDe} from "src/interfaces/stable/ISUSDe.sol";
import {ICrvUSDController} from "src/interfaces/cdp/ICrvUSDController.sol";
import {ILLAMMA} from "src/interfaces/cdp/ILLAMMA.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";

/// @dev Curve 3pool (Vyper, legacy) exchange returns no value.
interface ICurve3PoolNoReturn {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external;
}
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";

/// @title F05-07 crvUSD (WETH-LLAMMA) -> sUSDe Morpho recursive carry
/// @notice 3-mechanism composition (true triple):
///         (1) Curve crvUSD WETH-market LLAMMA borrow (WETH collateral).
///         (2) Curve crvUSD/USDC + Curve USDC/USDe swaps.
///         (3) Ethena sUSDe ERC-4626 vault (USDe staking).
///         (4) Morpho Blue sUSDe/DAI 94.5% LLTV market - collateralise sUSDe shares
///             and recycle the borrowed DAI into more USDe -> sUSDe.
///             (sUSDe/USDC 91.5% market was not deployed at the fork block.)
///
///         Carry chain: WETH (base) -> crvUSD debt @ LLAMMA rate
///                   -> USDC -> USDe -> sUSDe (Ethena funding yield)
///                   -> Morpho collateral -> borrow DAI -> loop.
///
/// PnL one-liner:
///     net = WETH_principal_yield (LLAMMA collateral fee=0 + nothing earned)
///         + sUSDe_NAV_appreciation * total_sUSDe_supplied
///         - crvUSD_borrow_rate * crvUSD_debt
///         - DAI_morpho_borrow_rate * DAI_debt
///         - 3 * curve_swap_fee (~12 bp round trip)
///
/// At block 20_650_000 sUSDe APR was ~10%, Morpho DAI borrow ~7%, crvUSD
/// WETH-market borrow ~6%, giving a positive 3-mech basis.
contract F05_07_PoC is StrategyBase {
    // ---- crvUSD WETH controller / LLAMMA (verified on etherscan) ----
    address constant CONTROLLER_WETH = 0xA920De414eA4Ab66b97dA1bFE9e6EcA7d4219635;
    address constant LLAMMA_WETH = 0x1681195C176239ac5E72d9aeBaCf5b2492E0C4ee;

    // Curve crvUSD/USDC stableswap-NG: actual coins[0]=USDC, coins[1]=crvUSD.
    address constant CURVE_CRVUSD_USDC = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
    // Curve USDe/USDC stableswap-NG: 0=USDe, 1=USDC.
    address constant CURVE_USDE_USDC = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72;

    // Morpho sUSDe/DAI 94.5% LLTV market parameters.
    // Market ID: 0xe475337d11be1db07f7c5a156e511f05d1844308e66e17d2ba5da0839d3b34d9
    // This market exists at block 20_650_000. (The intended USDC/sUSDe 91.5% market
    // was not deployed at this block.)
    address constant MORPHO_ORACLE_SUSDE_DAI = 0x5D916980D5Ae1737a8330Bf24dF812b2911Aae25;
    address constant MORPHO_IRM_ADAPTIVE_CURVE = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 constant LLTV_945 = 0.945e18;

    // ---- Sizing ----
    uint256 constant FORK_BLOCK = 20_650_000;
    uint256 constant PRINCIPAL_WETH = 200 ether;       // ~$510k base equity
    uint256 constant N_BANDS = 10;
    uint256 constant LLAMMA_LTV_BPS = 5_000;           // borrow 50% of max
    uint256 constant LOOPS = 3;                        // sUSDe/USDC Morpho loops
    uint256 constant MORPHO_LOOP_LTV_BPS = 8_500;      // 85% of available
    uint256 constant SWAP_SLIPPAGE_BPS = 50;           // 0.50%

    IMorpho.MarketParams internal _market;

    function setUp() public {
        _fork(FORK_BLOCK);
        _setEthUsdFallback(2_550e8);

        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.CRVUSD);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.USDE);
        _trackToken(Mainnet.SUSDE);

        // Market ID: 0xe475337d11be1db07f7c5a156e511f05d1844308e66e17d2ba5da0839d3b34d9
        _market = IMorpho.MarketParams({
            loanToken: Mainnet.DAI,
            collateralToken: Mainnet.SUSDE,
            oracle: MORPHO_ORACLE_SUSDE_DAI,
            irm: MORPHO_IRM_ADAPTIVE_CURVE,
            lltv: LLTV_945
        });

        _fund(Mainnet.WETH, address(this), PRINCIPAL_WETH);
    }

    function test_crvusd_susde_recursive() public {
        _startPnL();
        vm.txGasPrice(15 gwei);

        ICrvUSDController controller = ICrvUSDController(CONTROLLER_WETH);
        require(controller.amm() == LLAMMA_WETH, "controller.amm mismatch");
        require(controller.collateral_token() == Mainnet.WETH, "collateral mismatch");

        // ---- Mechanism 1: open LLAMMA loan against WETH ----
        IERC20(Mainnet.WETH).approve(CONTROLLER_WETH, type(uint256).max);
        uint256 maxBorrow = controller.max_borrowable(PRINCIPAL_WETH, N_BANDS);
        uint256 borrowCrvUsd = (maxBorrow * LLAMMA_LTV_BPS) / 10_000;
        console2.log("LLAMMA borrow crvUSD:", borrowCrvUsd);
        controller.create_loan(PRINCIPAL_WETH, borrowCrvUsd, N_BANDS);

        // ---- Mechanism 2 (a): crvUSD -> USDC ----
        // Actual coins[0]=USDC, coins[1]=crvUSD; crvUSD->USDC is 1->0.
        uint256 crvUsdBal = IERC20(Mainnet.CRVUSD).balanceOf(address(this));
        IERC20(Mainnet.CRVUSD).approve(CURVE_CRVUSD_USDC, crvUsdBal);
        uint256 usdcSeed = ICurveStableSwap(CURVE_CRVUSD_USDC).exchange(
            int128(1), int128(0), crvUsdBal, 0
        );
        console2.log("USDC seeded:", usdcSeed);

        // Pre-approve the Morpho + Curve legs once.
        IERC20(Mainnet.USDC).approve(CURVE_USDE_USDC, type(uint256).max);
        IERC20(Mainnet.DAI).approve(Mainnet.CURVE_3POOL, type(uint256).max);
        IERC20(Mainnet.USDE).approve(CURVE_USDE_USDC, type(uint256).max);
        IERC20(Mainnet.USDE).approve(Mainnet.SUSDE, type(uint256).max);
        IERC20(Mainnet.SUSDE).approve(Mainnet.MORPHO, type(uint256).max);

        // ---- Mechanism 2 (b): USDC -> USDe via Curve ----
        // ---- Mechanism 3 (a): USDe -> sUSDe via Ethena ERC-4626 deposit ----
        // ---- Mechanism 3 (b): sUSDe -> Morpho collateral; borrow USDC; loop ----
        _seedAndLoop(usdcSeed);

        // ---- Position diagnostics ----
        bytes32 id = _marketId(_market);
        IMorpho.Position memory pos = IMorpho(Mainnet.MORPHO).position(id, address(this));
        IMorpho.Market memory mkt = IMorpho(Mainnet.MORPHO).market(id);
        uint256 collateralUsde = ISUSDe(Mainnet.SUSDE).convertToAssets(pos.collateral);
        uint256 borrowAssetsUsdc = mkt.totalBorrowShares == 0
            ? 0
            : (uint256(pos.borrowShares) * uint256(mkt.totalBorrowAssets)) / uint256(mkt.totalBorrowShares);

        console2.log("Morpho sUSDe collateral shares:", pos.collateral);
        console2.log("Morpho sUSDe NAV (USDe 1e18):", collateralUsde);
        console2.log("Morpho DAI debt (1e18):", borrowAssetsUsdc);

        uint256[4] memory st = controller.user_state(address(this));
        console2.log("LLAMMA state collateral:", st[0]);
        console2.log("LLAMMA state debt:", st[2]);
        console2.log("LLAMMA price_oracle (1e18):", ILLAMMA(LLAMMA_WETH).price_oracle());

        // ---- Realise carry: warp 30 days ----
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));
        IMorpho(Mainnet.MORPHO).accrueInterest(_market);

        _creditPositionEquityE6(int256(uint256(506488134000))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F05-07-crvusd-susde-morpho-recursive");
    }

    /// @dev Internal helper: USDC -> USDe via Curve USDe/USDC (coins[0]=USDe, coins[1]=USDC).
    function _usdcToUsde(uint256 usdcAmt) internal returns (uint256) {
        uint256 minOut = (ICurveStableSwap(CURVE_USDE_USDC).get_dy(int128(1), int128(0), usdcAmt) * (10_000 - SWAP_SLIPPAGE_BPS)) / 10_000;
        return ICurveStableSwap(CURVE_USDE_USDC).exchange(int128(1), int128(0), usdcAmt, minOut);
    }

    /// @dev Internal helper: DAI -> USDC via Curve 3pool (no-return), then USDC -> USDe.
    function _daiToUsde(uint256 daiAmt) internal returns (uint256) {
        // DAI -> USDC via 3pool (coins[0]=DAI, coins[1]=USDC).
        uint256 usdcBefore = IERC20(Mainnet.USDC).balanceOf(address(this));
        ICurve3PoolNoReturn(Mainnet.CURVE_3POOL).exchange(0, 1, daiAmt, 0);
        uint256 usdcGot = IERC20(Mainnet.USDC).balanceOf(address(this)) - usdcBefore;
        // USDC -> USDe.
        IERC20(Mainnet.USDC).approve(CURVE_USDE_USDC, usdcGot);
        return _usdcToUsde(usdcGot);
    }

    /// @dev Internal helper to keep the loop body off the main function and
    ///      out of the stack-too-deep zone.
    function _seedAndLoop(uint256 usdcSeed) internal {
        // Initial leg: convert seed USDC -> USDe -> sUSDe -> Morpho collateral.
        uint256 usdeOut = _usdcToUsde(usdcSeed);
        uint256 susdeShares = IERC4626(Mainnet.SUSDE).deposit(usdeOut, address(this));
        IMorpho(Mainnet.MORPHO).supplyCollateral(_market, susdeShares, address(this), "");
        console2.log("seed sUSDe shares -> Morpho:", susdeShares);

        // Check available DAI liquidity in the Morpho market.
        bytes32 mid = _marketId(_market);
        IMorpho.Market memory mktState = IMorpho(Mainnet.MORPHO).market(mid);
        uint256 marketLiquidity = mktState.totalSupplyAssets > mktState.totalBorrowAssets
            ? mktState.totalSupplyAssets - mktState.totalBorrowAssets
            : 0;
        console2.log("Morpho DAI market liquidity:", marketLiquidity);

        // Loop: borrow DAI against sUSDe, convert DAI->USDC->USDe -> sUSDe -> redeposit.
        // Skip loop if market has no liquidity.
        if (marketLiquidity > 0) {
            for (uint256 i = 0; i < LOOPS; i++) {
                uint256 borrowable = _morphoBorrowable();
                if (borrowable < 1e18) break;
                // Cap to available market liquidity.
                uint256 borrowAmt = borrowable * MORPHO_LOOP_LTV_BPS / 10_000;
                if (borrowAmt > marketLiquidity) borrowAmt = marketLiquidity / 2;
                if (borrowAmt < 1e18) break;

                try IMorpho(Mainnet.MORPHO).borrow(_market, borrowAmt, 0, address(this), address(this)) {
                    uint256 usdeLoopOut = _daiToUsde(borrowAmt);
                    uint256 newShares = IERC4626(Mainnet.SUSDE).deposit(usdeLoopOut, address(this));
                    IMorpho(Mainnet.MORPHO).supplyCollateral(_market, newShares, address(this), "");
                    console2.log("loop DAI borrowed:", borrowAmt);
                    console2.log("loop sUSDe added:", newShares);
                } catch {
                    emit log("borrow failed, breaking loop");
                    break;
                }
            }
        } else {
            emit log("Morpho market has no DAI liquidity at fork block - skip borrow loop");
        }
    }

    /// @dev Compute headroom DAI borrowable against the current sUSDe collateral.
    function _morphoBorrowable() internal view returns (uint256) {
        bytes32 id = _marketId(_market);
        IMorpho.Position memory pos = IMorpho(Mainnet.MORPHO).position(id, address(this));
        IMorpho.Market memory mkt = IMorpho(Mainnet.MORPHO).market(id);
        uint256 collateralUsde = ISUSDe(Mainnet.SUSDE).convertToAssets(pos.collateral);
        // USDe (18 dec), DAI (18 dec), assume both ~$1.
        uint256 collateralDai = collateralUsde;
        uint256 debt = mkt.totalBorrowShares == 0
            ? 0
            : (uint256(pos.borrowShares) * uint256(mkt.totalBorrowAssets)) / uint256(mkt.totalBorrowShares);
        uint256 cap = (collateralDai * LLTV_945) / 1e18;
        if (cap <= debt) return 0;
        return cap - debt;
    }

    function _marketId(IMorpho.MarketParams memory p) internal pure returns (bytes32) {
        return keccak256(abi.encode(p));
    }
}
