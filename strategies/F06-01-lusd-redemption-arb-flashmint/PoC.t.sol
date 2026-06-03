// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {ICurveStableSwap, ICurveCryptoSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IDssFlash} from "src/interfaces/cdp/IDssFlash.sol";
import {IERC3156FlashBorrower} from "src/interfaces/common/IFlashLoanReceiver.sol";

// ---- Local Liquity v1 interfaces (do NOT modify the shared ITroveManager) ----

/// @dev Liquity v1 TroveManager.redeemCollateral has a richer signature than
///      the shared v1/v2 union interface; declare locally.
interface ITroveManagerV1 {
    function redeemCollateral(
        uint256 _LUSDamount,
        address _firstRedemptionHint,
        address _upperPartialRedemptionHint,
        address _lowerPartialRedemptionHint,
        uint256 _partialRedemptionHintNICR,
        uint256 _maxIterations,
        uint256 _maxFeePercentage
    ) external;

    function getRedemptionRateWithDecay() external view returns (uint256);
    function baseRate() external view returns (uint256);
    function getEntireSystemDebt() external view returns (uint256);
    function getEntireSystemColl() external view returns (uint256);
    function getTroveOwnersCount() external view returns (uint256);
}

/// @dev Liquity v1 HintHelpers (off-chain hint computation). Hints are advisory
///      - passing all-zero hints simply forces the on-chain code to walk the
///      sorted list with `_maxIterations` cap, which on a fork is acceptable.
interface IHintHelpers {
    function getRedemptionHints(
        uint256 _LUSDamount,
        uint256 _price,
        uint256 _maxIterations
    )
        external
        view
        returns (
            address firstRedemptionHint,
            uint256 partialRedemptionHintNICR,
            uint256 truncatedLUSDamount
        );
}

interface IPriceFeed {
    function fetchPrice() external returns (uint256);
    function lastGoodPrice() external view returns (uint256);
}

/// @notice Curve LUSD/3pool meta-pool. Coins: [LUSD, 3CRV].
///         underlying_coins: [LUSD, DAI, USDC, USDT].
interface ICurveMeta {
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 min_dy)
        external
        returns (uint256);
    function get_dy_underlying(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function coins(uint256 i) external view returns (address);
}

/// @title F06-01 - LUSD redemption arbitrage using Maker DSS flashmint
/// @notice When LUSD trades below $1 on Curve, flashmint DAI, buy cheap LUSD,
///         redeem 1:1 against the Liquity v1 TroveManager for ETH, swap ETH
///         back to DAI, repay flashmint. Profit = (1/p_curve - (1-R)) * notional
///         net of swap fees.
contract F06_01_LusdRedemptionArbFlashmintTest is StrategyBase, IERC3156FlashBorrower {
    // ---- Liquity v1 mainnet addresses (immutable since 2021) ----

    /// @dev Liquity TroveManager.
    address constant TROVE_MANAGER = 0xA39739EF8b0231DbFA0DcdA07d7e29faAbCf4bb2;
    /// @dev Liquity HintHelpers (view-only redemption hint computer).
    address constant HINT_HELPERS = 0xE84251b93D9524E0d2e621Ba7dc7cb3579F997C0;
    /// @dev Liquity PriceFeed (Chainlink/Tellor medianiser).
    address constant LIQUITY_PRICE_FEED = 0x4c517D4e2C851CA76d7eC94B805269Df0f2201De;

    /// @dev Curve LUSD/3pool (meta-pool).
    address constant CURVE_LUSD_3POOL = 0xEd279fDD11cA84bEef15AF5D39BB4d4bEE23F0cA;

    // ---- Tunables ----

    /// @dev Pinned block - LUSD ~99 cents on Curve, baseRate near floor.
    ///      14_400_000 (~mid-Mar 2022) predates DssFlash deployment at
    ///      0x60744434... which went live around block 14_700_000.
    ///      15_000_000 (~mid-Apr 2022) has DssFlash live + LUSD mildly off-peg.
    uint256 constant FORK_BLOCK = 15_000_000;

    /// @dev DAI flashmint size - keep modest so Curve sandwich isn't required.
    uint256 constant FLASH_DAI = 5_000_000e18;

    /// @dev Max acceptable Liquity redemption fee percentage (1e18 = 100%).
    ///      5% is the protocol cap; we accept up to 2% in this PoC.
    uint256 constant MAX_FEE_PCT = 0.02e18;

    /// @dev Max iterations through SortedTroves before partial. 0 = unbounded.
    uint256 constant MAX_ITERS = 0;

    /// @dev Magic value an ERC-3156 receiver must return.
    bytes32 constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    // ---- State ----

    /// @dev Set in onFlashLoan so testStrategy can assert post-condition.
    uint256 internal _ethRedeemed;
    uint256 internal _daiBack;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.LUSD);
        _trackToken(Mainnet.USDT);
        _trackToken(Mainnet.WETH);
    }

    function testStrategy_F06_01() public {
        _startPnL();

        // Sanity: confirm DSS Flash is open and zero-fee at this block.
        uint256 fee = IDssFlash(Mainnet.DSS_FLASH).flashFee(Mainnet.DAI, FLASH_DAI);
        require(fee == 0, "DSS toll bumped - re-evaluate");
        require(IDssFlash(Mainnet.DSS_FLASH).maxFlashLoan(Mainnet.DAI) >= FLASH_DAI, "flash cap");

        // Snapshot Liquity redemption rate for the PnL preview.
        uint256 rRate = ITroveManagerV1(TROVE_MANAGER).getRedemptionRateWithDecay();
        emit log_named_uint("liquity_redemption_rate_e18", rRate);

        // Snapshot Curve price (LUSD per DAI on the cheap side).
        uint256 quote = ICurveMeta(CURVE_LUSD_3POOL).get_dy_underlying(
            1 /*DAI*/, 0 /*LUSD*/, 1e18
        );
        emit log_named_uint("curve_lusd_per_dai_e18", quote);

        // Trigger the arb via flashmint. All action happens in onFlashLoan.
        IDssFlash(Mainnet.DSS_FLASH).flashLoan(
            address(this),
            Mainnet.DAI,
            FLASH_DAI,
            ""
        );

        emit log_named_uint("eth_redeemed_wei", _ethRedeemed);
        emit log_named_uint("dai_back_wei", _daiBack);

        // After repay, residual DAI on this contract is the realised profit.
        uint256 residualDai = IERC20(Mainnet.DAI).balanceOf(address(this));
        emit log_named_uint("residual_dai_profit", residualDai);

        _endPnL("F06-01: LUSD redemption arb flashmint");
    }

    // ---- ERC-3156 callback (DSS Flash) ----

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

        // ---- 1) Swap DAI -> LUSD on Curve LUSD/3pool (cheap leg) ----
        IERC20(Mainnet.DAI).approve(CURVE_LUSD_3POOL, amount);
        // underlying index: 0 LUSD, 1 DAI, 2 USDC, 3 USDT
        uint256 lusdOut = ICurveMeta(CURVE_LUSD_3POOL).exchange_underlying(
            1, 0, amount, 0 /* PoC: no min - production must set */
        );
        require(lusdOut > 0, "curve buy");

        // ---- 2) Redeem LUSD -> ETH at Liquity TroveManager ----
        IERC20(Mainnet.LUSD).approve(TROVE_MANAGER, lusdOut);
        uint256 ethBefore = address(this).balance;

        // Use all-zero hints; on-chain code will walk SortedTroves up to
        // MAX_ITERS (0 = no cap). Production: compute via HintHelpers off-chain.
        try ITroveManagerV1(TROVE_MANAGER).redeemCollateral(
            lusdOut,
            address(0), // firstRedemptionHint
            address(0), // upperPartialHint
            address(0), // lowerPartialHint
            0,          // partialRedemptionHintNICR
            MAX_ITERS,
            MAX_FEE_PCT
        ) {
            // ok
        } catch (bytes memory reason) {
            // If redemption is blocked (e.g. <14d post-deploy block, recovery mode,
            // baseRate too high), short-circuit and just repay the flash.
            emit log_bytes(reason);
        }

        _ethRedeemed = address(this).balance - ethBefore;

        if (_ethRedeemed > 0) {
            // ---- 3) Wrap ETH -> WETH so we can route through Curve tricrypto2 ----
            IWETH(Mainnet.WETH).deposit{value: _ethRedeemed}();

            // ---- 4) Curve tricrypto2 WETH -> USDT (indices: 0=USDT,1=WBTC,2=WETH) ----
            IERC20(Mainnet.WETH).approve(Mainnet.CURVE_TRICRYPTO_2, _ethRedeemed);
            uint256 usdtOut = ICurveCryptoSwap(Mainnet.CURVE_TRICRYPTO_2).exchange(
                2, 0, _ethRedeemed, 0
            );

            // ---- 5) Curve 3pool USDT -> DAI (indices: 0=DAI,1=USDC,2=USDT) ----
            IERC20(Mainnet.USDT).approve(Mainnet.CURVE_3POOL, usdtOut);
            ICurveStableSwap(Mainnet.CURVE_3POOL).exchange(
                int128(2), int128(0), usdtOut, 0
            );
        }

        // ---- 6) Repay flashmint ----
        _daiBack = IERC20(Mainnet.DAI).balanceOf(address(this));
        // Approve DSS Flash to pull `amount + fee` (fee = 0 here).
        IERC20(Mainnet.DAI).approve(Mainnet.DSS_FLASH, amount + feeAmount);
        return CALLBACK_SUCCESS;
    }
}
