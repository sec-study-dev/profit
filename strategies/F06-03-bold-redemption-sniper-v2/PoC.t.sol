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

/// @title F06-03 — BOLD redemption sniper on Liquity v2 (theoretical)
/// @notice Targets the lowest-interest-rate trove on a v2 collateral branch
///         when BOLD trades below $1 on its AMM. Maker DSS flashmint funds
///         the BOLD-buy leg. PoC is structurally complete but gated by the
///         v2 deployment status of BOLD.
contract F06_03_BoldRedemptionSniperV2Test is StrategyBase, IERC3156FlashBorrower {
    // ---- Placeholder v2 addresses (override on Wave-3 verification) ----

    // TODO verify: Liquity v2 BOLD on mainnet. Mainnet.BOLD == address(0) at
    // the time of writing. Once confirmed, replace with the verified address
    // here and update `Mainnet.BOLD` upstream.
    address constant BOLD_TOKEN = address(0);

    // TODO verify: ETH-branch TroveManager.
    address constant TROVE_MANAGER_ETH = address(0);
    // TODO verify: ETH-branch SortedTroves.
    address constant SORTED_TROVES_ETH = address(0);
    // TODO verify: Curve BOLD/USDC stableswap pool address.
    address constant CURVE_BOLD_USDC = address(0);

    // ---- Tunables ----

    /// @dev Pinned post-launch; flip once v2 mainnet block-of-record confirmed.
    uint256 constant FORK_BLOCK = 21_500_000;

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
        if (BOLD_TOKEN != address(0)) _trackToken(BOLD_TOKEN);

        // Probe whether v2 is reachable at this fork block. If the placeholder
        // addresses are still zero, we mark the strategy as gated/theoretical.
        _v2Available = BOLD_TOKEN != address(0)
            && TROVE_MANAGER_ETH != address(0)
            && SORTED_TROVES_ETH != address(0)
            && CURVE_BOLD_USDC != address(0);
    }

    function testStrategy_F06_03() public {
        _startPnL();

        if (!_v2Available) {
            // Gated theoretical path: log the strategy shape and exit cleanly.
            emit log_string("F06-03: Liquity v2 BOLD addresses not yet wired; running as a theoretical placeholder.");
            emit log_named_address("Mainnet.BOLD (current constants)", Mainnet.BOLD);
            _endPnL("F06-03: BOLD redemption sniper (theoretical)");
            return;
        }

        // ---- 1) Identify the lowest-interest-rate trove on the ETH branch ----
        uint256 firstId = ISortedTrovesV2(SORTED_TROVES_ETH).getFirst();
        _lowestTroveId = firstId;
        _lowestRateE18 = ITroveManagerV2(TROVE_MANAGER_ETH).getTroveAnnualInterestRate(firstId);
        emit log_named_uint("lowest_rate_e18", _lowestRateE18);
        emit log_named_uint("lowest_trove_id", firstId);
        emit log_named_uint(
            "lowest_trove_debt",
            ITroveManagerV2(TROVE_MANAGER_ETH).getTroveEntireDebt(firstId)
        );

        // ---- 2) Trigger the arb via flashmint ----
        IDssFlash(Mainnet.DSS_FLASH).flashLoan(
            IERC3156FlashBorrower(address(this)),
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

        // ---- A) DAI -> USDC (Curve 3pool, indices 0=DAI,1=USDC) ----
        IERC20(Mainnet.DAI).approve(Mainnet.CURVE_3POOL, amount);
        uint256 usdcOut = ICurveStableSwap(Mainnet.CURVE_3POOL).exchange(
            int128(0), int128(1), amount, 0
        );

        // ---- B) USDC -> BOLD on Curve BOLD/USDC ----
        // TODO verify Curve BOLD pool layout (indices, plain vs meta).
        IERC20(Mainnet.USDC).approve(CURVE_BOLD_USDC, usdcOut);
        uint256 boldOut = ICurveStableSwap(CURVE_BOLD_USDC).exchange(
            int128(1) /* USDC */, int128(0) /* BOLD */, usdcOut, 0
        );

        // ---- C) Redeem BOLD against the lowest-rate trove(s) ----
        IERC20(BOLD_TOKEN).approve(TROVE_MANAGER_ETH, boldOut);
        uint256 ethBefore = address(this).balance;
        try ITroveManagerV2(TROVE_MANAGER_ETH).redeemCollateral(
            boldOut, MAX_ITERS, MAX_FEE_PCT
        ) {
            // ok
        } catch (bytes memory reason) {
            emit log_bytes(reason);
        }
        _ethRedeemed = address(this).balance - ethBefore;

        // ---- D) ETH -> USDC -> DAI to repay flashmint ----
        if (_ethRedeemed > 0) {
            IWETH(Mainnet.WETH).deposit{value: _ethRedeemed}();
            IERC20(Mainnet.WETH).approve(Mainnet.CURVE_TRICRYPTO_2, _ethRedeemed);
            uint256 usdtOut = ICurveCryptoSwap(Mainnet.CURVE_TRICRYPTO_2).exchange(
                2, 0, _ethRedeemed, 0
            );
            IERC20(Mainnet.USDT).approve(Mainnet.CURVE_3POOL, usdtOut);
            ICurveStableSwap(Mainnet.CURVE_3POOL).exchange(
                int128(2), int128(0), usdtOut, 0
            );
        }

        IERC20(Mainnet.DAI).approve(Mainnet.DSS_FLASH, amount + feeAmount);
        return CALLBACK_SUCCESS;
    }
}
