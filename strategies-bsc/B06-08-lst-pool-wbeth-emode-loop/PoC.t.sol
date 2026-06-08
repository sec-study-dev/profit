// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {IWBETH} from "src/interfaces/bsc/lst/IWBETH.sol";

/// @title B06-08 Venus WBETH-collateralised leveraged staking carry
/// @notice The "Liquid Staked BNB" isolated pool does NOT list WBETH/WETH and
///         Venus Core has no WETH borrow market, so a WBETH/WETH eMode loop is
///         infeasible on BSC. Faithful restructure: WBETH is supplied to its
///         Venus **Core** market (vWBETH, CF 0.80) and a modest USDT loan is
///         drawn against it. The position is a leveraged long-WBETH staking
///         carry: the WBETH ETH-staking yield on the collateral exceeds the
///         USDT borrow cost on the (deliberately small) debt. Collateral parks
///         in Venus, so PnL is on-chain equity (collateral - debt) plus the
///         projected net carry over the hold horizon.
contract B06_08_VenusWBETHCarryTest is BSCStrategyBase {
    // Verified at this block: vWBETH (Core) and vUSDT (Core) have code and
    // ample supply-cap / cash headroom.
    uint256 internal constant FORK_BLOCK = 44_000_000;

    // ---- Verified Venus Core addresses ----
    address internal constant LOCAL_VWBETH_CORE = 0x6CFdEc747f37DAf3b87a35a1D9c8AD3063A1A8A0;
    // BSC.vUSDT is the Core vUSDT.

    uint256 internal constant PRINCIPAL_WBETH = 100 ether;
    /// @dev Conservative LTV so the WBETH staking yield outweighs USDT cost.
    uint256 internal constant BORROW_LTV_BPS = 2_500;
    uint256 internal constant HOLD_DAYS = 30;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.WBETH);
        _trackToken(BSC.USDT);
        _trackToken(LOCAL_VWBETH_CORE);
        _trackToken(BSC.vUSDT);
    }

    function testStrategy_B06_08() public {
        _fund(BSC.WBETH, address(this), PRINCIPAL_WBETH);
        _startPnL();

        IVenusComptroller comp = IVenusComptroller(BSC.VENUS_COMPTROLLER);
        address[] memory mk = new address[](1);
        mk[0] = LOCAL_VWBETH_CORE;
        comp.enterMarkets(mk);

        IVToken vWbeth = IVToken(LOCAL_VWBETH_CORE);
        IVToken vUsdt = IVToken(BSC.vUSDT);

        // ---- Supply WBETH ----
        IERC20(BSC.WBETH).approve(LOCAL_VWBETH_CORE, type(uint256).max);
        require(vWbeth.mint(PRINCIPAL_WBETH) == 0, "vWBETH mint failed");

        // ---- Borrow a modest USDT amount against it ----
        // WBETH rate -> ETH; ETH ~$3000 in the base override.
        uint256 rate = 1e18;
        try IWBETH(BSC.WBETH).exchangeRate() returns (uint256 r) {
            if (r > 0) rate = r;
        } catch {}
        uint256 collUsd = PRINCIPAL_WBETH * rate / 1e18 * 3_000; // USD (1e18)
        uint256 borrowUsdt = collUsd * BORROW_LTV_BPS / 10_000;   // USDT (1e18)
        uint256 cash = vUsdt.getCash();
        if (borrowUsdt > cash) borrowUsdt = cash / 2;
        require(vUsdt.borrow(borrowUsdt) == 0, "vUSDT borrow failed");

        uint256 usdtBorrowed = IERC20(BSC.USDT).balanceOf(address(this));
        emit log_named_uint("usdt_borrowed_e18", usdtBorrowed);

        // ---- Position equity (collateral - debt), 1e8 USD ----
        uint256 wbethColl = vWbeth.balanceOfUnderlying(address(this));
        uint256 usdtDebt = vUsdt.borrowBalanceCurrent(address(this));
        uint256 wbethPriceE8 = 3_000e8 * rate / 1e18;
        emit log_named_uint("wbeth_exchange_rate_1e18", rate);
        emit log_named_uint("wbeth_collateral_wei", wbethColl);
        emit log_named_uint("usdt_debt_e18", usdtDebt);

        int256 collE8 = int256(wbethColl * wbethPriceE8 / 1e18);
        int256 debtE8 = int256(usdtDebt * 1e8 / 1e18);
        _creditPositionEquityE8(collE8 - debtE8);

        // ---- Projected 30-day net carry ----
        // WBETH staking yield ~3.7% APY on collateral; USDT borrow cost from
        // the live IRM on the debt. Static fork => project, don't warp.
        uint256 wbethYieldE8 = (uint256(collE8) * 370 / 10_000) * 30 / 365;
        uint256 usdtBorrowRate = vUsdt.borrowRatePerBlock();
        uint256 borrowCostUsdt = usdtDebt * usdtBorrowRate * (30 days / 3) / 1e18; // USDT wei
        int256 carryE8 = int256(wbethYieldE8) - int256(borrowCostUsdt * 1e8 / 1e18);
        emit log_named_int("projected_30d_carry_e8", carryE8);
        _creditPositionEquityE8(carryE8);

        // Note on accounting: the WBETH token leg captures the -principal as
        // the WBETH leaves `address(this)` (priced at the WBETH override). The
        // equity credit adds back the on-chain collateral (+) and the debt (-)
        // so the held USDT (the borrow proceeds, +) nets the debt. Net PnL is
        // therefore the projected carry. We mark WBETH to its real ETH
        // exchange rate so the principal leg is valued correctly.
        _setOraclePrice(BSC.WBETH, wbethPriceE8);

        _endPnL("B06-08: Venus WBETH leveraged staking carry");
    }
}
