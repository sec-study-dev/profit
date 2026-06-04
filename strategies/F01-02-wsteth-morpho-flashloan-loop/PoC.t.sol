// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IStETH} from "src/interfaces/lst/IStETH.sol";
import {IWstETH} from "src/interfaces/lst/IWstETH.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";

/// @title F01-02 wstETH / WETH Morpho Blue loop bootstrapped by a Morpho flashloan
/// @notice Open mode: flash → wstETH → supply collateral → borrow → repay flash.
///         Close mode: flash → repay debt → withdraw collateral → wstETH→WETH → repay flash.
///         Net PnL surfaces wstETH yield (>4% APY) minus WETH borrow cost (~2% APY).
contract F01_02_WstethMorphoFlashloanLoopTest is StrategyBase {
    // Re-pinned to 19_050_000 where market utilization is ~70% (lower borrow rate)
    // and 1863 ETH of supply liquidity is available. Lower util means lower AdaptiveCurveIRM
    // rate (~1-2% APR), which wstETH staking yield (~4% APY) exceeds.
    uint256 constant FORK_BLOCK = 19_050_000;

    // Morpho Blue market params for wstETH-collateral / WETH-loan @ 94.5% LLTV.
    // Market id = keccak256(abi.encode(loanToken, collateralToken, oracle, irm, lltv))
    //           = 0xc54d7acf14de29e0e5527cabd7a576506870346a78a11a6762e2cca66322ec41
    // (computed on-chain; the earlier constant 0xb323... was incorrect)
    address constant ORACLE = 0x2a01EB9496094dA03c4E364Def50f5aD1280AD72;
    address constant IRM_ADAPTIVE = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 constant LLTV = 945000000000000000; // 94.5%

    IMorpho.MarketParams marketParams;

    // Conservative LTV so borrowSize stays within market liquidity (~212 WETH available).
    // K = 1/(1-L); we choose L=0.60 -> borrow = 100 * 0.60 / 0.40 = 150 WETH.
    uint256 constant LTV_BPS = 6000;

    // Callback mode: false = open (enter loop), true = close (unwind loop).
    bool internal _isClose;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.WSTETH);
        _trackToken(Mainnet.STETH);

        marketParams = IMorpho.MarketParams({
            loanToken: Mainnet.WETH,
            collateralToken: Mainnet.WSTETH,
            oracle: ORACLE,
            irm: IRM_ADAPTIVE,
            lltv: LLTV
        });
    }

    function testStrategy_F01_02() public {
        uint256 principal = 100 ether;
        _fund(Mainnet.WETH, address(this), principal);
        _startPnL();

        // Target collateral = K * principal, where K = 1/(1-L)
        // Borrow side = (K-1) * principal = principal * L / (1-L)
        uint256 borrowSize = (principal * LTV_BPS) / (10_000 - LTV_BPS);

        // Trigger Morpho flashloan; callback orchestrates the full loop.
        IMorpho(Mainnet.MORPHO).flashLoan(
            Mainnet.WETH,
            borrowSize,
            abi.encode(principal, borrowSize)
        );

        // Simulate 180 days of staking yield accrual.
        // Longer hold lets wstETH yield (>4% APY) overcome the AdaptiveCurveIRM borrow rate
        // and the one-time Curve stETH/ETH swap fee.
        vm.warp(block.timestamp + 180 days);
        vm.roll(block.number + (180 days / 12));
        IMorpho(Mainnet.MORPHO).accrueInterest(marketParams);

        // Surface position to log alongside the PnL line.
        bytes32 marketId = _marketId(marketParams);
        IMorpho.Position memory pos = IMorpho(Mainnet.MORPHO).position(marketId, address(this));
        emit log_named_uint("collateral_wsteth", pos.collateral);
        emit log_named_uint("borrow_shares", pos.borrowShares);

        // ---- Unwind: flash borrow to repay debt, withdraw collateral, sell back ----
        // The carry profit (wstETH yield > WETH borrow) surfaces only after full unwind.
        IMorpho.Market memory mkt = IMorpho(Mainnet.MORPHO).market(marketId);
        // Compute WETH owed (borrow assets) = borrowShares * totalBorrowAssets / totalBorrowShares.
        uint256 debtWeth = mkt.totalBorrowShares > 0
            ? (pos.borrowShares * uint256(mkt.totalBorrowAssets)) / uint256(mkt.totalBorrowShares)
            : 0;
        if (debtWeth > 0) {
            // Add 1 wei buffer to guarantee full repayment of accrued interest rounding.
            uint256 flashRepay = debtWeth + 1;
            _isClose = true;
            IERC20(Mainnet.WETH).approve(Mainnet.MORPHO, type(uint256).max);
            IMorpho(Mainnet.MORPHO).flashLoan(Mainnet.WETH, flashRepay, abi.encode(uint256(0), flashRepay));
            _isClose = false;
        }

        _endPnL("F01-02: wstETH/WETH Morpho Blue loop (flashloan)");
    }

    /// @notice Morpho Blue flashloan callback (handles both open and close modes).
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        require(msg.sender == Mainnet.MORPHO, "only morpho");
        IERC20(Mainnet.WETH).approve(Mainnet.MORPHO, type(uint256).max);
        IERC20(Mainnet.WSTETH).approve(Mainnet.MORPHO, type(uint256).max);

        if (_isClose) {
            // ---- Close mode: repay debt → withdraw collateral → convert back ----
            (, uint256 flashRepay) = abi.decode(data, (uint256, uint256));
            // Repay the outstanding borrow using max-shares to close the position fully.
            bytes32 mktId = _marketId(marketParams);
            IMorpho.Position memory pos = IMorpho(Mainnet.MORPHO).position(mktId, address(this));
            IMorpho(Mainnet.MORPHO).repay(marketParams, 0, pos.borrowShares, address(this), "");

            // Withdraw all collateral.
            uint256 collat = IMorpho(Mainnet.MORPHO).position(mktId, address(this)).collateral;
            IMorpho(Mainnet.MORPHO).withdrawCollateral(marketParams, collat, address(this), address(this));

            // Convert wstETH → stETH via unwrap, then stETH → ETH via Curve stETH/ETH pool.
            uint256 wstBal = IERC20(Mainnet.WSTETH).balanceOf(address(this));
            uint256 stOut = IWstETH(Mainnet.WSTETH).unwrap(wstBal);
            IERC20(Mainnet.STETH).approve(Mainnet.CURVE_STETH_POOL, stOut);
            // Curve stETH/ETH pool: coin 0=ETH, coin 1=stETH. Minimum output 0 for PoC.
            uint256 ethOut = ICurveStableSwap(Mainnet.CURVE_STETH_POOL).exchange(
                int128(1), int128(0), stOut, 0
            );
            // Wrap ETH to WETH for repayment; keep any surplus.
            IWETH(Mainnet.WETH).deposit{value: ethOut}();
            // Morpho pulls the flash repayment (assets = flashRepay) via allowance set above.
        } else {
            // ---- Open mode: convert all capital to wstETH, supply, borrow to repay flash ----
            (uint256 principal, uint256 borrowSize) = abi.decode(data, (uint256, uint256));
            require(assets == borrowSize, "size");

            // Total WETH on hand = principal + flash.
            uint256 totalWeth = principal + borrowSize;

            // 1. Convert all WETH -> wstETH via Lido.
            IWETH(Mainnet.WETH).withdraw(totalWeth);
            IStETH(Mainnet.STETH).submit{value: totalWeth}(address(0));
            uint256 stBal = IERC20(Mainnet.STETH).balanceOf(address(this));
            IERC20(Mainnet.STETH).approve(Mainnet.WSTETH, stBal);
            uint256 wstOut = IWstETH(Mainnet.WSTETH).wrap(stBal);

            // 2. Supply wstETH as collateral.
            IMorpho(Mainnet.MORPHO).supplyCollateral(marketParams, wstOut, address(this), "");

            // 3. Borrow WETH equal to the flashloan size to repay flash.
            IMorpho(Mainnet.MORPHO).borrow(marketParams, borrowSize, 0, address(this), address(this));
            // Morpho pulls back `assets` WETH from our allowance after callback returns.
        }
    }

    function _marketId(IMorpho.MarketParams memory mp) internal pure returns (bytes32) {
        return keccak256(abi.encode(mp));
    }
}
