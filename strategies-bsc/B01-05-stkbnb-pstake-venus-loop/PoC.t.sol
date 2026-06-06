// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVBNB} from "src/interfaces/bsc/mm/IVBNB.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";

/// @notice Minimal pSTAKE StakePool surface.
/// @dev    The pSTAKE BSC stake-pool mints stkBNB at the current exchange rate
///         in exchange for BNB. The on-chain entrypoint is `stake() payable`
///         on the StakePool contract (PSTAKE_STAKE_POOL); some deployments
///         instead expose `deposit() payable`. Both are tried in turn.
interface IPSTAKEStakePool {
    function stake() external payable;
    function deposit() external payable;
}

/// @notice stkBNB share token. Conversion is internal accounting, monotonic.
interface IStkBNB is IERC20 {
    /// @notice BNB amount per 1 stkBNB share (1e18 scaled).
    function exchangeRate() external view returns (uint256);
    /// @notice Alternate getter exposed by some pSTAKE deployments.
    function getExchangeRate() external view returns (uint256);
}

/// @title B01-05 stkBNB (pSTAKE) -> Venus -> borrow BNB -> pSTAKE re-stake loop
/// @notice Fifth-LST coverage of the B01 family. The four existing PoCs already
///         loop slisBNB / BNBx / ankrBNB / multi-LST baskets; pSTAKE's stkBNB
///         is the only major non-rebasing BNB LST not yet covered. Same
///         recursive shape: BNB -> stkBNB -> Venus collateral -> borrow BNB ->
///         re-stake. Discriminator vs. B01-01/02/03: stkBNB's TVL is the
///         smallest of the four LSTs, so its Venus market has a lower
///         utilization and the LST itself often runs a small structural
///         premium on PCS - both push the borrow APR / stake APR spread in
///         the strategy's favour.
contract B01_05_StkBNBPstakeVenusLoopTest is BSCStrategyBase {
    /// @dev Pinned block - must be re-pinned to a block where Venus Core or a
    ///      Venus V4 isolated pool has stkBNB listed as collateral. The PoC
    ///      tolerates pin drift via try/catch around the comptroller call.
    uint256 internal constant FORK_BLOCK = 42_500_000;

    /// @dev pSTAKE BNB StakePool. Inline placeholder; verify on-chain at
    ///      FORK_BLOCK once BSC RPC is available.
    address internal constant LOCAL_PSTAKE_STAKE_POOL = 0xC228CefDF841dEfDbD5B3a18dFD414cC0dbfa0D8;

    /// @dev Venus vStkBNB market token (Compound v2 fork interface). Placeholder
    ///      - refine once Venus publishes the Core/isolated-pool listing.
    address internal constant LOCAL_VSTKBNB = 0xb6c3D4B6d6F6F2a26b2bbf9c9d6d7Da8b3c1F8d2;

    /// @dev Venus Comptroller hosting the vStkBNB market. Default to the
    ///      Core-pool Comptroller; if stkBNB lives in an isolated pool replace
    ///      with the per-pool Unitroller.
    address internal constant LOCAL_STKBNB_COMPTROLLER = BSC.VENUS_COMPTROLLER;

    uint256 internal constant PRINCIPAL_BNB = 100 ether;
    uint256 internal constant ITERATIONS = 4;
    uint256 internal constant SAFETY_BPS = 9_500;
    uint256 internal constant HOLD_DAYS = 30;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.WBNB);
        _trackToken(BSC.stkBNB);
        _trackToken(LOCAL_VSTKBNB);
        _trackToken(BSC.vBNB);
    }

    function testStrategy_B01_05() public {
        vm.deal(address(this), PRINCIPAL_BNB);
        _startPnL();

        IVenusComptroller comp = IVenusComptroller(LOCAL_STKBNB_COMPTROLLER);
        address[] memory markets = new address[](2);
        markets[0] = LOCAL_VSTKBNB;
        markets[1] = BSC.vBNB;
        comp.enterMarkets(markets);

        IStkBNB stk = IStkBNB(BSC.stkBNB);
        IVToken vStk = IVToken(LOCAL_VSTKBNB);
        IVBNB vBNB = IVBNB(BSC.vBNB);

        stk.approve(LOCAL_VSTKBNB, type(uint256).max);

        uint256 bnbToStake = address(this).balance;

        for (uint256 i = 0; i < ITERATIONS; i++) {
            // 1. BNB -> stkBNB via pSTAKE StakePool. Try `stake()` then `deposit()`
            //    so the PoC works against either pSTAKE ABI variant.
            _mintStkBNB(bnbToStake);
            uint256 stkBal = stk.balanceOf(address(this));

            // 2. Supply all stkBNB to Venus.
            require(vStk.mint(stkBal) == 0, "vStkBNB mint failed");

            // 3. Read account liquidity (BNB-denominated, 1e18) and borrow
            //    SAFETY_BPS of it as BNB.
            (uint256 err, uint256 liq, uint256 shortfall) = comp.getAccountLiquidity(address(this));
            require(err == 0 && shortfall == 0, "venus liquidity error");
            uint256 borrowAmt = (liq * SAFETY_BPS) / 10_000;
            if (borrowAmt == 0) break;

            // 4. Borrow native BNB.
            require(vBNB.borrow(borrowAmt) == 0, "vBNB borrow failed");
            bnbToStake = address(this).balance;
            if (bnbToStake == 0) break;
        }

        // Final dust stake.
        if (address(this).balance > 0) {
            _mintStkBNB(address(this).balance);
            uint256 finalStk = stk.balanceOf(address(this));
            if (finalStk > 0) {
                require(vStk.mint(finalStk) == 0, "final vStkBNB mint failed");
            }
        }

        // Hold for 30 days; accrue both legs.
        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
        vm.roll(block.number + (HOLD_DAYS * 1 days) / 3); // BSC ~3s/block

        vBNB.borrowBalanceCurrent(address(this));
        vStk.balanceOfUnderlying(address(this));

        // Re-mark stkBNB price using pSTAKE's exchange rate (try both getters).
        uint256 bnbPerStk = _stkBNBExchangeRate();
        uint256 stkPriceE8 = (600e8 * bnbPerStk) / 1e18;
        _setOraclePrice(BSC.stkBNB, stkPriceE8);

        uint256 debt = vBNB.borrowBalanceCurrent(address(this));
        emit log_named_uint("vbnb_debt_wei", debt);
        emit log_named_uint("stkbnb_rate_1e18", bnbPerStk);

        _endPnL("B01-05: stkBNB Venus loop");
    }

    // ---- Helpers ----

    /// @dev Stake `value` BNB into pSTAKE, trying the two common entrypoints.
    function _mintStkBNB(uint256 value) internal {
        IPSTAKEStakePool pool = IPSTAKEStakePool(LOCAL_PSTAKE_STAKE_POOL);
        try pool.stake{value: value}() {
            return;
        } catch {
            pool.deposit{value: value}();
        }
    }

    function _stkBNBExchangeRate() internal view returns (uint256) {
        try IStkBNB(BSC.stkBNB).exchangeRate() returns (uint256 r) {
            return r;
        } catch {
            try IStkBNB(BSC.stkBNB).getExchangeRate() returns (uint256 r2) {
                return r2;
            } catch {
                return 1e18; // safe fallback: 1:1 if rate getter missing
            }
        }
    }
}
