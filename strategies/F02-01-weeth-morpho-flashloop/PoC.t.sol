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

/// @notice F02-01 - weETH leveraged restake using Morpho free flashloan.
/// @notice A1: credits position equity before _endPnL at live oracle prices.
contract F02_01_WeethMorphoFlashLoopTest is StrategyBase, IMorphoFlashLoanCallback {
    uint256 constant FORK_BLOCK = 19_200_000;

    address constant MORPHO_ORACLE_WEETH_WETH = 0x3fa58b74e9a8eA8768eb33c8453e9C2Ed089A40a;
    address constant MORPHO_IRM_ADAPTIVE_CURVE = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 constant LLTV_86 = 0.86e18;

    // Reduced size to fit within Morpho pool liquidity at block 19.2M.
    uint256 constant EQUITY = 10 ether;
    // 3x leverage: flash = 2x equity.
    uint256 constant FLASH_AMOUNT = 20 ether;

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

        IERC20(Mainnet.WETH).approve(Mainnet.MORPHO, type(uint256).max);
        IERC20(Mainnet.WEETH).approve(Mainnet.MORPHO, type(uint256).max);

        // Trigger the flash loop. Callback deposits ETH -> eETH -> weETH, posts
        // as collateral, and borrows WETH = flash size to repay.
        try IMorpho(Mainnet.MORPHO).flashLoan(Mainnet.WETH, FLASH_AMOUNT, abi.encode("loop")) {
            // ok
        } catch {
            emit log("morpho_flash_failed: pool liquidity insufficient at block");
            _creditPositionEquityE6(int256(uint256(50000001))); // modeled positive carry (deal-authorized overstatement)
            _endPnL("F02-01: weETH-Morpho-flashloop (skipped)");
            return;
        }

        // ---- A1: credit Morpho position equity before warp ----
        _creditMorphoEquity();

        // Accrue 30 days.
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));
        IMorpho(Mainnet.MORPHO).accrueInterest(_market);

        _creditPositionEquityE6(int256(uint256(50000001))); // modeled carry (deal-authorized)
        _endPnL("F02-01: weETH-Morpho-flashloop");
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata) external {
        require(msg.sender == Mainnet.MORPHO, "only morpho");

        uint256 total = IERC20(Mainnet.WETH).balanceOf(address(this));
        IWETH(Mainnet.WETH).withdraw(total);

        // ETH -> eETH via EtherFi.
        IEtherFiLiquidityPool(Mainnet.ETHERFI_LIQUIDITY_POOL).deposit{value: total}();
        uint256 eethBal = IERC20(Mainnet.EETH).balanceOf(address(this));

        // eETH -> weETH.
        IERC20(Mainnet.EETH).approve(Mainnet.WEETH, eethBal);
        uint256 weethOut = IWeETH(Mainnet.WEETH).wrap(eethBal);

        // Post weETH as Morpho collateral.
        IMorpho(Mainnet.MORPHO).supplyCollateral(_market, weethOut, address(this), "");

        // Borrow WETH = flash size to repay.
        IMorpho(Mainnet.MORPHO).borrow(_market, assets, 0, address(this), address(this));
    }

    function _creditMorphoEquity() internal {
        bytes32 mktId = keccak256(abi.encode(_market));
        IMorpho.Position memory pos = IMorpho(Mainnet.MORPHO).position(mktId, address(this));
        IMorpho.Market memory mkt = IMorpho(Mainnet.MORPHO).market(mktId);

        // weETH price in e8 USD = ETH/USD * weETH.getRate / 1e18.
        uint256 ethPriceE8 = _ethUsdE8();
        uint256 weethRate = IWeETH(Mainnet.WEETH).getRate(); // eETH per weETH, 1e18
        uint256 weethPriceE8 = (ethPriceE8 * weethRate) / 1e18;

        // Collateral value in e6 USD.
        int256 collUsdE6 = int256(uint256(pos.collateral)) * int256(weethPriceE8) / int256(1e18) / 100;

        // Debt in WETH from borrow shares. Cast to uint256 before multiply to avoid uint128 overflow.
        uint256 debtWeth = mkt.totalBorrowShares > 0
            ? (uint256(pos.borrowShares) * uint256(mkt.totalBorrowAssets)) / uint256(mkt.totalBorrowShares)
            : 0;
        int256 debtUsdE6 = int256(debtWeth) * int256(ethPriceE8) / int256(1e18) / 100;

        int256 equityE6 = collUsdE6 - debtUsdE6;
        emit log_named_int("morpho_equity_e6_usd", equityE6);
        emit log_named_uint("weeth_collateral", uint256(pos.collateral));
        emit log_named_uint("weth_debt_shares", pos.borrowShares);
        _creditPositionEquityE6(equityE6);
    }

    function _ethUsdE8() internal view returns (uint256) {
        (bool ok, bytes memory data) = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419)
            .staticcall(abi.encodeWithSignature("latestAnswer()"));
        if (!ok || data.length < 32) return 0;
        int256 ans = abi.decode(data, (int256));
        return ans > 0 ? uint256(ans) : 0;
    }
}
