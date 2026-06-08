// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWBNB} from "src/interfaces/bsc/common/IWBNB.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {IWombatPool} from "src/interfaces/bsc/amm/IWombatPool.sol";
import {console2} from "forge-std/console2.sol";

interface IStaderStakeManager {
    function deposit() external payable;
    function convertBnbXToBnb(uint256 amount) external view returns (uint256);
    function convertBnbToBnbX(uint256 amount) external view returns (uint256);
}

/// @title B01-07 BNBx -> Venus iso pool -> borrow WBNB -> Wombat WBNB/BNBx recycle (3-mech)
/// @notice Three-mechanism stack:
///         1. Stader BNBx - mint LST from BNB.
///         2. Venus "Liquid Staked BNB" isolated pool - supply BNBx, borrow WBNB.
///         3. Wombat BNBx/WBNB pool - recycle the borrowed WBNB into BNBx via
///            the Wombat swap (instead of a slow Stader re-mint), extracting any
///            Wombat asset-weight skew. Falls back to Stader mint if Wombat is
///            unprofitable.
/// @dev    The original PoC targeted "Lista Lending", whose address/ABI are
///         unverifiable on-chain (placeholder has no code; the Aave-style
///         IListaLending ABI does not match Lista's deployed market). Per the
///         playbook (point 4) the BNBx-collateral lending leg is routed through
///         the on-chain-verified Venus isolated vBNBx market; the Wombat recycle
///         discriminator is preserved. Wombat BNBx pool 0x8df1... verified.
contract B01_07_BNBxListaWombatRecycleLoopTest is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 40_000_000;

    address internal constant LOCAL_STADER_STAKE_MANAGER = 0x7276241a669489E4BBB76f63d2A43Bfe63080F2F;
    address internal constant LOCAL_BNBX = 0x1bdd3Cf7F79cfB8EdbB955f20ad99211551BA275;

    address internal constant LOCAL_LSB_COMPTROLLER = 0xd933909A4a2b7A4638903028f44D1d38ce27c352;
    address internal constant LOCAL_VBNBX = 0x5E21bF67a6af41c74C1773E4b473ca5ce8fd3791;
    address internal constant LOCAL_VWBNB = 0xe10E80B7FD3a29fE46E16C30CC8F4dd938B742e2;

    /// @dev Wombat BNBx/WBNB pool (verified: has BNBx + WBNB assets, live quotes).
    address internal constant LOCAL_WOMBAT_BNBX_POOL = 0x8df1126de13bcfef999556899F469d64021adBae;

    uint256 internal constant PRINCIPAL_BNB = 10 ether;
    uint256 internal constant ITERATIONS = 4;
    uint256 internal constant SAFETY_BPS = 8_000;
    uint256 internal constant HOLD_DAYS = 30;
    uint256 internal constant WOMBAT_MIN_EDGE_BPS = 5;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.WBNB);
        _trackToken(LOCAL_BNBX);
    }

    function testStrategy_B01_07() public {
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
        IWombatPool wombat = IWombatPool(LOCAL_WOMBAT_BNBX_POOL);

        bnbx.approve(LOCAL_VBNBX, type(uint256).max);
        wbnb.approve(LOCAL_WOMBAT_BNBX_POOL, type(uint256).max);

        // Initial: BNB -> BNBx via Stader, supply to Venus iso pool.
        stader.deposit{value: PRINCIPAL_BNB}();
        require(vBNBx.mint(bnbx.balanceOf(address(this))) == 0, "vBNBx mint init failed");

        uint256 wombatHops;
        for (uint256 i = 0; i < ITERATIONS; i++) {
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
            uint256 wbnbBal = IERC20(BSC.WBNB).balanceOf(address(this));
            if (wbnbBal == 0) break;

            // Compare Wombat swap vs Stader re-mint for WBNB -> BNBx.
            uint256 staderBnbx = stader.convertBnbToBnbX(wbnbBal);
            uint256 wombatBnbx;
            try wombat.quotePotentialSwap(BSC.WBNB, LOCAL_BNBX, wbnbBal) returns (uint256 o, uint256) {
                wombatBnbx = o;
            } catch {
                wombatBnbx = 0;
            }

            uint256 minEdge = (staderBnbx * (10_000 + WOMBAT_MIN_EDGE_BPS)) / 10_000;
            if (wombatBnbx >= minEdge) {
                wombat.swap(
                    BSC.WBNB,
                    LOCAL_BNBX,
                    wbnbBal,
                    (wombatBnbx * 9_990) / 10_000,
                    address(this),
                    block.timestamp + 1
                );
                wombatHops++;
            } else {
                // Fallback: unwrap and Stader re-mint.
                wbnb.withdraw(wbnbBal);
                stader.deposit{value: address(this).balance}();
            }

            uint256 freshBnbx = bnbx.balanceOf(address(this));
            if (freshBnbx == 0) break;
            require(vBNBx.mint(freshBnbx) == 0, "vBNBx mint loop failed");
        }

        // ---- Position equity at entry (1e8 USD). ----
        uint256 debtWei = vWBNB.borrowBalanceCurrent(address(this));
        uint256 collBnbx = vBNBx.balanceOfUnderlying(address(this));
        uint256 collBnbWei = stader.convertBnbXToBnb(collBnbx);

        uint256 bnbUsdE8 = 600e8;
        int256 collUsdE8 = int256((collBnbWei * bnbUsdE8) / 1e18);
        int256 debtUsdE8 = int256((debtWei * bnbUsdE8) / 1e18);
        _creditPositionEquityE8(collUsdE8 - debtUsdE8);

        // Projected 30-day carry: BNBx stake yield on collateral minus WBNB
        // borrow APR on debt (live IRM rate).
        uint256 blocksPerYear = 365 days / 3;
        uint256 borrowApr1e18 = vWBNB.borrowRatePerBlock() * blocksPerYear;
        uint256 stakeApr1e18 = 4e16;
        int256 annualCarryBnb =
            int256((collBnbWei * stakeApr1e18) / 1e18) - int256((debtWei * borrowApr1e18) / 1e18);
        int256 carryBnb = (annualCarryBnb * int256(HOLD_DAYS)) / 365;
        _creditPositionEquityE8((carryBnb * int256(bnbUsdE8)) / 1e18);

        emit log_named_uint("wombat_hops", wombatHops);
        emit log_named_uint("coll_bnb_wei", collBnbWei);
        emit log_named_uint("wbnb_debt_wei", debtWei);
        emit log_named_int("carry_bnb_wei_30d", carryBnb);

        _endPnL("B01-07: BNBx Venus + Wombat recycle");
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
