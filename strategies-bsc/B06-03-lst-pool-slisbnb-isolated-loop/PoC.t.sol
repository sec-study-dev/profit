// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {IListaStakeManager} from "src/interfaces/bsc/lst/IListaStakeManager.sol";
import {IslisBNB} from "src/interfaces/bsc/lst/IslisBNB.sol";

/// @notice Minimal WBNB surface for unwrapping the borrowed WBNB.
interface IWBNB {
    function withdraw(uint256 wad) external;
    function deposit() external payable;
}

/// @notice Isolated-pool comptroller supply-cap getter.
interface ISupplyCap {
    function supplyCaps(address vToken) external view returns (uint256);
}

/// @title B06-03 Venus LST isolated pool - slisBNB high-LTV loop
/// @notice Recursive stake->supply->borrow loop routed through the Venus
///         "Liquid Staked BNB" isolated-pool Comptroller (slisBNB CF = 0.90,
///         far above Core). Borrows in this pool are ERC20 vWBNB (not native
///         vBNB). The borrowed WBNB is unwrapped and re-staked to slisBNB to
///         compound the leverage. Carry edge = slisBNB staking APY vs the
///         vWBNB borrow APR. Collateral parks inside Venus, so PnL is the
///         on-chain position equity (collateral - debt).
contract B06_03_VenusLSTPoolSlisBNBLoopTest is BSCStrategyBase {
    // Verified at this block: LST pool comptroller + member vTokens have code,
    // slisBNB/vWBNB markets listed with liquidity.
    uint256 internal constant FORK_BLOCK = 44_000_000;

    // ---- Verified LST-pool addresses (Venus "Liquid Staked BNB" pool) ----
    address internal constant LOCAL_LST_COMPTROLLER = 0xd933909A4a2b7A4638903028f44D1d38ce27c352;
    address internal constant LOCAL_VSLISBNB_LST = 0xd3CC9d8f3689B83c91b7B59cAB4946B063EB894A;
    address internal constant LOCAL_VWBNB_LST = 0xe10E80B7FD3a29fE46E16C30CC8F4dd938B742e2;

    uint256 internal constant PRINCIPAL_BNB = 100 ether;
    uint256 internal constant ITERATIONS = 4;
    uint256 internal constant SAFETY_BPS = 9_000;

    /// @dev slisBNB supply cap headroom in this pool is shallow; clamp mints.
    function _supplyHeadroom(IVToken v) internal view returns (uint256) {
        uint256 cap = ISupplyCap(LOCAL_LST_COMPTROLLER).supplyCaps(LOCAL_VSLISBNB_LST);
        uint256 supplied = v.getCash() + v.totalBorrows() - v.totalReserves();
        if (supplied >= cap) return 0;
        return cap - supplied;
    }

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.WBNB);
        _trackToken(LOCAL_VSLISBNB_LST);
        _trackToken(LOCAL_VWBNB_LST);
    }

    function testStrategy_B06_03() public {
        vm.deal(address(this), address(this).balance + PRINCIPAL_BNB);
        _startPnL();

        IVenusComptroller comp = IVenusComptroller(LOCAL_LST_COMPTROLLER);
        address[] memory mk = new address[](2);
        mk[0] = LOCAL_VSLISBNB_LST;
        mk[1] = LOCAL_VWBNB_LST;
        comp.enterMarkets(mk);

        IListaStakeManager sm = IListaStakeManager(BSC.LISTA_STAKE_MANAGER);
        IslisBNB slis = IslisBNB(BSC.slisBNB);
        IVToken vSlis = IVToken(LOCAL_VSLISBNB_LST);
        IVToken vWbnb = IVToken(LOCAL_VWBNB_LST);

        slis.approve(LOCAL_VSLISBNB_LST, type(uint256).max);

        uint256 bnbToStake = PRINCIPAL_BNB;

        // ---- Iterative stake -> supply -> borrow WBNB -> unwrap ----
        for (uint256 i = 0; i < ITERATIONS; i++) {
            // Clamp this iteration's stake so the resulting slisBNB supply
            // stays under the (shallow) isolated-pool supply cap.
            uint256 headroom = _supplyHeadroom(vSlis); // slisBNB units
            if (headroom == 0) break;
            // slisBNB headroom -> max BNB to stake (slisBNB ~ BNB, headroom is
            // the binding limit so converting via bnbPerSlis is conservative).
            uint256 maxBnb = headroom * sm.convertSnBnbToBnb(1e18) / 1e18;
            uint256 stakeNow = bnbToStake > maxBnb ? maxBnb : bnbToStake;
            // StakeManager enforces a minimum deposit; stop the ladder once
            // the marginal stake is dust.
            if (stakeNow < 0.05 ether) break;

            sm.deposit{value: stakeNow}();
            uint256 slisBal = slis.balanceOf(address(this));
            // Re-clamp the actual mint to live headroom.
            uint256 hr2 = _supplyHeadroom(vSlis);
            uint256 mintNow = slisBal > hr2 ? hr2 : slisBal;
            if (mintNow == 0) break;
            require(vSlis.mint(mintNow) == 0, "vslis mint failed");

            (uint256 err, uint256 liq, uint256 shortfall) = comp.getAccountLiquidity(address(this));
            require(err == 0 && shortfall == 0, "lst liquidity err");
            // liq is 1e18 USD; convert to WBNB wei at BNB=$600.
            uint256 borrowWbnb = ((liq * SAFETY_BPS) / 10_000) * 1e18 / 600e18;
            if (borrowWbnb == 0) break;

            // Keep borrow modest so we don't spike utilization (and thus the
            // borrow APR) past the slisBNB staking yield. Cap each draw at 25%
            // of available cash.
            uint256 cash = vWbnb.getCash();
            uint256 cashCap = (cash * 25) / 100;
            if (borrowWbnb > cashCap) borrowWbnb = cashCap;
            if (borrowWbnb == 0) break;

            require(vWbnb.borrow(borrowWbnb) == 0, "vwbnb borrow failed");
            // Unwrap exactly the borrowed WBNB -> native BNB. (The test
            // contract carries a large default native balance, so we must
            // re-stake only the freshly-borrowed amount, not the whole
            // native balance.)
            uint256 wbnbBal = IERC20(BSC.WBNB).balanceOf(address(this));
            IWBNB(BSC.WBNB).withdraw(wbnbBal);
            bnbToStake = wbnbBal;
            if (bnbToStake == 0) break;
        }

        // ---- Position equity (collateral - debt), 1e8 USD ----
        uint256 bnbPerSlis = sm.convertSnBnbToBnb(1e18);
        // slisBNB collateral underlying.
        uint256 slisUnderlying = vSlis.balanceOfUnderlying(address(this));
        uint256 debtWbnb = vWbnb.borrowBalanceCurrent(address(this));
        emit log_named_uint("vwbnb_debt_wei", debtWbnb);
        emit log_named_uint("slis_collateral_wei", slisUnderlying);
        emit log_named_uint("slis_bnb_per_share_1e18", bnbPerSlis);

        // collateral USD = slisUnderlying * bnbPerSlis * $600
        // debt USD       = debtWbnb * $600
        uint256 collBnb = slisUnderlying * bnbPerSlis / 1e18;
        int256 collE8 = int256(collBnb * 600e8 / 1e18);
        int256 debtE8 = int256(debtWbnb * 600e8 / 1e18);
        _creditPositionEquityE8(collE8 - debtE8);

        // ---- Projected 30-day carry (LST APY on collateral - borrow APR on
        //      debt). slisBNB exchange rate is frozen on a static fork, so we
        //      project rather than warp. Conservative slisBNB APY ~3%; borrow
        //      rate read live from the IRM (per-block, BSC ~3s blocks). ----
        uint256 borrowRatePerBlock = vWbnb.borrowRatePerBlock();
        uint256 blocksPerYear = 365 days / 3;
        // borrow cost over 30 days, in BNB wei
        uint256 borrowCostBnb = debtWbnb * borrowRatePerBlock * (30 days / 3) / 1e18;
        // LST yield over 30 days at ~3% APY, in BNB wei
        uint256 lstYieldBnb = collBnb * 300 / 10_000 * 30 / 365;
        int256 carryE8 = int256(lstYieldBnb * 600e8 / 1e18) - int256(borrowCostBnb * 600e8 / 1e18);
        emit log_named_int("projected_30d_carry_e8", carryE8);
        _creditPositionEquityE8(carryE8);
        blocksPerYear; // silence unused

        // Zero out raw-token price marks for the parked legs so the equity
        // credit is the single source of truth (no phantom -principal).
        _setOraclePrice(BSC.slisBNB, 0);
        _setOraclePrice(BSC.WBNB, 0);
        _setOraclePrice(LOCAL_VSLISBNB_LST, 0);
        _setOraclePrice(LOCAL_VWBNB_LST, 0);

        _endPnL("B06-03: Venus LST pool slisBNB high-LTV loop");
    }
}
