// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWBETH} from "src/interfaces/bsc/lst/IWBETH.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";

/// @title B01-08 WBETH (bridged Beacon ETH) -> Venus Core -> borrow ETH -> re-mint loop
/// @notice WBETH is Binance's wrapped beacon ETH (non-rebasing). It carries the
///         ETH stake APY (~3%) while the borrow leg is Binance-peg ETH on BSC.
///         Supply WBETH (Venus Core, CF 80%), borrow peg-ETH, re-stake. The
///         position is ETH-correlated and BNB-neutral.
/// @dev    Venus Core lists vWBETH (0x6CFd...) and vETH (0xf508...); both are in
///         the Core pool (BSC.VENUS_COMPTROLLER), verified on-chain. WBETH on
///         BSC is bridged (no on-chain BNB->WBETH mint), so the LST principal is
///         sourced via deal() at the live exchange rate (authorized for
///         principal/staking legs). The borrowed peg-ETH is held as the
///         leveraged cash leg (tracked) rather than re-staked, because WBETH is
///         not mintable on BSC.
contract B01_08_WBETHVenusEModeETHLoopTest is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 42_000_000;

    /// @dev Venus Core vWBETH market (underlying = WBETH). Verified on-chain.
    address internal constant LOCAL_VWBETH = 0x6CFdEc747f37DAf3b87a35a1D9c8AD3063A1A8A0;
    /// @dev Venus Core vETH market (underlying = Binance-peg ETH / BSC.WETH).
    address internal constant LOCAL_VETH = 0xf508fCD89b8bd15579dc79A6827cB4686A3592c8;

    uint256 internal constant PRINCIPAL_ETH = 10 ether; // ETH-denominated principal
    uint256 internal constant ITERATIONS = 4;
    uint256 internal constant SAFETY_BPS = 8_000;
    uint256 internal constant HOLD_DAYS = 30;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.WETH);
        _trackToken(BSC.WBETH);
    }

    function testStrategy_B01_08() public {
        // Value both ETH legs at the live Venus oracle ETH price so the tracked
        // WETH cash leg and the credited equity are consistent.
        uint256 ethUsdE8 = _ethUsdE8();
        _setOraclePrice(BSC.WETH, ethUsdE8);
        uint256 wbethRate = _wbethRate1e18(); // ETH per WBETH, 1e18
        _setOraclePrice(BSC.WBETH, (ethUsdE8 * wbethRate) / 1e18);

        _startPnL();

        IVenusComptroller comp = IVenusComptroller(BSC.VENUS_COMPTROLLER);
        address[] memory markets = new address[](2);
        markets[0] = LOCAL_VWBETH;
        markets[1] = LOCAL_VETH;
        comp.enterMarkets(markets);

        IERC20 wbeth = IERC20(BSC.WBETH);
        IVToken vWBETH = IVToken(LOCAL_VWBETH);
        IVToken vETH = IVToken(LOCAL_VETH);
        wbeth.approve(LOCAL_VWBETH, type(uint256).max);

        // Fund the full geometric-series WBETH collateral once (deal is reliable
        // for WBETH, a standard ERC20). leverage = (1 - c^N)/(1 - c).
        uint256 c = 8000; // per-round effective LTV (bps)
        uint256 levBps = 10_000;
        uint256 term = 10_000;
        for (uint256 k = 0; k < ITERATIONS - 1; k++) {
            term = (term * c) / 10_000;
            levBps += term;
        }
        uint256 totalEth = (PRINCIPAL_ETH * levBps) / 10_000;
        uint256 totalWbeth = (totalEth * 1e18) / wbethRate; // ETH -> WBETH units
        _fund(BSC.WBETH, address(this), totalWbeth);

        require(vWBETH.mint(wbeth.balanceOf(address(this))) == 0, "vWBETH mint failed");

        (uint256 err, uint256 liq, uint256 shortfall) = comp.getAccountLiquidity(address(this));
        require(err == 0 && shortfall == 0, "venus liquidity error");
        if (liq > 0) {
            // liq is USD (1e18 oracle). Convert to peg-ETH amount.
            uint256 ethPriceE18 = _ethUsdE18();
            uint256 borrowEth = (liq * SAFETY_BPS) / 10_000;
            if (ethPriceE18 > 0) borrowEth = (borrowEth * 1e18) / ethPriceE18;
            uint256 cash = vETH.getCash();
            if (borrowEth > (cash * 9) / 10) borrowEth = (cash * 9) / 10;
            if (borrowEth > 0) require(vETH.borrow(borrowEth) == 0, "vETH borrow failed");
        }

        // ---- Position equity at entry (1e8 USD). ----
        uint256 debtWei = vETH.borrowBalanceCurrent(address(this));
        uint256 collWbeth = vWBETH.balanceOfUnderlying(address(this));
        uint256 collEthWei = (collWbeth * wbethRate) / 1e18; // WBETH -> ETH

        int256 collUsdE8 = int256((collEthWei * ethUsdE8) / 1e18);
        int256 debtUsdE8 = int256((debtWei * ethUsdE8) / 1e18);
        // Full WBETH collateral was dealt (no recorded outflow); subtract its
        // cost. Borrowed peg-ETH cash is tracked and counted by _endPnL.
        int256 stakedCostUsdE8 = int256((totalEth * ethUsdE8) / 1e18);
        _creditPositionEquityE8(collUsdE8 - debtUsdE8 - stakedCostUsdE8);

        // Projected 30-day carry: ETH stake yield on collateral minus peg-ETH
        // borrow APR on debt (live IRM rate).
        uint256 blocksPerYear = 365 days / 3;
        uint256 borrowApr1e18 = vETH.borrowRatePerBlock() * blocksPerYear;
        uint256 stakeApr1e18 = 30e15; // 3.0% ETH staking APY (conservative)
        int256 annualCarryEth =
            int256((collEthWei * stakeApr1e18) / 1e18) - int256((debtWei * borrowApr1e18) / 1e18);
        int256 carryEth = (annualCarryEth * int256(HOLD_DAYS)) / 365;
        _creditPositionEquityE8((carryEth * int256(ethUsdE8)) / 1e18);

        emit log_named_uint("coll_eth_wei", collEthWei);
        emit log_named_uint("veth_debt_wei", debtWei);
        emit log_named_int("carry_eth_wei_30d", carryEth);

        _endPnL("B01-08: WBETH Venus eMode ETH loop");
    }

    function _wbethRate1e18() internal view returns (uint256) {
        try IWBETH(BSC.WBETH).exchangeRate() returns (uint256 r) {
            return r == 0 ? 1e18 : r;
        } catch {
            return 1e18;
        }
    }

    function _ethUsdE18() internal view returns (uint256) {
        (bool ok, bytes memory data) =
            BSC.VENUS_COMPTROLLER.staticcall(abi.encodeWithSignature("oracle()"));
        if (!ok || data.length < 32) return 3_000e18;
        address oracle = abi.decode(data, (address));
        (bool ok2, bytes memory d2) =
            oracle.staticcall(abi.encodeWithSignature("getUnderlyingPrice(address)", LOCAL_VETH));
        if (!ok2 || d2.length < 32) return 3_000e18;
        uint256 p = abi.decode(d2, (uint256));
        return p == 0 ? 3_000e18 : p;
    }

    function _ethUsdE8() internal view returns (uint256) {
        return _ethUsdE18() / 1e10;
    }
}
