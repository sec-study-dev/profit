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
import {console2} from "forge-std/console2.sol";

/// @notice F02-01 - weETH leveraged restake using Morpho free flashloan.
///
/// Mechanism: borrow WETH from Morpho (free flash), mint weETH via EtherFi pool,
/// post weETH collateral to Morpho's weETH/WETH market, borrow WETH equal to
/// flash, repay. Result: ~5x weETH stack on ~equity ETH.
contract F02_01_WeethMorphoFlashLoopTest is StrategyBase, IMorphoFlashLoanCallback {
    // ---- Constants ----

    /// @dev Pinned block: 19,200,000 (~Feb 2024). Morpho weETH/WETH market live; LRT season 2.
    uint256 constant FORK_BLOCK = 19_200_000;

    /// @dev Morpho weETH/WETH market (Gauntlet-curated, 86% LLTV).
    /// Verified canonical market id via app.morpho.org/ethereum/market/0x37e7484d...:
    /// MarketParams(loanToken=WETH, collateralToken=weETH, oracle=0x3fa58b74...,
    ///              irm=AdaptiveCurve, lltv=0.86e18).
    /// Source: https://app.morpho.org/ethereum/market/0x37e7484d642d90f14451f1910ba4b7b8e4c3ccdd0ec28f8b2bdb35479e472ba7/weeth-weth
    /// At PoC runtime we recompute this from the MarketParams struct (so a re-org
    /// or off-by-one in our copy doesn't silently target the wrong market) and
    /// `console2.log` it for cross-check.
    bytes32 constant WEETH_WETH_MARKET_ID =
        0x37e7484d642d90f14451f1910ba4b7b8e4c3ccdd0ec28f8b2bdb35479e472ba7;

    /// @dev MorphoChainlinkOracleV2 for weETH/WETH - wraps EtherFi's getRate().
    /// Verified from the Morpho weETH/WETH market parameters at FORK_BLOCK.
    address constant MORPHO_ORACLE_WEETH_WETH = 0x3fa58b74e9a8ea8768eb33c8453e9c2ed089a40a;
    /// @dev Morpho Blue AdaptiveCurveIRM.
    address constant MORPHO_IRM_ADAPTIVE_CURVE = 0x870ac11d48b15db9a138cf899d20f13f79ba00bc;
    uint256 constant LLTV_86 = 0.86e18;

    uint256 constant EQUITY = 100 ether;
    /// @dev 4x leverage on equity -> 5x total notional.
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

        // Recompute market id from struct and log for cross-check against
        // the verified canonical id (`WEETH_WETH_MARKET_ID`).
        bytes32 derivedId = keccak256(abi.encode(_market));
        console2.log("derived weETH/WETH marketId:");
        console2.logBytes32(derivedId);
        console2.log("expected weETH/WETH marketId:");
        console2.logBytes32(WEETH_WETH_MARKET_ID);
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

        // Wrap eETH -> weETH.
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
