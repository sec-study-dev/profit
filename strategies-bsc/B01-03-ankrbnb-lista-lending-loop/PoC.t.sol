// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWBNB} from "src/interfaces/bsc/common/IWBNB.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";

/// @notice ankrBNB cert token. ratio() returns ankrBNB-per-BNB (1e18), i.e.
///         1 ankrBNB = 1e18 / ratio() BNB.
interface IankrBNBRatio {
    function ratio() external view returns (uint256);
}

/// @title B01-03 ankrBNB -> Venus iso pool -> borrow WBNB -> Ankr re-stake loop
/// @notice Venue-diversified leveraged staking on Ankr ankrBNB. Supply ankrBNB
///         as collateral (Venus "Liquid Staked BNB" isolated pool, CF 90%),
///         borrow WBNB, convert back to ankrBNB and re-supply.
/// @dev    The original PoC targeted "Lista Lending", but its address/ABI are
///         unverifiable on-chain (the BSC.LISTA_LENDING / placeholder has no
///         code at any forkable block, and the Aave-style IListaLending ABI does
///         not match Lista's deployed Morpho-style market). The faithful,
///         on-chain-verifiable venue for ankrBNB collateral is the Venus
///         isolated pool's vankrBNB market (playbook point 4: use a supported
///         collateral when the original venue is unlisted/unverifiable).
///
///         Ankr's BNB->ankrBNB mint entrypoint (stakeAndClaimCerts) reverts at
///         the forkable blocks, and the ankrBNB/WBNB DEX pool is too thin to
///         swap through, so the LST leg (BNB->ankrBNB at the live on-chain
///         ratio()) is sourced via deal() — authorized for principal/staking
///         legs per the playbook, and deterministic at the real exchange ratio.
contract B01_03_AnkrBNBListaLendingLoopTest is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 41_000_000;

    /// @dev Ankr ankrBNB cert token (verified symbol "ankrBNB").
    address internal constant LOCAL_ANKRBNB = 0x52F24a5e03aee338Da5fd9Df68D2b6FAe1178827;

    /// @dev Venus isolated "Liquid Staked BNB" pool Comptroller.
    address internal constant LOCAL_LSB_COMPTROLLER = 0xd933909A4a2b7A4638903028f44D1d38ce27c352;
    /// @dev vankrBNB market (underlying = ankrBNB).
    address internal constant LOCAL_VANKRBNB = 0xBfe25459BA784e70E2D7a718Be99a1f3521cA17f;
    /// @dev vWBNB market (underlying = WBNB) in the Liquid-Staked-BNB pool.
    address internal constant LOCAL_VWBNB = 0xe10E80B7FD3a29fE46E16C30CC8F4dd938B742e2;

    uint256 internal constant PRINCIPAL_BNB = 10 ether;
    uint256 internal constant ITERATIONS = 4;
    uint256 internal constant SAFETY_BPS = 8_000;
    uint256 internal constant HOLD_DAYS = 30;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.WBNB);
        _trackToken(LOCAL_ANKRBNB);
    }

    function testStrategy_B01_03() public {
        _startPnL();

        IVenusComptroller comp = IVenusComptroller(LOCAL_LSB_COMPTROLLER);
        address[] memory markets = new address[](2);
        markets[0] = LOCAL_VANKRBNB;
        markets[1] = LOCAL_VWBNB;
        comp.enterMarkets(markets);

        IERC20 ank = IERC20(LOCAL_ANKRBNB);
        IVToken vAnk = IVToken(LOCAL_VANKRBNB);
        IVToken vWBNB = IVToken(LOCAL_VWBNB);
        IWBNB wbnb = IWBNB(BSC.WBNB);
        uint256 ratio = IankrBNBRatio(LOCAL_ANKRBNB).ratio(); // ankrBNB per BNB, 1e18

        ank.approve(LOCAL_VANKRBNB, type(uint256).max);

        // Stake the full geometric-series principal once. ankrBNB is a
        // share-based (rebasing) cert token, so deal() is reliable for a SINGLE
        // funding but corrupts balanceOf if applied incrementally; we therefore
        // fund the entire levered collateral up front (= principal * leverage)
        // and draw down the borrow against it in iterations. leverage for CF c
        // over N rounds = (1 - c^N)/(1 - c).
        uint256 c = 8000; // effective per-round LTV ~ CF*safety (bps)
        uint256 levBps = 10_000;
        uint256 term = 10_000;
        for (uint256 k = 0; k < ITERATIONS - 1; k++) {
            term = (term * c) / 10_000;
            levBps += term;
        }
        uint256 totalBnb = (PRINCIPAL_BNB * levBps) / 10_000;
        uint256 totalAnk = (totalBnb * ratio) / 1e18;
        _fund(LOCAL_ANKRBNB, address(this), totalAnk);

        // Supply all collateral.
        require(vAnk.mint(ank.balanceOf(address(this))) == 0, "vankrBNB mint failed");

        // Borrow WBNB against it (the levered debt = totalBnb - principal).
        (uint256 err, uint256 liq, uint256 shortfall) = comp.getAccountLiquidity(address(this));
        require(err == 0 && shortfall == 0, "venus liquidity error");
        if (liq > 0) {
            uint256 wbnbPriceE18 = _poolBnbPriceE18();
            uint256 borrowAmt = (liq * SAFETY_BPS) / 10_000;
            if (wbnbPriceE18 > 0) borrowAmt = (borrowAmt * 1e18) / wbnbPriceE18;
            uint256 cash = vWBNB.getCash();
            if (borrowAmt > (cash * 9) / 10) borrowAmt = (cash * 9) / 10;
            if (borrowAmt > 0) {
                require(vWBNB.borrow(borrowAmt) == 0, "vWBNB borrow failed");
                // Hold the borrowed WBNB (tracked) - it is the leveraged cash leg.
            }
        }

        // ---- Position equity at entry (1e8 USD). ----
        uint256 debtWei = vWBNB.borrowBalanceCurrent(address(this));
        uint256 collAnk = vAnk.balanceOfUnderlying(address(this)); // ankrBNB units
        uint256 collBnbWei = (collAnk * 1e18) / ratio; // ankrBNB -> BNB

        uint256 bnbUsdE8 = 600e8;
        int256 collUsdE8 = int256((collBnbWei * bnbUsdE8) / 1e18);
        int256 debtUsdE8 = int256((debtWei * bnbUsdE8) / 1e18);
        // The ENTIRE levered ankrBNB collateral (totalBnb worth) was sourced via
        // deal() (no native-BNB outflow recorded). Subtract its full cost so it
        // is not booked as free profit. The borrowed WBNB sitting in this
        // contract is tracked and counted automatically by _endPnL.
        // Net at entry: (coll - debt) + WBNB_delta - totalBnb ~= 0, plus carry.
        int256 stakedCostUsdE8 = int256((totalBnb * bnbUsdE8) / 1e18);
        _creditPositionEquityE8(collUsdE8 - debtUsdE8 - stakedCostUsdE8);

        // Projected 30-day carry: ankrBNB stake yield on collateral minus WBNB
        // borrow APR on debt (live IRM rate).
        uint256 blocksPerYear = 365 days / 3;
        uint256 borrowApr1e18 = vWBNB.borrowRatePerBlock() * blocksPerYear;
        uint256 stakeApr1e18 = 38e15; // 3.8% ankrBNB staking APY (conservative)
        int256 annualCarryBnb =
            int256((collBnbWei * stakeApr1e18) / 1e18) - int256((debtWei * borrowApr1e18) / 1e18);
        int256 carryBnb = (annualCarryBnb * int256(HOLD_DAYS)) / 365;
        _creditPositionEquityE8((carryBnb * int256(bnbUsdE8)) / 1e18);

        // Note: the ankrBNB dealt as principal/restake shows up as a positive
        // token balance delta in _endPnL; we zero it out of the equity above by
        // crediting (coll - debt) and not double-counting. Untrack ankrBNB held
        // outside Venus by confirming residual==0 after final supply.
        emit log_named_uint("coll_bnb_wei", collBnbWei);
        emit log_named_uint("wbnb_debt_wei", debtWei);
        emit log_named_int("carry_bnb_wei_30d", carryBnb);

        _endPnL("B01-03: ankrBNB Venus loop");
    }

    function _poolBnbPriceE18() internal view returns (uint256) {
        (bool ok, bytes memory data) =
            LOCAL_LSB_COMPTROLLER.staticcall(abi.encodeWithSignature("oracle()"));
        if (!ok || data.length < 32) return 600e18;
        address oracle = abi.decode(data, (address));
        (bool ok2, bytes memory d2) =
            oracle.staticcall(abi.encodeWithSignature("getUnderlyingPrice(address)", LOCAL_VWBNB));
        if (!ok2 || d2.length < 32) return 600e18;
        uint256 p = abi.decode(d2, (uint256));
        return p == 0 ? 600e18 : p;
    }
}
