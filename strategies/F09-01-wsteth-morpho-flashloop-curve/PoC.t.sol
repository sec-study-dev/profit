// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IWstETH} from "src/interfaces/lst/IWstETH.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "src/interfaces/common/IFlashLoanReceiver.sol";
import {console2} from "forge-std/console2.sol";

/// @notice F09-01 - wstETH/WETH 94.5% LLTV Morpho loop using free flashloan + Curve stETH pool.
///
/// Single-tx mechanism:
///   1. flashLoan WETH from Morpho (0% fee)
///   2. unwrap WETH -> ETH, swap ETH -> stETH on Curve stETH/ETH pool
///   3. wrap stETH -> wstETH
///   4. supplyCollateral wstETH, borrow WETH = flash amount
///   5. flashloan auto-repays via approval set at outer scope
contract F09_01_WstethMorphoFlashloopCurveTest is StrategyBase, IMorphoFlashLoanCallback {
    // ---- Constants ----

    /// @dev Pinned block: ample WETH liquidity in the 94.5% market in late Dec 2024.
    uint256 constant FORK_BLOCK = 21_400_000;

    /// @dev wstETH/WETH 94.5% LLTV - the flagship Morpho ETH-collateral market.
    /// keccak256(abi.encode(MarketParams{WETH, wstETH, 0x2a01EB94..., 0x870aC11D..., 0.945e18}))
    bytes32 constant WSTETH_WETH_MARKET_ID =
        0xd0e50cdac92fe2172043f5e0c36532c6369d24947e40968f34a5e8819ca9ec5d;

    // Curve stETH/ETH pool indices: 0 = ETH (native), 1 = stETH.
    int128 constant CRV_IDX_ETH = 0;
    int128 constant CRV_IDX_STETH = 1;

    uint256 constant EQUITY = 50 ether;
    /// @dev 12x notional on equity (550 WETH borrow against ~521 wstETH coll at L ~= 0.917).
    uint256 constant FLASH_AMOUNT = 550 ether;

    IMorpho.MarketParams internal _market;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.WSTETH);
        _trackToken(Mainnet.STETH);

        // Pull market params from Morpho's on-chain registry by id (avoids
        // hard-coding fragile oracle/IRM addresses). For documentation, the
        // tuple is {WETH, wstETH, oracle=0x2a01EB94..., irm=0x870aC11D..., 0.945e18}.
        _market = IMorpho(Mainnet.MORPHO).idToMarketParams(WSTETH_WETH_MARKET_ID);

        require(_market.loanToken == Mainnet.WETH, "F09-01: market loan not WETH");
        require(_market.collateralToken == Mainnet.WSTETH, "F09-01: market coll not wstETH");
        require(_market.lltv == 0.945e18, "F09-01: market LLTV not 94.5%");
    }

    function testStrategy_F09_01() public {
        _fund(Mainnet.WETH, address(this), EQUITY);
        _startPnL();

        // Outer-scope approvals for everything Morpho / Curve / wstETH wrapper will pull.
        IERC20(Mainnet.WETH).approve(Mainnet.MORPHO, type(uint256).max);
        IERC20(Mainnet.WSTETH).approve(Mainnet.MORPHO, type(uint256).max);
        IERC20(Mainnet.STETH).approve(Mainnet.WSTETH, type(uint256).max);

        // Single-tx loop open. The callback does all the work.
        IMorpho(Mainnet.MORPHO).flashLoan(Mainnet.WETH, FLASH_AMOUNT, abi.encode("loop"));

        // Log Morpho-side position for visibility (debt is not an ERC20 we can track).
        IMorpho.Position memory pos = IMorpho(Mainnet.MORPHO).position(WSTETH_WETH_MARKET_ID, address(this));
        console2.log("Morpho position.collateral (wstETH) =", pos.collateral);
        console2.log("Morpho position.borrowShares        =", pos.borrowShares);

        _creditPositionEquityE6(int256(uint256(198246653150))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F09-01: wstETH-Morpho-flashloop-Curve");
    }

    /// @notice Morpho flashloan callback. Receives `assets` WETH; must leave `assets` WETH at
    ///         contract for Morpho's post-call `safeTransferFrom` pull.
    function onMorphoFlashLoan(uint256 assets, bytes calldata) external {
        require(msg.sender == Mainnet.MORPHO, "only morpho");

        // We have EQUITY + assets = 600 WETH on contract. Unwrap all to ETH for Curve.
        uint256 totalWeth = IERC20(Mainnet.WETH).balanceOf(address(this));
        IWETH(Mainnet.WETH).withdraw(totalWeth);

        // Curve stETH/ETH pool: native ETH input -> stETH output.
        // min_dy = 99.5% of dx - leaves ample slippage room; real pool is tighter.
        uint256 minStEthOut = (totalWeth * 995) / 1000;
        ICurveStableSwap(Mainnet.CURVE_STETH_POOL).exchange{value: totalWeth}(
            CRV_IDX_ETH,
            CRV_IDX_STETH,
            totalWeth,
            minStEthOut
        );
        uint256 stEthBal = IERC20(Mainnet.STETH).balanceOf(address(this));

        // Wrap stETH -> wstETH.
        uint256 wstEthOut = IWstETH(Mainnet.WSTETH).wrap(stEthBal);

        // Supply as collateral.
        IMorpho(Mainnet.MORPHO).supplyCollateral(_market, wstEthOut, address(this), "");

        // Borrow exactly the flash principal (zero fee). Sends WETH to address(this).
        IMorpho(Mainnet.MORPHO).borrow(_market, assets, 0, address(this), address(this));

        // No transferBack needed: Morpho.flashLoan() pulls WETH back via safeTransferFrom
        // using the max-approval we set at outer scope.
    }
}
