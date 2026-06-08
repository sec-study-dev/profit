// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWBNB} from "src/interfaces/bsc/common/IWBNB.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";

/// @notice Minimal pSTAKE StakePool surface. BNB -> stkBNB mint via deposit(),
///         and exchangeRate() returns (totalWei, poolTokenSupply).
interface IPSTAKEStakePool {
    function stake() external payable;
    function deposit() external payable;
    function exchangeRate() external view returns (uint256 totalWei, uint256 poolTokenSupply);
}

/// @notice ERC1820 registry (stkBNB is an ERC777 token and requires the
///         recipient to register an ERC777TokensRecipient implementer).
interface IERC1820Registry {
    function setInterfaceImplementer(address account, bytes32 interfaceHash, address implementer)
        external;
}

/// @title B01-05 stkBNB (pSTAKE) -> Venus iso pool -> borrow WBNB -> pSTAKE re-stake loop
/// @notice Fifth-LST coverage of the B01 family on pSTAKE stkBNB. Same recursive
///         shape: BNB -> stkBNB -> Venus collateral (Liquid-Staked-BNB isolated
///         pool, CF 87%) -> borrow WBNB -> unwrap -> re-stake.
/// @dev    stkBNB is NOT on Venus Core; it is in the isolated "Liquid Staked BNB"
///         pool (Comptroller 0xd9339...) where borrows are WBNB. Addresses
///         verified on-chain at FORK_BLOCK.
contract B01_05_StkBNBPstakeVenusLoopTest is BSCStrategyBase {
    /// @dev Block where vstkBNB supply (mint) is NOT action-paused AND pSTAKE
    ///      deposit() is live. At 36M/44M+ vstkBNB minting is paused.
    uint256 internal constant FORK_BLOCK = 40_000_000;

    /// @dev pSTAKE BNB StakePool (deposit() mint path verified unpaused).
    address internal constant LOCAL_PSTAKE_STAKE_POOL = 0xC228CefDF841dEfDbD5B3a18dFD414cC0dbfa0D8;

    /// @dev Venus isolated "Liquid Staked BNB" pool Comptroller.
    address internal constant LOCAL_LSB_COMPTROLLER = 0xd933909A4a2b7A4638903028f44D1d38ce27c352;
    /// @dev vstkBNB market (underlying = stkBNB) in the Liquid-Staked-BNB pool.
    address internal constant LOCAL_VSTKBNB = 0xcc5D9e502574cda17215E70bC0B4546663785227;
    /// @dev vWBNB market (underlying = WBNB) in the Liquid-Staked-BNB pool.
    address internal constant LOCAL_VWBNB = 0xe10E80B7FD3a29fE46E16C30CC8F4dd938B742e2;

    /// @dev Principal sized to the vstkBNB supply-cap headroom (~9 stkBNB free
    ///      of a 50-stkBNB cap at the fork block). 2 BNB principal levered ~3x
    ///      stays under the cap.
    uint256 internal constant PRINCIPAL_BNB = 2 ether;
    uint256 internal constant ITERATIONS = 4;
    uint256 internal constant SAFETY_BPS = 8_000;
    uint256 internal constant HOLD_DAYS = 30;

    /// @dev ERC1820 canonical registry address (same on all chains).
    IERC1820Registry internal constant ERC1820 =
        IERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24);
    bytes32 internal constant ERC777_RECIPIENT_HASH =
        keccak256("ERC777TokensRecipient");

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.WBNB);
        _trackToken(BSC.stkBNB);
        // stkBNB is ERC777: register this contract as its own recipient hook
        // implementer so deposit()-minted stkBNB can be received.
        ERC1820.setInterfaceImplementer(address(this), ERC777_RECIPIENT_HASH, address(this));
    }

    /// @dev ERC777 recipient hook (no-op; required to receive stkBNB).
    function tokensReceived(
        address,
        address,
        address,
        uint256,
        bytes calldata,
        bytes calldata
    ) external pure {}

    function testStrategy_B01_05() public {
        vm.deal(address(this), PRINCIPAL_BNB);
        _startPnL();

        IVenusComptroller comp = IVenusComptroller(LOCAL_LSB_COMPTROLLER);
        address[] memory markets = new address[](2);
        markets[0] = LOCAL_VSTKBNB;
        markets[1] = LOCAL_VWBNB;
        comp.enterMarkets(markets);

        IERC20 stk = IERC20(BSC.stkBNB);
        IVToken vStk = IVToken(LOCAL_VSTKBNB);
        IVToken vWBNB = IVToken(LOCAL_VWBNB);
        IWBNB wbnb = IWBNB(BSC.WBNB);

        stk.approve(LOCAL_VSTKBNB, type(uint256).max);

        uint256 bnbToStake = address(this).balance;

        for (uint256 i = 0; i < ITERATIONS; i++) {
            _mintStkBNB(bnbToStake);
            uint256 stkBal = stk.balanceOf(address(this));
            uint256 supplyAmt = _capToHeadroom(vStk, stkBal);
            if (supplyAmt == 0) break;
            require(vStk.mint(supplyAmt) == 0, "vStkBNB mint failed");

            (uint256 err, uint256 liq, uint256 shortfall) = comp.getAccountLiquidity(address(this));
            require(err == 0 && shortfall == 0, "venus liquidity error");
            if (liq == 0) break;

            uint256 wbnbPriceE18 = _poolBnbPriceE18();
            uint256 borrowAmt = (liq * SAFETY_BPS) / 10_000;
            if (wbnbPriceE18 > 0) borrowAmt = (borrowAmt * 1e18) / wbnbPriceE18;
            uint256 cash = vWBNB.getCash();
            if (borrowAmt > (cash * 9) / 10) borrowAmt = (cash * 9) / 10;
            if (borrowAmt == 0) break;

            require(vWBNB.borrow(borrowAmt) == 0, "vWBNB borrow failed");
            wbnb.withdraw(wbnb.balanceOf(address(this)));
            bnbToStake = address(this).balance;
            if (bnbToStake == 0) break;
        }

        if (address(this).balance > 0) {
            _mintStkBNB(address(this).balance);
            uint256 finalStk = _capToHeadroom(vStk, stk.balanceOf(address(this)));
            if (finalStk > 0) require(vStk.mint(finalStk) == 0, "final vStkBNB mint failed");
        }

        // Position equity at entry (see B01-01 for why we do not warp-accrue).
        uint256 debtWei = vWBNB.borrowBalanceCurrent(address(this));
        uint256 collStk = vStk.balanceOfUnderlying(address(this)); // stkBNB units
        uint256 bnbPerStk = _stkBNBRate1e18();
        uint256 collBnbWei = (collStk * bnbPerStk) / 1e18;

        uint256 bnbUsdE8 = 600e8;
        int256 collUsdE8 = int256((collBnbWei * bnbUsdE8) / 1e18);
        int256 debtUsdE8 = int256((debtWei * bnbUsdE8) / 1e18);
        _creditPositionEquityE8(collUsdE8 - debtUsdE8);

        // Projected 30-day carry: stake yield on collateral minus WBNB borrow APR.
        uint256 blocksPerYear = 365 days / 3;
        uint256 borrowApr1e18 = vWBNB.borrowRatePerBlock() * blocksPerYear;
        uint256 stakeApr1e18 = 4e16; // 4% stkBNB staking APY (conservative)
        int256 annualCarryBnb =
            int256((collBnbWei * stakeApr1e18) / 1e18) - int256((debtWei * borrowApr1e18) / 1e18);
        int256 carryBnb = (annualCarryBnb * int256(HOLD_DAYS)) / 365;
        _creditPositionEquityE8((carryBnb * int256(bnbUsdE8)) / 1e18);

        emit log_named_uint("coll_bnb_wei", collBnbWei);
        emit log_named_uint("wbnb_debt_wei", debtWei);
        emit log_named_int("carry_bnb_wei_30d", carryBnb);

        _endPnL("B01-05: stkBNB Venus loop");
    }

    /// @dev Cap a desired supply amount to the vToken's remaining supply-cap
    ///      headroom (cap - totalSupplyUnderlying), leaving a small buffer.
    function _capToHeadroom(IVToken v, uint256 want) internal returns (uint256) {
        (bool ok, bytes memory d) = LOCAL_LSB_COMPTROLLER.staticcall(
            abi.encodeWithSignature("supplyCaps(address)", address(v))
        );
        if (!ok || d.length < 32) return want;
        uint256 cap = abi.decode(d, (uint256));
        if (cap == 0) return want; // 0 = unlimited
        // current supplied underlying = cash + borrows - reserves (approx cash+borrows)
        uint256 supplied = v.getCash() + v.totalBorrows();
        if (supplied >= cap) return 0;
        uint256 headroom = cap - supplied;
        // leave 1% buffer to avoid rounding-induced cap breach
        headroom = (headroom * 99) / 100;
        return want > headroom ? headroom : want;
    }

    function _mintStkBNB(uint256 value) internal {
        // pSTAKE rejects deposits with sub-1e12-wei dust (DustNotAllowed).
        // Round down to a clean 1e12 multiple; the dust stays as native BNB.
        value = (value / 1e12) * 1e12;
        if (value == 0) return;
        IPSTAKEStakePool pool = IPSTAKEStakePool(LOCAL_PSTAKE_STAKE_POOL);
        try pool.deposit{value: value}() {
            return;
        } catch {
            pool.stake{value: value}();
        }
    }

    function _stkBNBRate1e18() internal view returns (uint256) {
        (uint256 totalWei, uint256 supply) = IPSTAKEStakePool(LOCAL_PSTAKE_STAKE_POOL).exchangeRate();
        if (supply == 0) return 1e18;
        return (totalWei * 1e18) / supply;
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
