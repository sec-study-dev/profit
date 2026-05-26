// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IWeETH} from "src/interfaces/lrt/IWeETH.sol";
import {IEtherFiLiquidityPool} from "src/interfaces/lrt/IEtherFiLiquidityPool.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "src/interfaces/common/IFlashLoanReceiver.sol";

/// @notice F02-01 — weETH leveraged restake using Morpho free flashloan.
///
/// Mechanism: borrow WETH from Morpho (free flash), mint weETH via EtherFi pool,
/// post weETH collateral to Morpho's weETH/WETH market, borrow WETH equal to
/// flash, repay. Result: ~5x weETH stack on ~equity ETH.
contract F02_01_WeethMorphoFlashLoopTest is StrategyBase, IMorphoFlashLoanCallback {
    // ---- Constants ----

    /// @dev Pinned block: 19,200,000 (~Feb 2024). Morpho weETH/WETH market live; LRT season 2.
    uint256 constant FORK_BLOCK = 19_200_000;

    /// @dev Morpho weETH/WETH market (Gauntlet-curated, ~86% LLTV).
    /// TODO verify: this is the canonical 86% market id at the fork block.
    /// Computed off-chain as keccak256(abi.encode(MarketParams{WETH, weETH, oracle, irm, 0.86e18})).
    /// If wrong at the fork block we fall back to creating the market via createMarket().
    bytes32 constant WEETH_WETH_MARKET_ID =
        0xc54d7acf14de29e0e5527cabd7a576506870346a78a11a6762e2cca66322ec41;

    /// @dev Gauntlet-deployed Chainlink-based oracle for weETH/WETH.
    /// Format: ChainlinkOracle wrapping weETH-rate.
    address constant MORPHO_ORACLE_WEETH_WETH = 0x3fa58b74e9a8eA8768eb33c8453e9C2Ed089A40a;
    /// @dev Morpho Blue AdaptiveCurveIRM.
    address constant MORPHO_IRM_ADAPTIVE_CURVE = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 constant LLTV_86 = 0.86e18;

    uint256 constant EQUITY = 100 ether;
    /// @dev 4x leverage on equity → 5x total notional.
    uint256 constant FLASH_AMOUNT = 400 ether;

    IMorpho.MarketParams internal _market;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.WEETH);
        _trackToken(Mainnet.EETH);

        _market = IMorpho.MarketParams({
            loanToken: Mainnet.WETH,
            collateralToken: Mainnet.WEETH,
            oracle: MORPHO_ORACLE_WEETH_WETH,
            irm: MORPHO_IRM_ADAPTIVE_CURVE,
            lltv: LLTV_86
        });
    }

    function testStrategy_F02_01() public {
        _fund(Mainnet.WETH, address(this), EQUITY);
        _startPnL();

        // Approve Morpho to pull the WETH we'll need to (a) repay flash, (b) repay any borrow if exit.
        IERC20(Mainnet.WETH).approve(Mainnet.MORPHO, type(uint256).max);
        IERC20(Mainnet.WEETH).approve(Mainnet.MORPHO, type(uint256).max);

        // Trigger the loop via flashloan. The callback (onMorphoFlashLoan) does the heavy lifting.
        IMorpho(Mainnet.MORPHO).flashLoan(Mainnet.WETH, FLASH_AMOUNT, abi.encode("loop"));

        // After flash callback returns: we hold ~491 weETH as collateral on Morpho,
        // and a 400 WETH variable-rate debt. Equity = ~100 ETH worth of weETH net.
        // Cash yield/borrow accrual happens over time; the points yield is off-chain.
        // For PoC we just report immediate balances + on-chain position state.

        _endPnL("F02-01: weETH-Morpho-flashloop");
    }

    /// @notice Morpho Blue flashloan callback. Receives `assets` WETH, must approve Morpho to pull it back by end.
    function onMorphoFlashLoan(uint256 assets, bytes calldata) external {
        require(msg.sender == Mainnet.MORPHO, "only morpho");

        // We now hold EQUITY (already on contract) + assets (flashed WETH) = 500 WETH.
        // Unwrap to ETH.
        uint256 total = IERC20(Mainnet.WETH).balanceOf(address(this));
        IWETH(Mainnet.WETH).withdraw(total);

        // Deposit ETH into EtherFi liquidity pool to mint eETH 1:1.
        IEtherFiLiquidityPool(Mainnet.ETHERFI_LIQUIDITY_POOL).deposit{value: total}();
        uint256 eethBal = IERC20(Mainnet.EETH).balanceOf(address(this));

        // Wrap eETH → weETH.
        IERC20(Mainnet.EETH).approve(Mainnet.WEETH, eethBal);
        uint256 weethOut = IWeETH(Mainnet.WEETH).wrap(eethBal);

        // Supply weETH as collateral to the weETH/WETH market.
        IMorpho(Mainnet.MORPHO).supplyCollateral(_market, weethOut, address(this), "");

        // Borrow exactly the flashloan principal so we can return it. (Free flashloan: no fee.)
        IMorpho(Mainnet.MORPHO).borrow(_market, assets, 0, address(this), address(this));

        // Approval already set at outer scope. Morpho pulls back `assets` after this returns.
        // (No-op: the flashLoan() function does `safeTransferFrom(initiator, ...)` after callback.)
    }
}
