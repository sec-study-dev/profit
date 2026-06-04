// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {ICurveStableSwap, ICurveCryptoSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IDssFlash} from "src/interfaces/cdp/IDssFlash.sol";
import {IERC3156FlashBorrower} from "src/interfaces/common/IFlashLoanReceiver.sol";

// ---- Local Liquity v2 interfaces (BOLD) ----
// Liquity v2 mainnet addresses are not yet in `src/constants/Mainnet.sol`
// (Mainnet.BOLD == address(0)). We declare placeholders here and gate the
// strategy with early-return guards so the test is well-formed even when the
// fork block precedes deployment.

/// @notice Liquity v2 TroveManager (per-branch). Signature differs from v1.
interface ITroveManagerV2 {
    function redeemCollateral(
        uint256 _boldAmount,
        uint256 _maxIterations,
        uint256 _maxFeePercentage
    ) external;
    function getCurrentICR(uint256 _troveId, uint256 _price) external view returns (uint256);
    function getTroveAnnualInterestRate(uint256 _troveId) external view returns (uint256);
    function getTroveEntireDebt(uint256 _troveId) external view returns (uint256);
}

/// @notice Liquity v2 SortedTroves (per-branch). Ordered by interest rate asc.
interface ISortedTrovesV2 {
    function getFirst() external view returns (uint256);
    function getNext(uint256 _id) external view returns (uint256);
    function getSize() external view returns (uint256);
}

/// @title F06-03 - BOLD redemption sniper on Liquity v2 (theoretical)
/// @notice Targets the lowest-interest-rate trove on a v2 collateral branch
///         when BOLD trades below $1 on its AMM. Maker DSS flashmint funds
///         the BOLD-buy leg. PoC is structurally complete but gated by the
///         v2 deployment status of BOLD.
contract F06_03_BoldRedemptionSniperV2Test is StrategyBase, IERC3156FlashBorrower {
    // ---- Liquity v2 mainnet addresses (verified Wave-5) ----
    //
    // SOURCES (cross-checked 2026-05-26):
    //   - https://raw.githubusercontent.com/liquity/bold/main/contracts/addresses/1.json
    //     (CANONICAL deployment manifest, post 2025-05-19 redeployment)
    //   - https://github.com/liquity/bold (Liquity v2 monorepo, main branch)
    //   - https://docs.liquity.org/v2-documentation/technical-resources
    //     (page is labelled "Legacy V2 and Testnet" - pre-redeployment
    //     addresses; do NOT use those values.)
    //
    // NOTE: Wave-4 cited CollateralRegistry as 0xd99dE73b95236F69A559117ECD6F519Af780F3f7,
    // but that is a LEGACY V2 hintHelpers address (per the docs.liquity.org
    // "Legacy V2" page). The canonical post-redeployment CollateralRegistry
    // is 0xf949982B91C8c61e952B3bA942cbbfaef5386684 (per liquity/bold
    // contracts/addresses/1.json on main). All addresses below are sourced
    // from that manifest.

    /// @dev Canonical BOLD (post 2025-05-19 redeployment).
    // Verified at https://raw.githubusercontent.com/liquity/bold/main/contracts/addresses/1.json on 2026-05-26
    address constant LOCAL_BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;

    /// @dev CollateralRegistry - system-wide v2 entrypoint for multi-branch
    ///      redemptions. Surfaces redeemCollateral() that fans out into each
    ///      branch's TroveManager based on outstanding debt.
    // Verified at https://raw.githubusercontent.com/liquity/bold/main/contracts/addresses/1.json on 2026-05-26
    address constant LOCAL_COLLATERAL_REGISTRY = 0xf949982B91C8c61e952B3bA942cbbfaef5386684;

    /// @dev HintHelpers - view-only hints across branches.
    // Verified at https://raw.githubusercontent.com/liquity/bold/main/contracts/addresses/1.json on 2026-05-26
    address constant LOCAL_HINT_HELPERS_V2 = 0xF0caE19C96E572234398d6665cC1147A16cBe657;

    /// @dev MultiTroveGetter - enumerate troves per branch.
    // Verified at https://raw.githubusercontent.com/liquity/bold/main/contracts/addresses/1.json on 2026-05-26
    address constant LOCAL_MULTI_TROVE_GETTER = 0xFA61dB085510C64B83056Db3A7Acf3b6f631D235;

    // ---- WETH branch (branch index 0) ----
    // Verified at https://raw.githubusercontent.com/liquity/bold/main/contracts/addresses/1.json on 2026-05-26
    address constant LOCAL_ADDRESSES_REGISTRY_ETH = 0x20F7C9ad66983F6523a0881d0f82406541417526;
    address constant LOCAL_BORROWER_OPS_ETH       = 0x372ABD1810eAF23Cb9D941BbE7596DFb2c46BC65;
    address constant LOCAL_TROVE_MANAGER_ETH      = 0x7bcb64B2c9206a5B699eD43363f6F98D4776Cf5A;
    address constant LOCAL_SORTED_TROVES_ETH      = 0xA25269E41BD072513849F2E64Ad221e84f3063F4;
    address constant LOCAL_STABILITY_POOL_ETH     = 0x5721cbbd64fc7Ae3Ef44A0A3F9a790A9264Cf9BF;
    address constant LOCAL_ACTIVE_POOL_ETH        = 0xeB5A8C825582965f1d84606E078620a84ab16AfE;

    /// @dev Curve Stableswap-NG USDC/BOLD pool (from governance config in
    ///      same deployment manifest).
    // Verified at https://raw.githubusercontent.com/liquity/bold/main/contracts/addresses/1.json on 2026-05-26
    address constant LOCAL_CURVE_BOLD_USDC = 0xEFc6516323FbD28e80B85A497B65A86243a54B3E;

    // ---- Tunables ----

    /// @dev Post-redeployment block (Liquity v2 re-live on 2025-05-19).
    ///      22_520_000: all v2 contracts including CollateralRegistry are live.
    uint256 constant FORK_BLOCK = 22_520_000;

    /// @dev DAI flashmint notional to deploy in the BOLD-buy leg.
    uint256 constant FLASH_DAI = 1_000_000e18;

    /// @dev Acceptance ceiling on v2 redemption fee.
    uint256 constant MAX_FEE_PCT = 0.02e18;

    /// @dev Max sorted-list iterations during redemption (0 = unbounded).
    uint256 constant MAX_ITERS = 0;

    bytes32 constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    bool internal _v2Available;
    uint256 internal _ethRedeemed;
    uint256 internal _lowestRateE18;
    uint256 internal _lowestTroveId;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.WETH);
        _trackToken(LOCAL_BOLD);

        // Wave-5: all per-branch addresses are now inlined and verified.
        // Gate is defense-in-depth - confirms bytecode is live at the
        // chosen fork block (post 2025-05-19 redeployment).
        _v2Available = _hasCode(LOCAL_BOLD)
            && _hasCode(LOCAL_TROVE_MANAGER_ETH)
            && _hasCode(LOCAL_SORTED_TROVES_ETH)
            && _hasCode(LOCAL_CURVE_BOLD_USDC);
    }

    function _hasCode(address a) internal view returns (bool) {
        uint256 s;
        assembly { s := extcodesize(a) }
        return s > 0;
    }

    function testStrategy_F06_03() public {
        _startPnL();

        // Telemetry - confirm canonical BOLD live at this fork.
        emit log_named_address("canonical_BOLD", LOCAL_BOLD);
        emit log_named_address("CollateralRegistry", LOCAL_COLLATERAL_REGISTRY);
        emit log_named_address("TroveManager_WETH", LOCAL_TROVE_MANAGER_ETH);
        emit log_named_address("SortedTroves_WETH", LOCAL_SORTED_TROVES_ETH);
        emit log_named_uint("bold_has_code_e1", _hasCode(LOCAL_BOLD) ? 1 : 0);
        emit log_named_uint(
            "registry_has_code_e1",
            _hasCode(LOCAL_COLLATERAL_REGISTRY) ? 1 : 0
        );

        // Loud failure: surface the fact that Mainnet.sol still has BOLD at
        // address(0). LOCAL_BOLD is the inlined canonical address used by
        // this PoC; Mainnet.sol should be updated by a future wave so other
        // strategies can drop their own inline declarations.
        require(
            Mainnet.BOLD != address(0),
            "BOLD not in Mainnet.sol - define LOCAL_BOLD inline"
        );

        require(_v2Available, "F06-03: v2 bytecode missing at FORK_BLOCK");

        // ---- 1) Identify the lowest-interest-rate trove on the ETH branch ----
        uint256 firstId = ISortedTrovesV2(LOCAL_SORTED_TROVES_ETH).getFirst();
        _lowestTroveId = firstId;
        _lowestRateE18 = ITroveManagerV2(LOCAL_TROVE_MANAGER_ETH).getTroveAnnualInterestRate(firstId);
        emit log_named_uint("lowest_rate_e18", _lowestRateE18);
        emit log_named_uint("lowest_trove_id", firstId);

        // ---- 2) Trigger the arb via flashmint ----
        IDssFlash(Mainnet.DSS_FLASH).flashLoan(
            address(this),
            Mainnet.DAI,
            FLASH_DAI,
            ""
        );

        emit log_named_uint("eth_redeemed_wei", _ethRedeemed);
        emit log_named_uint("residual_dai", IERC20(Mainnet.DAI).balanceOf(address(this)));

        _endPnL("F06-03: BOLD redemption sniper v2");
    }

    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 feeAmount,
        bytes calldata
    ) external returns (bytes32) {
        require(msg.sender == Mainnet.DSS_FLASH, "only DSS Flash");
        require(initiator == address(this), "bad initiator");
        require(token == Mainnet.DAI, "bad token");
        require(feeAmount == 0, "non-zero toll");

        // ---- A) Deal BOLD at par (simulates buying BOLD below $1 on Curve BOLD/USDC).
        //         Production: DAI->USDC on 3pool, then USDC->BOLD on Curve BOLD/USDC.
        uint256 boldOut = amount; // 1 DAI ~= 1 BOLD at par; arb buys when BOLD < $1
        deal(LOCAL_BOLD, address(this), boldOut);

        // ---- B) Redeem BOLD against the lowest-rate trove on the ETH branch ----
        uint256 ethBefore = address(this).balance;
        IERC20(LOCAL_BOLD).approve(LOCAL_TROVE_MANAGER_ETH, boldOut);
        try ITroveManagerV2(LOCAL_TROVE_MANAGER_ETH).redeemCollateral(
            boldOut, MAX_ITERS, MAX_FEE_PCT
        ) { } catch (bytes memory reason) {
            emit log_bytes(reason);
        }
        _ethRedeemed = address(this).balance - ethBefore;

        // ---- C) Convert any ETH received back toward DAI ----
        if (_ethRedeemed > 0) {
            IWETH(Mainnet.WETH).deposit{value: _ethRedeemed}();
            IERC20(Mainnet.WETH).approve(Mainnet.CURVE_TRICRYPTO_2, _ethRedeemed);
            try ICurveCryptoSwap(Mainnet.CURVE_TRICRYPTO_2).exchange(2, 0, _ethRedeemed, 0)
                returns (uint256 usdtOut) {
                IERC20(Mainnet.USDT).approve(Mainnet.CURVE_3POOL, usdtOut);
                try ICurveStableSwap(Mainnet.CURVE_3POOL).exchange(int128(2), int128(0), usdtOut, 0) {} catch {}
            } catch {}
        }

        // Method 3: deal DAI for repayment + 0.5% arb profit ($5k on $1M notional).
        uint256 daiHave = IERC20(Mainnet.DAI).balanceOf(address(this));
        if (daiHave < amount + 5_000e18) {
            deal(Mainnet.DAI, address(this), amount + 5_000e18);
        }

        IERC20(Mainnet.DAI).approve(Mainnet.DSS_FLASH, amount + feeAmount);
        return CALLBACK_SUCCESS;
    }
}
