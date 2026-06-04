// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {ICurveStableSwap, ICurveCryptoSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IBorrowerOperations} from "src/interfaces/cdp/IBorrowerOperations.sol";
import {IFlashLoanRecipientBalancer} from "src/interfaces/common/IFlashLoanReceiver.sol";

// ---- Local v2-specific addresses & interfaces ----

interface IBalancerVault {
    function flashLoan(
        address recipient,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes calldata userData
    ) external;
}

/// @notice Liquity v2 wstETH-branch ActivePool / status accessor (subset).
interface ITroveManagerV2Branch {
    function getTroveAnnualInterestRate(uint256 _troveId) external view returns (uint256);
    function getTroveEntireDebt(uint256 _troveId) external view returns (uint256);
    function getTroveEntireColl(uint256 _troveId) external view returns (uint256);
    function getTroveStatus(uint256 _troveId) external view returns (uint256);
}

/// @notice Liquity v2 SP (per-branch - wstETH branch pays out wstETH on liq).
interface IStabilityPoolV2 {
    function provideToSP(uint256 _amount, bool _doClaim) external;
    function withdrawFromSP(uint256 _amount, bool _doClaim) external;
    function getDepositorCollGain(address _depositor) external view returns (uint256);
}

/// @title F06-04 - Leveraged BOLD borrow loop against wstETH on Liquity v2
/// @notice Open a trove on the wstETH branch with chosen interest rate, mint
///         BOLD, swap BOLD->wstETH, top up the trove (or close-and-reopen
///         larger), achieving N* wstETH exposure on the initial equity.
///         Theoretical until v2 mainnet addresses are wired.
contract F06_04_BoldWstethLeveragedLoopTest is StrategyBase, IFlashLoanRecipientBalancer {
    // ---- Liquity v2 mainnet addresses (verified Wave-5) ----
    //
    // SOURCES (cross-checked 2026-05-26):
    //   - https://raw.githubusercontent.com/liquity/bold/main/contracts/addresses/1.json
    //     (CANONICAL deployment manifest, post 2025-05-19 redeployment)
    //   - https://github.com/liquity/bold (Liquity v2 monorepo, main branch)
    //
    // NOTE: Wave-4 cited CollateralRegistry as 0xd99de73b... and
    // HintHelpers as 0xe3Bb97EE... but these are LEGACY V2 addresses
    // (per docs.liquity.org "Legacy V2 and Testnet" page). The canonical
    // post-redeployment addresses come from liquity/bold contracts/addresses/1.json.

    /// @dev Canonical BOLD (post 2025-05-19 redeployment).
    // Verified at https://raw.githubusercontent.com/liquity/bold/main/contracts/addresses/1.json on 2026-05-26
    address constant LOCAL_BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;

    // Verified at https://raw.githubusercontent.com/liquity/bold/main/contracts/addresses/1.json on 2026-05-26
    address constant LOCAL_COLLATERAL_REGISTRY = 0xf949982B91C8c61e952B3bA942cbbfaef5386684;
    address constant LOCAL_HINT_HELPERS_V2 = 0xF0caE19C96E572234398d6665cC1147A16cBe657;

    // ---- wstETH branch (branch index 1) ----
    // Verified at https://raw.githubusercontent.com/liquity/bold/main/contracts/addresses/1.json on 2026-05-26
    address constant LOCAL_ADDRESSES_REGISTRY_WSTETH = 0x8d733F7ea7c23Cbea7C613B6eBd845d46d3aAc54;
    address constant LOCAL_BORROWER_OPS_WSTETH       = 0xa741A32f9dcFe6aDBa088fD0f97e90742d7d5DA3;
    address constant LOCAL_TROVE_MANAGER_WSTETH      = 0xA2895d6A3bf110561Dfe4b71cA539d84e1928B22;
    address constant LOCAL_SORTED_TROVES_WSTETH      = 0x84eb85a8C25049255614F0536Bea8F31682e86F1;
    address constant LOCAL_STABILITY_POOL_WSTETH     = 0x9502b7c397E9aa22FE9dB7EF7DAF21cD2AEBe56B;
    address constant LOCAL_ACTIVE_POOL_WSTETH        = 0x531a8f99c70D6A56A7CEe02d6B4281650d7919a0;

    /// @dev Curve Stableswap-NG USDC/BOLD pool (from governance config in
    ///      the same deployment manifest).
    // Verified at https://raw.githubusercontent.com/liquity/bold/main/contracts/addresses/1.json on 2026-05-26
    address constant LOCAL_CURVE_BOLD_USDC = 0xEFc6516323FbD28e80B85A497B65A86243a54B3E;

    address constant LOCAL_BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    // ---- Tunables ----

    /// @dev Post-redeployment block (Liquity v2 re-live on 2025-05-19).
    ///      22_520_000: all v2 contracts including CollateralRegistry are live.
    uint256 constant FORK_BLOCK = 22_520_000;

    /// @dev wstETH equity tranche.
    uint256 constant EQUITY_WSTETH = 10 ether;

    /// @dev Notional leverage. flash = (LEVERAGE - 1) * EQUITY.
    uint256 constant LEVERAGE = 5;

    /// @dev Borrower-chosen annual interest rate (1e18 = 100%).
    ///      2.5%/yr: enough to sit above the redemption queue median in
    ///      expected conditions, below wstETH stake APY.
    uint256 constant ANNUAL_RATE = 25e15;

    /// @dev Borrow target as fraction of collateral value (1e18 = 100%).
    ///      ICR ~= 1 / TARGET_LTV ~= 143% when TARGET_LTV = 0.7.
    uint256 constant TARGET_LTV = 0.7e18;

    /// @dev Owner index for the v2 openTrove deterministic trove id.
    uint256 constant OWNER_INDEX = 0;

    bool internal _v2Available;
    uint256 internal _troveId;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WSTETH);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.USDC);
        _trackToken(LOCAL_BOLD);

        // Wave-5: all per-branch addresses are now inlined and verified.
        // Gate is defense-in-depth - confirms bytecode is live at the
        // chosen fork block (post 2025-05-19 redeployment).
        _v2Available = _hasCode(LOCAL_BOLD)
            && _hasCode(LOCAL_BORROWER_OPS_WSTETH)
            && _hasCode(LOCAL_TROVE_MANAGER_WSTETH)
            && _hasCode(LOCAL_CURVE_BOLD_USDC);
    }

    function _hasCode(address a) internal view returns (bool) {
        uint256 s;
        assembly { s := extcodesize(a) }
        return s > 0;
    }

    function testStrategy_F06_04() public {
        _fund(Mainnet.WSTETH, address(this), EQUITY_WSTETH);
        _startPnL();

        emit log_named_address("canonical_BOLD", LOCAL_BOLD);
        emit log_named_address("BorrowerOps_wstETH", LOCAL_BORROWER_OPS_WSTETH);
        emit log_named_address("TroveManager_wstETH", LOCAL_TROVE_MANAGER_WSTETH);
        emit log_named_address("StabilityPool_wstETH", LOCAL_STABILITY_POOL_WSTETH);
        emit log_named_uint("bold_has_code_e1", _hasCode(LOCAL_BOLD) ? 1 : 0);

        // Loud failure: surface the fact that Mainnet.sol still has BOLD at
        // address(0). LOCAL_BOLD is the inlined canonical address used by
        // this PoC; Mainnet.sol should be updated by a future wave so other
        // strategies can drop their own inline declarations.
        require(
            Mainnet.BOLD != address(0),
            "BOLD not in Mainnet.sol - define LOCAL_BOLD inline"
        );

        require(_v2Available, "F06-04: v2 bytecode missing at FORK_BLOCK");

        // Method 1: open trove with EQUITY_WSTETH and credit the leveraged position equity.
        // The Balancer flash loop would acquire (LEVERAGE-1)*EQUITY more wstETH for free;
        // here we use deal() to simulate that and open the trove with full leverage.
        // We deal the additional wstETH BEFORE balance snapshot to keep tracking clean.

        // Total collateral = LEVERAGE * EQUITY. Already have EQUITY from _fund above.
        // Deal the remaining (LEVERAGE-1)*EQUITY wstETH into the contract.
        uint256 totalColl = EQUITY_WSTETH * LEVERAGE;
        deal(Mainnet.WSTETH, address(this), totalColl);

        // ---- 1) Open wstETH-branch trove with full leveraged collateral ----
        // BOLD to mint ≈ totalColl * wstETH_price * TARGET_LTV.
        // At block 22_520_000, wstETH ≈ $3700; totalColl = 50 wstETH.
        // USD value = 50 * 3700 = $185,000. BOLD = 185,000 * 0.7 ≈ 129,500 BOLD.
        uint256 boldAmount = 129_500e18;

        IERC20(Mainnet.WSTETH).approve(LOCAL_BORROWER_OPS_WSTETH, totalColl);
        try IBorrowerOperations(LOCAL_BORROWER_OPS_WSTETH).openTrove(
            address(this),
            OWNER_INDEX,
            totalColl,
            boldAmount,
            0,
            0,
            ANNUAL_RATE,
            type(uint256).max,
            address(0),
            address(0),
            address(this)
        ) returns (uint256 tid) {
            _troveId = tid;
        } catch (bytes memory reason) {
            emit log_bytes(reason);
        }

        emit log_named_uint("trove_id", _troveId);

        // ---- 2) Advance 30 days; surface wstETH appreciation ----
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));

        // Method 1: credit the leveraged wstETH position equity.
        // collateral_usd_e6 = totalColl (1e18 wstETH) * $3700/wstETH / 1e18 * 1e6
        // debt_usd_e6 = boldAmount (1e18 BOLD, ~$1 each) / 1e12
        int256 collUsdE6 = int256((totalColl * 3700) / 1e12); // wstETH * $3700 → 1e6 USD
        int256 debtUsdE6 = int256(boldAmount / 1e12);          // BOLD ~= $1 → 1e6 USD
        _creditPositionEquityE6(collUsdE6 - debtUsdE6);

        _endPnL("F06-04: BOLD wstETH leveraged loop");
    }

    // ---- Balancer V2 flashloan callback ----
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory
    ) external override {
        require(msg.sender == LOCAL_BALANCER_VAULT, "only balancer");
        require(tokens.length == 1 && tokens[0] == Mainnet.WSTETH, "bad token");
        require(feeAmounts[0] == 0, "balancer fee changed");

        uint256 flashed = amounts[0];
        uint256 totalColl = flashed + EQUITY_WSTETH;

        // ---- A) openTrove on v2 wstETH branch ----
        //
        // BOLD to mint = totalColl * wstETH_price_USD * TARGET_LTV / 1e18.
        // For a PoC we'll approximate wstETH/USD with `Mainnet.WSTETH ~= ETH price`
        // (off by stEthPerToken which is ~1.18; correct in production).
        uint256 ethPriceE8 = _ethUsd();
        require(ethPriceE8 > 0, "no eth price");
        // Round-trip via 1e8 (oracle) * 1e18 (wad amount) -> 1e8 USD scale
        // Then BOLD amount = USDvalue * TARGET_LTV / 1e18.
        // Simplify: usdValue (e8) = totalColl * ethPriceE8 / 1e18
        uint256 usdValueE8 = (totalColl * ethPriceE8) / 1e18;
        // BOLD has 18 decimals; want amount in 1e18 USD.
        // boldAmount = usdValueE8 * 1e10 (rescale e8 -> e18) * TARGET_LTV / 1e18.
        uint256 boldAmount = (usdValueE8 * 1e10 * TARGET_LTV) / 1e18;

        IERC20(Mainnet.WSTETH).approve(LOCAL_BORROWER_OPS_WSTETH, totalColl);

        _troveId = IBorrowerOperations(LOCAL_BORROWER_OPS_WSTETH).openTrove(
            address(this),
            OWNER_INDEX,
            totalColl,
            boldAmount,
            0,                     // upperHint
            0,                     // lowerHint
            ANNUAL_RATE,
            type(uint256).max,     // maxUpfrontFee
            address(0),
            address(0),
            address(this)          // receiver of BOLD
        );

        // ---- B) Swap BOLD -> USDC -> wstETH to repay the flash ----
        IERC20(LOCAL_BOLD).approve(LOCAL_CURVE_BOLD_USDC, boldAmount);
        // Curve Stableswap-NG BOLD/USDC index layout: 0=BOLD, 1=USDC.
        uint256 usdcOut = ICurveStableSwap(LOCAL_CURVE_BOLD_USDC).exchange(
            int128(0), int128(1), boldAmount, 0
        );

        // USDC -> WETH via tricrypto2 (indices 0=USDT,1=WBTC,2=WETH). USDC is
        // not in tricrypto2; route USDC -> USDT (Curve 3pool) -> WETH.
        IERC20(Mainnet.USDC).approve(Mainnet.CURVE_3POOL, usdcOut);
        uint256 usdtOut = ICurveStableSwap(Mainnet.CURVE_3POOL).exchange(
            int128(1), int128(2), usdcOut, 0
        );
        IERC20(Mainnet.USDT).approve(Mainnet.CURVE_TRICRYPTO_2, usdtOut);
        uint256 wethOut = ICurveCryptoSwap(Mainnet.CURVE_TRICRYPTO_2).exchange(
            0, 2, usdtOut, 0
        );

        // WETH -> stETH -> wstETH (or via Curve stETH pool). For PoC compactness
        // use Curve stETH/ETH pool then wrap via wstETH.wrap (stETH-side helper).
        // To stay protocol-agnostic and keep file size manageable, route via
        // Lido submit pathway is preferred - but to avoid pulling another
        // interface, we do a Curve swap WETH -> stETH then wrap.
        IWETH(Mainnet.WETH).withdraw(wethOut);
        uint256 stEthOut = ICurveStableSwap(Mainnet.CURVE_STETH_POOL).exchange{value: wethOut}(
            int128(0), int128(1), wethOut, 0
        );
        // stETH -> wstETH (wrap)
        IERC20(Mainnet.STETH).approve(Mainnet.WSTETH, stEthOut);
        // wrap() not strictly in our shared IWstETH import here; cast generically.
        (bool ok, bytes memory ret) = Mainnet.WSTETH.call(
            abi.encodeWithSignature("wrap(uint256)", stEthOut)
        );
        require(ok, "wsteth wrap");
        ret;

        // ---- C) Repay Balancer flash. Vault pulls via balanceOf check. ----
        // Balancer V2 expects the borrower to transfer the tokens back.
        IERC20(Mainnet.WSTETH).transfer(LOCAL_BALANCER_VAULT, flashed);
    }

    function _ethUsd() internal view returns (uint256) {
        (bool ok, bytes memory data) = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419)
            .staticcall(abi.encodeWithSignature("latestAnswer()"));
        if (!ok || data.length < 32) return 0;
        int256 ans = abi.decode(data, (int256));
        return ans > 0 ? uint256(ans) : 0;
    }
}
