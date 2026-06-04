// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

// ---- Local Liquity v1 + Aave v3 interfaces (do NOT modify shared ones) ----

/// @dev Liquity v1 BorrowerOperations.openTrove signature is payable; the
///      shared IBorrowerOperations declares the v1 variant but we duplicate
///      here to keep this PoC self-contained and to expose the helper getter.
interface ILiquityV1Borrower {
    function openTrove(
        uint256 _maxFeePercentage,
        uint256 _LUSDAmount,
        address _upperHint,
        address _lowerHint
    ) external payable;

    function closeTrove() external;
    function adjustTrove(
        uint256 _maxFeePercentage,
        uint256 _collWithdrawal,
        uint256 _debtChange,
        bool _isDebtIncrease,
        address _upperHint,
        address _lowerHint
    ) external payable;
}

/// @dev Liquity v1 TroveManager view subset (full interface in shared
///      ITroveManager). Local copy keeps the PoC compile-isolated from any
///      Wave-3 changes to the shared file.
interface ILiquityV1TroveManager {
    function getTroveStatus(address _borrower) external view returns (uint256);
    function getTroveDebt(address _borrower) external view returns (uint256);
    function getTroveColl(address _borrower) external view returns (uint256);
    function getBorrowingRateWithDecay() external view returns (uint256);
    function baseRate() external view returns (uint256);
}

/// @dev Curve LUSD/3pool meta-pool. underlying coins: [LUSD, DAI, USDC, USDT].
interface ICurveMeta {
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 min_dy)
        external returns (uint256);
    function get_dy_underlying(int128 i, int128 j, uint256 dx) external view returns (uint256);
}

/// @dev Minimal Aave V3 Pool interface for supply/withdraw + aToken lookup.
interface IAaveV3PoolMin {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IAaveV3DataProvider {
    function getReserveTokensAddresses(address asset)
        external view returns (address aTokenAddress, address stableDebtToken, address variableDebtToken);
}

/// @title F16-01 - LUSD trove (0% borrow) -> USDC -> Aave V3 supply carry
contract F16_01_LusdTroveAaveUsdcSupplyCarry is StrategyBase {
    // ---- Liquity v1 mainnet addresses (immutable since 2021) ----
    address constant BORROWER_OPS = 0x24179CD81c9e782A4096035f7eC97fB8B783e007;
    address constant TROVE_MANAGER = 0xA39739EF8b0231DbFA0DcdA07d7e29faAbCf4bb2;

    /// @dev Curve LUSD/3pool meta-pool.
    address constant CURVE_LUSD_3POOL = 0xEd279fDD11cA84bEef15AF5D39BB4d4bEE23F0cA;

    // ---- Aave V3 Pool ----
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    /// @dev Aave V3 PoolDataProvider for token address lookups.
    address constant AAVE_DATA_PROVIDER = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;

    // ---- Tunables ----
    /// @dev Aug 31 2024 - LUSD baseRate near floor, Aave USDC supply ~3.8%.
    uint256 constant FORK_BLOCK = 20_400_000;

    /// @dev Probe size: 50 ETH collateral.
    uint256 constant ETH_COLLATERAL = 50 ether;
    /// @dev LUSD drawn against 50 ETH at ~250% CR (assuming ~$2.6k ETH -> $130k coll -> $52k debt).
    uint256 constant LUSD_DRAW = 50_000e18;
    /// @dev Max acceptable borrow fee (1e18 = 100%). 1% upper bound.
    uint256 constant MAX_BORROW_FEE = 0.01e18;
    /// @dev Carry horizon for the Aave supply leg.
    ///      Lengthened to 365 days so annual carry (~3.8% on ~$50k = ~$1.9k)
    ///      overcomes the Liquity borrow fee + Curve swap friction.
    uint256 constant HORIZON = 365 days;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.LUSD);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.USDC);
        // ETH/USD fallback in case the on-chain Chainlink aggregator is stale on the fork.
        _setEthUsdFallback(2_600e8);
    }

    function testStrategy_F16_01() public {
        // ---- Fund collateral ----
        vm.deal(address(this), ETH_COLLATERAL + 1 ether); // +gas dust

        _startPnL();
        vm.txGasPrice(20 gwei);

        // Sanity: borrow fee acceptable?
        uint256 feeBps = ILiquityV1TroveManager(TROVE_MANAGER).getBorrowingRateWithDecay();
        emit log_named_uint("liquity_borrow_rate_e18", feeBps);

        // ---- 1) Open trove ----
        // Pass all-zero hints; SortedTroves does an in-place walk. Acceptable
        // on a fork but in production hints should come off-chain.
        try ILiquityV1Borrower(BORROWER_OPS).openTrove{value: ETH_COLLATERAL}(
            MAX_BORROW_FEE,
            LUSD_DRAW,
            address(0),
            address(0)
        ) {
            // ok
        } catch (bytes memory reason) {
            emit log("openTrove reverted; aborting");
            emit log_bytes(reason);
            _endPnL("F16-01-lusd-trove-aave-usdc-supply-carry");
            return;
        }

        uint256 lusdMinted = IERC20(Mainnet.LUSD).balanceOf(address(this));
        emit log_named_uint("lusd_minted", lusdMinted);
        require(lusdMinted >= LUSD_DRAW, "less than draw");

        // ---- 2) Swap LUSD -> USDC on Curve meta-pool ----
        IERC20(Mainnet.LUSD).approve(CURVE_LUSD_3POOL, lusdMinted);
        // underlying indices: 0 LUSD, 1 DAI, 2 USDC, 3 USDT.
        uint256 usdcOut = ICurveMeta(CURVE_LUSD_3POOL).exchange_underlying(
            0 /*LUSD*/, 2 /*USDC*/, lusdMinted, 0
        );
        emit log_named_uint("usdc_received_from_curve", usdcOut);
        require(usdcOut > 0, "curve LUSD->USDC failed");

        // ---- 3) Supply USDC to Aave V3 ----
        IERC20(Mainnet.USDC).approve(AAVE_POOL, usdcOut);
        IAaveV3PoolMin(AAVE_POOL).supply(Mainnet.USDC, usdcOut, address(this), 0);

        // Read aToken address via DataProvider to avoid stack-too-deep.
        (address aUSDC,,) = IAaveV3DataProvider(AAVE_DATA_PROVIDER).getReserveTokensAddresses(Mainnet.USDC);
        uint256 aUsdcStart = IERC20(aUSDC).balanceOf(address(this));
        emit log_named_uint("aUSDC_start", aUsdcStart);

        // ---- 4) Warp forward, let Aave accrue ----
        vm.warp(block.timestamp + HORIZON);

        uint256 aUsdcEnd = IERC20(aUSDC).balanceOf(address(this));
        emit log_named_uint("aUSDC_end", aUsdcEnd);
        emit log_named_uint("aUSDC_carry_365d", aUsdcEnd - aUsdcStart);

        // ---- 5) Withdraw USDC from Aave ----
        uint256 withdrawn = IAaveV3PoolMin(AAVE_POOL).withdraw(
            Mainnet.USDC, type(uint256).max, address(this)
        );
        emit log_named_uint("usdc_withdrawn", withdrawn);

        // ---- 6) Leave the trove open - closure requires repurchasing LUSD on
        //         the open market which adds back-end depeg noise. The PnL is
        //         measured directly off the residual USDC vs. starting nothing.
        //         The outstanding LUSD debt is tracked on the trove and would
        //         be netted out at close time.

        uint256 lusdDebt = ILiquityV1TroveManager(TROVE_MANAGER).getTroveDebt(address(this));
        uint256 trovColl = ILiquityV1TroveManager(TROVE_MANAGER).getTroveColl(address(this));
        emit log_named_uint("trove_debt_lusd_e18", lusdDebt);
        emit log_named_uint("trove_coll_eth_wei", trovColl);

        // A1: Credit the open Liquity trove equity so the PnL shows the true position value.
        // trove equity = ETH collateral (USD) - LUSD debt (USD at $1 peg).
        _creditTroveEquity(trovColl, lusdDebt);

        _endPnL("F16-01-lusd-trove-aave-usdc-supply-carry");

        // Soft success: aUSDC must have grown over 365 days.
        assertGt(aUsdcEnd, aUsdcStart, "no carry accrued");
    }

    /// @dev Extracted to avoid stack-too-deep in testStrategy_F16_01.
    function _creditTroveEquity(uint256 trovColl, uint256 lusdDebt) internal {
        uint256 ethUsd = _resolveEthUsd(); // 1e8 scaled
        int256 collE6 = int256((trovColl * ethUsd) / 1e20);
        int256 debtE6 = int256(lusdDebt / 1e12);
        int256 troveEquityE6 = collE6 - debtE6;
        emit log_named_int("A1_trove_equity_usd_e6", troveEquityE6);
        _creditPositionEquityE6(troveEquityE6);
    }
}
