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

    /// @dev Pinned block: 20,200,000 (~Jul 2024). Morpho weETH/WETH has >1700 WETH available
    /// at 75% util AND Curve weETH/WETH pool has >1400 WETH for close-side swap.
    uint256 constant FORK_BLOCK = 20_200_000;

    /// @dev Morpho weETH/WETH market (Gauntlet-curated, 86% LLTV).
    /// Verified canonical market id from morpho_markets.tsv:
    /// MarketParams(loanToken=WETH, collateralToken=weETH, oracle=0x3fa58b74...,
    ///              irm=AdaptiveCurve, lltv=0.86e18).
    /// Computed: keccak256(abi.encode(WETH, weETH, oracle, irm, lltv))
    ///         = 0x698fe98247a40c5771537b5786b2f3f9d78eb487b4ce4d75533cd0e94d88a115
    bytes32 constant WEETH_WETH_MARKET_ID =
        0x698fe98247a40c5771537b5786b2f3f9d78eb487b4ce4d75533cd0e94d88a115;

    /// @dev MorphoChainlinkOracleV2 for weETH/WETH - wraps EtherFi's getRate().
    /// Verified from the Morpho weETH/WETH market parameters at FORK_BLOCK.
    address constant MORPHO_ORACLE_WEETH_WETH = 0x3fa58b74e9a8eA8768eb33c8453e9C2Ed089A40a;
    /// @dev Morpho Blue AdaptiveCurveIRM.
    address constant MORPHO_IRM_ADAPTIVE_CURVE = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 constant LLTV_86 = 0.86e18;

    /// @dev Curve weETH/WETH 2-coin pool (coin0=WETH, coin1=weETH).
    /// Verified at block 19800000: coins(0)=WETH, coins(1)=weETH.
    address constant CURVE_WEETH_WETH_POOL = 0xDB74dfDD3BB46bE8Ce6C33dC9D82777BCFc3dEd5;

    uint256 constant EQUITY = 100 ether;
    /// @dev 3x leverage on equity -> 4x total notional. Reduced to limit Curve slippage on close.
    uint256 constant FLASH_AMOUNT = 300 ether;

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
        // Pass mode as bytes32 directly (not ABI-encoded string) for clean decoding.
        IMorpho(Mainnet.MORPHO).flashLoan(Mainnet.WETH, FLASH_AMOUNT, abi.encode(bytes32("loop")));

        // After flash callback: ~491 weETH collateral, ~400 WETH debt.

        // ---- Simulate 180 days of yield accrual ----
        vm.warp(block.timestamp + 180 days);
        vm.roll(block.number + (180 days / 12));
        IMorpho(Mainnet.MORPHO).accrueInterest(_market);

        // ---- Unwind: flash-repay the debt, withdraw collateral, convert to WETH ----
        bytes32 mktId = keccak256(abi.encode(_market));
        IMorpho.Position memory pos = IMorpho(Mainnet.MORPHO).position(mktId, address(this));
        IMorpho.Market memory mkt = IMorpho(Mainnet.MORPHO).market(mktId);
        uint256 debtWeth = mkt.totalBorrowShares > 0
            ? (uint256(pos.borrowShares) * uint256(mkt.totalBorrowAssets)) / uint256(mkt.totalBorrowShares)
            : 0;
        if (debtWeth > 0) {
            uint256 repayFlash = debtWeth + 1;
            IERC20(Mainnet.WETH).approve(Mainnet.MORPHO, type(uint256).max);
            IMorpho(Mainnet.MORPHO).flashLoan(Mainnet.WETH, repayFlash, abi.encode(bytes32("close")));
        }

        _endPnL("F02-01: weETH-Morpho-flashloop");
    }

    /// @notice Morpho Blue flashloan callback (handles open "loop" and close modes).
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        require(msg.sender == Mainnet.MORPHO, "only morpho");
        IERC20(Mainnet.WETH).approve(Mainnet.MORPHO, type(uint256).max);
        IERC20(Mainnet.WEETH).approve(Mainnet.MORPHO, type(uint256).max);

        bytes32 mode = abi.decode(data, (bytes32));

        if (mode == bytes32("close")) {
            // ---- Close mode: repay debt → withdraw collateral → swap weETH→WETH on Curve ----
            bytes32 mktId = keccak256(abi.encode(_market));
            IMorpho.Position memory pos = IMorpho(Mainnet.MORPHO).position(mktId, address(this));
            // Repay all borrow shares using the flashed WETH.
            IMorpho(Mainnet.MORPHO).repay(_market, 0, pos.borrowShares, address(this), "");
            // Withdraw all collateral (weETH).
            uint256 collat = IMorpho(Mainnet.MORPHO).position(mktId, address(this)).collateral;
            IMorpho(Mainnet.MORPHO).withdrawCollateral(_market, collat, address(this), address(this));
            // Convert weETH → WETH via Curve weETH/WETH pool (coin0=WETH, coin1=weETH).
            // Pool: 0xDB74dfDD3BB46bE8Ce6C33dC9D82777BCFc3dEd5 (verified at block 19800000).
            uint256 weethBal = IERC20(Mainnet.WEETH).balanceOf(address(this));
            IERC20(Mainnet.WEETH).approve(CURVE_WEETH_WETH_POOL, weethBal);
            // exchange(i=1[weETH], j=0[WETH], dx=weethBal, min_dy=0)
            (bool ok,) = CURVE_WEETH_WETH_POOL.call(
                abi.encodeWithSignature("exchange(int128,int128,uint256,uint256)", int128(1), int128(0), weethBal, 0)
            );
            if (!ok) {
                // Fallback: if pool exchange fails, just hold weETH (tracked).
                // Flash repayment will fail if insufficient WETH - but weETH is tracked.
            }
            // Morpho pulls back `assets` WETH from our allowance after this returns.
        } else {
            // ---- Open mode: WETH -> eETH -> weETH -> supply collateral -> borrow to repay flash ----
            uint256 total = IERC20(Mainnet.WETH).balanceOf(address(this));
            IWETH(Mainnet.WETH).withdraw(total);

            IEtherFiLiquidityPool(Mainnet.ETHERFI_LIQUIDITY_POOL).deposit{value: total}();
            uint256 eethBal = IERC20(Mainnet.EETH).balanceOf(address(this));

            IERC20(Mainnet.EETH).approve(Mainnet.WEETH, eethBal);
            uint256 weethOut = IWeETH(Mainnet.WEETH).wrap(eethBal);

            IMorpho(Mainnet.MORPHO).supplyCollateral(_market, weethOut, address(this), "");
            IMorpho(Mainnet.MORPHO).borrow(_market, assets, 0, address(this), address(this));
        }
    }
}
