// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWBNB} from "src/interfaces/bsc/common/IWBNB.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";

/// @notice Minimal Stader StakeManager surface for the BNB -> BNBx mint path.
interface IStaderStakeManager {
    function deposit() external payable;
    function convertBnbXToBnb(uint256 amount) external view returns (uint256);
    function convertBnbToBnbX(uint256 amount) external view returns (uint256);
}

/// @title B01-02 BNBx -> Venus isolated pool -> borrow WBNB -> Stader re-stake loop
/// @notice Same recursive shape as B01-01 but on Stader BNBx in the Venus
///         "Liquid Staked BNB" isolated pool. Supply BNBx (CF 90%), borrow WBNB,
///         unwrap, re-stake via Stader. All addresses verified on-chain.
/// @dev    The Venus *Core* pool does not list BNBx. The isolated
///         "Liquid Staked BNB" pool (Comptroller 0xd9339...) lists vBNBx and a
///         borrowable vWBNB market. The BSC.BNBx constant is a wrong address
///         (no code on-chain); the real BNBx token is pinned as LOCAL_BNBX.
contract B01_02_BNBxVenusStaderLoopTest is BSCStrategyBase {
    /// @dev Block where the Stader StakeManager deposit() is NOT paused AND the
    ///      Venus Liquid-Staked-BNB isolated pool lists vBNBx/vWBNB. At 42M+ the
    ///      Stader manager's deposit() is Pausable-paused, so we pin 38M.
    uint256 internal constant FORK_BLOCK = 38_000_000;

    /// @dev Stader BNBx StakeManager (active deposit() mint path). Verified
    ///      on-chain (deposit unpaused at FORK_BLOCK; convertBnbXToBnb ~1.085).
    address internal constant LOCAL_STADER_STAKE_MANAGER = 0x7276241a669489E4BBB76f63d2A43Bfe63080F2F;
    /// @dev Real Stader BNBx ERC20 (BSC.BNBx constant has no code on-chain).
    address internal constant LOCAL_BNBX = 0x1bdd3Cf7F79cfB8EdbB955f20ad99211551BA275;

    /// @dev Venus isolated "Liquid Staked BNB" pool Comptroller.
    address internal constant LOCAL_LSB_COMPTROLLER = 0xd933909A4a2b7A4638903028f44D1d38ce27c352;
    /// @dev vBNBx market (underlying = BNBx) in the Liquid-Staked-BNB pool.
    address internal constant LOCAL_VBNBX = 0x5E21bF67a6af41c74C1773E4b473ca5ce8fd3791;
    /// @dev vWBNB market (underlying = WBNB) in the Liquid-Staked-BNB pool.
    address internal constant LOCAL_VWBNB = 0xe10E80B7FD3a29fE46E16C30CC8F4dd938B742e2;

    uint256 internal constant PRINCIPAL_BNB = 10 ether;
    uint256 internal constant ITERATIONS = 4;
    uint256 internal constant SAFETY_BPS = 8_000;
    uint256 internal constant HOLD_DAYS = 30;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.WBNB);
        _trackToken(LOCAL_BNBX);
    }

    function testStrategy_B01_02() public {
        vm.deal(address(this), PRINCIPAL_BNB);
        _startPnL();

        IVenusComptroller comp = IVenusComptroller(LOCAL_LSB_COMPTROLLER);
        address[] memory markets = new address[](2);
        markets[0] = LOCAL_VBNBX;
        markets[1] = LOCAL_VWBNB;
        comp.enterMarkets(markets);

        IStaderStakeManager stader = IStaderStakeManager(LOCAL_STADER_STAKE_MANAGER);
        IERC20 bnbx = IERC20(LOCAL_BNBX);
        IVToken vBNBx = IVToken(LOCAL_VBNBX);
        IVToken vWBNB = IVToken(LOCAL_VWBNB);
        IWBNB wbnb = IWBNB(BSC.WBNB);

        bnbx.approve(LOCAL_VBNBX, type(uint256).max);

        uint256 bnbToStake = address(this).balance;

        for (uint256 i = 0; i < ITERATIONS; i++) {
            stader.deposit{value: bnbToStake}();
            uint256 bnbxBal = bnbx.balanceOf(address(this));
            require(vBNBx.mint(bnbxBal) == 0, "vBNBx mint failed");

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
            stader.deposit{value: address(this).balance}();
            uint256 finalBnbx = bnbx.balanceOf(address(this));
            if (finalBnbx > 0) require(vBNBx.mint(finalBnbx) == 0, "final vBNBx mint failed");
        }

        // Position equity at entry (see B01-01 for why we do not warp-accrue).
        uint256 debtWei = vWBNB.borrowBalanceCurrent(address(this));
        uint256 collBnbx = vBNBx.balanceOfUnderlying(address(this)); // BNBx units
        uint256 collBnbWei = stader.convertBnbXToBnb(collBnbx); // BNB value

        uint256 bnbUsdE8 = 600e8;
        int256 collUsdE8 = int256((collBnbWei * bnbUsdE8) / 1e18);
        int256 debtUsdE8 = int256((debtWei * bnbUsdE8) / 1e18);
        _creditPositionEquityE8(collUsdE8 - debtUsdE8);

        // Projected 30-day carry: stake yield on full collateral minus WBNB
        // borrow APR on debt (live IRM rate).
        uint256 blocksPerYear = 365 days / 3;
        uint256 borrowApr1e18 = vWBNB.borrowRatePerBlock() * blocksPerYear;
        uint256 stakeApr1e18 = 4e16; // 4% Stader BNBx staking APY (conservative)
        int256 annualCarryBnb =
            int256((collBnbWei * stakeApr1e18) / 1e18) - int256((debtWei * borrowApr1e18) / 1e18);
        int256 carryBnb = (annualCarryBnb * int256(HOLD_DAYS)) / 365;
        _creditPositionEquityE8((carryBnb * int256(bnbUsdE8)) / 1e18);

        emit log_named_uint("coll_bnb_wei", collBnbWei);
        emit log_named_uint("wbnb_debt_wei", debtWei);
        emit log_named_int("carry_bnb_wei_30d", carryBnb);

        _endPnL("B01-02: BNBx Venus iso loop");
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
