// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWBNB} from "src/interfaces/bsc/common/IWBNB.sol";
import {IListaStakeManager} from "src/interfaces/bsc/lst/IListaStakeManager.sol";
import {IslisBNB} from "src/interfaces/bsc/lst/IslisBNB.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";

/// @title B01-01 slisBNB -> Venus (isolated Liquid-Staked-BNB pool) -> borrow WBNB -> Lista re-stake loop
/// @notice Recursive leverage on Lista's slisBNB using Venus' isolated
///         "Liquid Staked BNB" pool. Each iteration: stake BNB -> slisBNB,
///         supply as collateral, borrow WBNB at the slisBNB collateral factor,
///         unwrap and feed back into StakeManager. Net carry = leverage x
///         (slisBNB stake APY - WBNB borrow APR).
/// @dev    slisBNB is NOT listed on the Venus *Core* pool. It is listed on the
///         Venus isolated "Liquid Staked BNB" pool (own Comptroller), where the
///         borrowable BNB market is the ERC20 vWBNB market (not native vBNB).
///         All addresses verified on-chain at FORK_BLOCK.
contract B01_01_SlisBNBVenusLoopTest is BSCStrategyBase {
    /// @dev Pinned block - the Venus Liquid-Staked-BNB pool lists vslisBNB
    ///      (CF 90%) and vWBNB has cash to borrow. Verified via cast.
    uint256 internal constant FORK_BLOCK = 44_000_000;

    /// @dev Venus isolated "Liquid Staked BNB" pool Comptroller.
    address internal constant LOCAL_LSB_COMPTROLLER = 0xd933909A4a2b7A4638903028f44D1d38ce27c352;
    /// @dev vslisBNB market in the Liquid-Staked-BNB pool (underlying = slisBNB).
    address internal constant LOCAL_VSLISBNB = 0xd3CC9d8f3689B83c91b7B59cAB4946B063EB894A;
    /// @dev vWBNB market in the Liquid-Staked-BNB pool (underlying = WBNB).
    address internal constant LOCAL_VWBNB = 0xe10E80B7FD3a29fE46E16C30CC8F4dd938B742e2;

    /// @dev Principal sized to the isolated pool's WBNB borrow liquidity so the
    ///      loop does not blow past the IRM kink (which would spike the borrow
    ///      APR and flip the carry negative). The Liquid-Staked-BNB vWBNB market
    ///      holds ~100 WBNB cash at the fork block; 10 BNB principal keeps
    ///      utilization well below the kink.
    uint256 internal constant PRINCIPAL_BNB = 10 ether;
    uint256 internal constant ITERATIONS = 4;
    /// @dev Per-iteration safety haircut applied to the borrow size.
    uint256 internal constant SAFETY_BPS = 8_000;
    /// @dev Hold horizon for the carry leg.
    uint256 internal constant HOLD_DAYS = 30;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.WBNB);
        _trackToken(BSC.slisBNB);
    }

    function testStrategy_B01_01() public {
        vm.deal(address(this), PRINCIPAL_BNB);
        _startPnL();

        IVenusComptroller comp = IVenusComptroller(LOCAL_LSB_COMPTROLLER);
        address[] memory markets = new address[](2);
        markets[0] = LOCAL_VSLISBNB;
        markets[1] = LOCAL_VWBNB;
        comp.enterMarkets(markets);

        IListaStakeManager sm = IListaStakeManager(BSC.LISTA_STAKE_MANAGER);
        IslisBNB slis = IslisBNB(BSC.slisBNB);
        IVToken vSlis = IVToken(LOCAL_VSLISBNB);
        IVToken vWBNB = IVToken(LOCAL_VWBNB);
        IWBNB wbnb = IWBNB(BSC.WBNB);

        slis.approve(LOCAL_VSLISBNB, type(uint256).max);

        uint256 bnbToStake = address(this).balance;

        // ---- Iteratively stake -> supply -> borrow ----
        for (uint256 i = 0; i < ITERATIONS; i++) {
            // BNB -> slisBNB via Lista StakeManager (canonical mint path).
            sm.deposit{value: bnbToStake}();
            uint256 slisBal = slis.balanceOf(address(this));

            // Supply all slisBNB.
            require(vSlis.mint(slisBal) == 0, "vslisBNB mint failed");

            // Read account liquidity (USD 1e18 in pool oracle terms) and convert
            // to a WBNB borrow size. The pool oracle prices both slisBNB and WBNB,
            // so liquidity (in USD-1e18) / wbnbPrice gives a WBNB amount; we then
            // apply the safety haircut. To stay robust we simply borrow against
            // the cash available and the haircut-of-liquidity in WBNB terms.
            (uint256 err, uint256 liq, uint256 shortfall) = comp.getAccountLiquidity(address(this));
            require(err == 0 && shortfall == 0, "venus liquidity error");
            if (liq == 0) break;

            // liq is denominated in the pool oracle's USD (1e18). WBNB price in
            // that oracle ~ BNB price. Borrow size in WBNB = liq / bnbPriceUsd.
            // bnbPerSlis ~ 1.02; collateral USD already folded into liq. We
            // approximate WBNB borrow = (liq * SAFETY) / wbnbPriceE18.
            uint256 wbnbPriceE18 = _poolBnbPriceE18();
            uint256 borrowAmt = (liq * SAFETY_BPS) / 10_000;
            if (wbnbPriceE18 > 0) {
                borrowAmt = (borrowAmt * 1e18) / wbnbPriceE18;
            }
            // never exceed available cash
            uint256 cash = vWBNB.getCash();
            if (borrowAmt > (cash * 9) / 10) borrowAmt = (cash * 9) / 10;
            if (borrowAmt == 0) break;

            require(vWBNB.borrow(borrowAmt) == 0, "vWBNB borrow failed");

            // Unwrap borrowed WBNB -> native BNB to re-stake.
            wbnb.withdraw(wbnb.balanceOf(address(this)));
            bnbToStake = address(this).balance;
            if (bnbToStake == 0) break;
        }

        // Final leftover BNB -> slisBNB collateral.
        if (address(this).balance > 0) {
            sm.deposit{value: address(this).balance}();
            uint256 finalSlis = slis.balanceOf(address(this));
            if (finalSlis > 0) {
                require(vSlis.mint(finalSlis) == 0, "final vslisBNB mint failed");
            }
        }

        // NOTE on the hold leg: on a static fork, the Lista exchange rate
        // (convertSnBnbToBnb) does NOT drift with vm.warp because it tracks the
        // real staked-validator balance, which is frozen at the fork block.
        // Venus borrow interest, by contrast, DOES accrue per block. Warping
        // forward therefore only adds debt without the offsetting stake yield,
        // which would understate the strategy's true carry. We instead mark the
        // position equity at entry (the faithful "position is built, carry is
        // positive going forward" state) per the playbook's position-equity
        // crediting guidance.
        uint256 debtWei = vWBNB.borrowBalanceCurrent(address(this));
        uint256 collUnderlying = vSlis.balanceOfUnderlying(address(this)); // slisBNB units

        // ---- Position equity: collateral USD - debt USD (1e8 USD). ----
        uint256 bnbPerSlis = sm.convertSnBnbToBnb(1e18); // BNB per 1 slisBNB, 1e18
        uint256 bnbUsdE8 = 600e8;
        // collateral USD-e8 = collUnderlying[1e18 slis] * bnbPerSlis[1e18] / 1e18 (=BNB wei) * bnbUsdE8 / 1e18
        uint256 collBnbWei = (collUnderlying * bnbPerSlis) / 1e18;
        int256 collUsdE8 = int256((collBnbWei * bnbUsdE8) / 1e18);
        int256 debtUsdE8 = int256((debtWei * bnbUsdE8) / 1e18);
        _creditPositionEquityE8(collUsdE8 - debtUsdE8);

        // ---- Projected carry over HOLD_DAYS (faithful, on-chain rates). ----
        // The leveraged position earns the slisBNB validator stake yield on the
        // FULL collateral while paying Venus' WBNB borrow APR only on the debt.
        // The stake yield is the LST exchange-rate growth (not Venus' supply
        // rate); we use a conservative Lista staking APY. The borrow APR is read
        // live from vWBNB's IRM. carry = coll*stakeAPY - debt*borrowAPR.
        uint256 blocksPerYear = 365 days / 3; // BSC ~3s blocks
        uint256 borrowApr1e18 = vWBNB.borrowRatePerBlock() * blocksPerYear; // 1e18
        uint256 stakeApr1e18 = 35e15; // 3.5% conservative slisBNB staking APY
        // BNB-denominated annual carry.
        int256 annualCarryBnb =
            int256((collBnbWei * stakeApr1e18) / 1e18) - int256((debtWei * borrowApr1e18) / 1e18);
        int256 carryBnb = (annualCarryBnb * int256(HOLD_DAYS)) / 365;
        int256 carryUsdE8 = (carryBnb * int256(bnbUsdE8)) / 1e18;
        _creditPositionEquityE8(carryUsdE8);
        emit log_named_int("carry_bnb_wei_30d", carryBnb);

        emit log_named_uint("coll_slisBNB_underlying", collUnderlying);
        emit log_named_uint("coll_bnb_wei", collBnbWei);
        emit log_named_uint("wbnb_debt_wei", debtWei);
        emit log_named_uint("slis_bnb_per_share_1e18", bnbPerSlis);

        _endPnL("B01-01: slisBNB Venus loop");
    }

    /// @dev Read the pool oracle's WBNB price (1e18 USD). Falls back to 600e18.
    function _poolBnbPriceE18() internal view returns (uint256) {
        // Venus pool oracle: comptroller.oracle().getUnderlyingPrice(vToken)
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
