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

/// @notice Liquity v2 SP (per-branch — wstETH branch pays out wstETH on liq).
interface IStabilityPoolV2 {
    function provideToSP(uint256 _amount, bool _doClaim) external;
    function withdrawFromSP(uint256 _amount, bool _doClaim) external;
    function getDepositorCollGain(address _depositor) external view returns (uint256);
}

/// @title F06-04 — Leveraged BOLD borrow loop against wstETH on Liquity v2
/// @notice Open a trove on the wstETH branch with chosen interest rate, mint
///         BOLD, swap BOLD→wstETH, top up the trove (or close-and-reopen
///         larger), achieving N× wstETH exposure on the initial equity.
///         Theoretical until v2 mainnet addresses are wired.
contract F06_04_BoldWstethLeveragedLoopTest is StrategyBase, IFlashLoanRecipientBalancer {
    // ---- Liquity v2 mainnet addresses (verified Wave-4) ----
    //
    // SOURCES:
    //   - https://docs.liquity.org/v2-documentation/technical-resources
    //   - https://etherscan.io/token/0x6440f144b7e50D6a8439336510312d2F54beB01D
    //   - https://www.liquity.org/blog/liquity-v2-redeployment
    //
    // Canonical BOLD (post 2025-05-19 redeployment).
    address constant LOCAL_BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;

    // CollateralRegistry is the only system-level entrypoint that exposes
    // each branch's BorrowerOperations via getBranch(N) helper. We resolve
    // wstETH-branch contracts at runtime where possible.
    address constant LOCAL_COLLATERAL_REGISTRY = 0xd99de73b95236f69A559117ECD6F519Af780F3f7;
    address constant LOCAL_HINT_HELPERS_V2 = 0xe3Bb97EE79AC4bdfc0c30A95aD82c243c9913AdA;

    // wstETH-branch contracts. The May-2025 redeployment swapped the previous
    // addresses (Etherscan now labels them "Old <X> wstETH"). The replacement
    // addresses are not all under stable labels at Wave-4. We keep them as
    // 0x0 + gate, but document the known DefaultPool (legacy) for traceability.
    //
    // Legacy (pre-redeployment, DO NOT use for real txs):
    //   DefaultPool wstETH  = 0xd796e1648526400386cc4d12fa05e5f11e6a22a1
    //   Old BO WETH branch = 0x0b995602b5a797823f92027e8b40c0f2d97aff1c
    //   Old TM WETH branch = 0x81d78814df42da2cab0e8870c477bc3ed861de66
    //   Old ST WETH branch = 0x879474cfbb980fb6899aaaa9b5d5ee14ffbf85a9
    //   Possible TM wstETH = 0x1cc79f3f47bfc060b6f761fcd1afc6d399a968b6 (search-derived; UNVERIFIED label)
    address constant LOCAL_BORROWER_OPS_WSTETH = address(0); // pending registry probe
    address constant LOCAL_TROVE_MANAGER_WSTETH = address(0);
    address constant LOCAL_STABILITY_POOL_WSTETH = address(0);
    address constant LOCAL_CURVE_BOLD_USDC = address(0);

    address constant LOCAL_BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    // ---- Tunables ----

    /// @dev Post-redeployment block (Liquity v2 re-live on 2025-05-19).
    ///      ~22,500,000 ≈ mid-June 2025; first month with v2 trove activity.
    uint256 constant FORK_BLOCK = 22_500_000;

    /// @dev wstETH equity tranche.
    uint256 constant EQUITY_WSTETH = 10 ether;

    /// @dev Notional leverage. flash = (LEVERAGE - 1) × EQUITY.
    uint256 constant LEVERAGE = 5;

    /// @dev Borrower-chosen annual interest rate (1e18 = 100%).
    ///      2.5%/yr: enough to sit above the redemption queue median in
    ///      expected conditions, below wstETH stake APY.
    uint256 constant ANNUAL_RATE = 25e15;

    /// @dev Borrow target as fraction of collateral value (1e18 = 100%).
    ///      ICR ≈ 1 / TARGET_LTV ≈ 143% when TARGET_LTV = 0.7.
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

        // BOLD must have code; per-branch addresses must be wired.
        _v2Available = _hasCode(LOCAL_BOLD)
            && LOCAL_BORROWER_OPS_WSTETH != address(0)
            && LOCAL_TROVE_MANAGER_WSTETH != address(0)
            && LOCAL_CURVE_BOLD_USDC != address(0);
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
        emit log_named_uint("bold_has_code_e1", _hasCode(LOCAL_BOLD) ? 1 : 0);

        if (!_v2Available) {
            emit log_string("F06-04: per-branch wstETH addresses pending; structural placeholder.");
            emit log_named_uint("planned_equity_wstETH", EQUITY_WSTETH);
            emit log_named_uint("planned_leverage", LEVERAGE);
            emit log_named_uint("planned_annual_rate_e18", ANNUAL_RATE);
            _endPnL("F06-04: BOLD wstETH leveraged loop (theoretical)");
            return;
        }

        // ---- 1) Borrow (LEVERAGE-1) × EQUITY wstETH from Balancer flashloan ----
        address[] memory tokens = new address[](1);
        tokens[0] = Mainnet.WSTETH;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = EQUITY_WSTETH * (LEVERAGE - 1);

        IBalancerVault(LOCAL_BALANCER_VAULT).flashLoan(
            address(this), tokens, amounts, ""
        );

        // ---- 2) Inspect resulting trove ----
        if (_troveId != 0) {
            emit log_named_uint("trove_id", _troveId);
            emit log_named_uint("trove_debt_bold", ITroveManagerV2Branch(LOCAL_TROVE_MANAGER_WSTETH).getTroveEntireDebt(_troveId));
            emit log_named_uint("trove_coll_wsteth", ITroveManagerV2Branch(LOCAL_TROVE_MANAGER_WSTETH).getTroveEntireColl(_troveId));
            emit log_named_uint("trove_rate_e18", ITroveManagerV2Branch(LOCAL_TROVE_MANAGER_WSTETH).getTroveAnnualInterestRate(_troveId));
        }

        // ---- 3) Advance 30 days; surface interest accrual ----
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));

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
        // For a PoC we'll approximate wstETH/USD with `Mainnet.WSTETH ≈ ETH price`
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
        // Lido submit pathway is preferred — but to avoid pulling another
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
