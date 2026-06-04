// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IERC4626} from "src/interfaces/common/IERC4626.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "src/interfaces/common/IFlashLoanReceiver.sol";
import {console2} from "forge-std/console2.sol";

/// @notice F09-02 - sUSDe/DAI 91.5% LLTV loop bootstrapped by Morpho's zero-fee flashLoan.
///
/// Single-tx mechanism:
///   1. flashLoan DAI from Morpho (0% fee)
///   2. PoC: deal() equivalent sUSDe (production: swap DAI -> USDe -> deposit to sUSDe)
///   3. supplyCollateral sUSDe, borrow DAI = flash amount
///   4. flashloan auto-repays via outer-scope approval
contract F09_02_SusdeDaiMorphoFlashloopTest is StrategyBase, IMorphoFlashLoanCallback {
    // ---- Constants ----

    uint256 constant FORK_BLOCK = 21_400_000;

    /// @dev sUSDe/DAI 91.5% LLTV market id (the canonical Morpho sUSDe leverage market).
    bytes32 constant SUSDE_DAI_MARKET_ID =
        0x1247f1c237eceae0602eab1470a5061a6dd8f734ba88c7cdc5d6109fb0026b28;

    uint256 constant EQUITY = 400_000e18; // 400k DAI
    /// @dev 9x leverage -> 10x notional.
    uint256 constant FLASH_AMOUNT = 3_600_000e18; // 3.6M DAI

    IMorpho.MarketParams internal _market;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.SUSDE);

        // Recover market params from on-chain registry (more robust than
        // hard-coding oracle/IRM/LLTV that might drift across deployments).
        _market = IMorpho(Mainnet.MORPHO).idToMarketParams(SUSDE_DAI_MARKET_ID);

        require(_market.loanToken == Mainnet.DAI, "F09-02: market loanToken not DAI");
        require(_market.collateralToken == Mainnet.SUSDE, "F09-02: market collateral not sUSDe");
        require(_market.lltv == 0.915e18, "F09-02: market LLTV not 91.5%");
    }

    function testStrategy_F09_02() public {
        _fund(Mainnet.DAI, address(this), EQUITY);
        _startPnL();

        IERC20(Mainnet.DAI).approve(Mainnet.MORPHO, type(uint256).max);
        IERC20(Mainnet.SUSDE).approve(Mainnet.MORPHO, type(uint256).max);

        IMorpho(Mainnet.MORPHO).flashLoan(Mainnet.DAI, FLASH_AMOUNT, abi.encode("loop"));

        // Log Morpho-side position: balance tracking alone is misleading because the
        // DAI debt is not an ERC20 the StrategyBase tracker can see.
        IMorpho.Position memory pos = IMorpho(Mainnet.MORPHO).position(SUSDE_DAI_MARKET_ID, address(this));
        console2.log("Morpho position.collateral (sUSDe shares) =", pos.collateral);
        console2.log("Morpho position.borrowShares             =", pos.borrowShares);

        // Warp 30 days to capture sUSDe yield accrual and DAI borrow interest.
        // sUSDe APY ~12% (at block 21.4M) vs DAI borrow ~8%; net carry positive.
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));

        // A1: Credit the open Morpho sUSDe/DAI position equity.
        // Collateral = sUSDe shares → value = convertToAssets(shares) * sUSDe_price_usd.
        // sUSDe price ≈ $1 per USDe backing (tracked as $1 in PriceOracle), so
        // collateral_USD_e6 ≈ convertToAssets(shares) / 1e12.
        // DAI debt: borrowShares * totalBorrowAssets / totalBorrowShares (in DAI, 1e18).
        {
            IMorpho.Market memory mkt = IMorpho(Mainnet.MORPHO).market(SUSDE_DAI_MARKET_ID);
            // Compute DAI debt from borrowShares.
            uint256 daiDebt = mkt.totalBorrowShares > 0
                ? (uint256(pos.borrowShares) * uint256(mkt.totalBorrowAssets)) / uint256(mkt.totalBorrowShares)
                : 0;
            // sUSDe collateral: convert shares to underlying USDe (1e18 USDe units).
            uint256 collUsde = IERC4626(Mainnet.SUSDE).convertToAssets(pos.collateral);
            // USDe ≈ $1. Collateral in 1e6 USD = collUsde / 1e12.
            int256 collE6 = int256(collUsde / 1e12);
            // DAI ≈ $1. Debt in 1e6 USD = daiDebt / 1e12.
            int256 debtE6 = int256(daiDebt / 1e12);
            int256 equityE6 = collE6 - debtE6;
            console2.log("A1_susde_coll_e6:", uint256(collE6));
            console2.log("A1_dai_debt_e6:", uint256(debtE6));
            console2.log("A1_equity_e6:", equityE6);
            _creditPositionEquityE6(equityE6);
        }

        _endPnL("F09-02: sUSDe-DAI-Morpho-flashloop");
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata) external {
        require(msg.sender == Mainnet.MORPHO, "only morpho");

        // We hold (EQUITY + assets) DAI = 4_000_000 DAI on contract. Production path:
        // swap **all** DAI -> USDe via Curve plain pool, then sUSDe.deposit(usde). To
        // keep the PoC deterministic against fork-block Curve liquidity, we simulate
        // that swap by (a) zeroing the DAI balance and (b) dealing the equivalent
        // sUSDe quantity. We read the **live** sUSDe share price via the ERC-4626
        // `convertToShares` view rather than hard-coding a ratio so the test stays
        // correct across fork blocks. Assumes USDe/DAI ~= 1.00 (sub-bps drift at
        // block 21.4M); production code would price-check the Curve USDe/DAI plain
        // pool first.
        uint256 daiBalIn = IERC20(Mainnet.DAI).balanceOf(address(this));
        uint256 sUsdeShares = IERC4626(Mainnet.SUSDE).convertToShares(daiBalIn);

        // Simulate swap: zero the DAI, credit sUSDe shares.
        deal(Mainnet.DAI, address(this), 0);
        deal(Mainnet.SUSDE, address(this), sUsdeShares);

        IMorpho(Mainnet.MORPHO).supplyCollateral(_market, sUsdeShares, address(this), "");

        // Borrow exactly the flash principal in DAI so we can repay. After borrow,
        // contract has `assets` DAI on hand; Morpho's post-callback safeTransferFrom
        // pulls those `assets` back.
        IMorpho(Mainnet.MORPHO).borrow(_market, assets, 0, address(this), address(this));

        // Outer-scope approval allows Morpho's safeTransferFrom to pull DAI back.
    }
}
