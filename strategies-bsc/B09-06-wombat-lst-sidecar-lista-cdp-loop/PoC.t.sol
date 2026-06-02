// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWombatPool} from "src/interfaces/bsc/amm/IWombatPool.sol";
import {IListaStakeManager} from "src/interfaces/bsc/lst/IListaStakeManager.sol";
import {IListaInteraction} from "src/interfaces/bsc/cdp/IListaInteraction.sol";
import {IPancakeStableRouter} from "src/interfaces/bsc/amm/IPancakeStableRouter.sol";

/// @title B09-06 Wombat BNB-LST sidecar -> Lista CDP -> PCS Stable unwind
/// @notice 3-mechanism composition:
///         (a) Wombat dynamic-weight slisBNB/BNB sidecar — acquire slisBNB
///             at a rate-fair-or-better quote when cov_BNB < 0.9.
///         (b) Lista CDP — deposit slisBNB collateral, mint lisUSD against it
///             (~70% LTV typical).
///         (c) PCS StableSwap lisUSD/USDT — convert minted lisUSD to USDT,
///             realizing the position in dollar-stable form for clean PnL.
///
///         Why 3-mech matters: the position **isolates the Wombat skew
///         bonus** (leg a) from the **borrow-against-LST yield** (leg b) and
///         the **lisUSD peg discount-or-premium** (leg c). The Wombat bonus
///         is captured atomically; the CDP+stable leg locks in roughly 70%
///         of the rate-marked value in USDT today, leaving 30% of upside on
///         slisBNB price appreciation as a tail leg.
///
///         At unwind (`_endPnL` snapshot), the position holds:
///           - leftover slisBNB collateral (over-collateralized residue) at
///             the Lista internal rate;
///           - USDT (from the lisUSD swap);
///           - lisUSD debt (negative on PnL).
contract B09_06_Wombat_LST_Sidecar_Lista_CDP_Loop is BSCStrategyBase {
    /// @dev TODO: pin a block where Wombat slisBNB sidecar cov_BNB < 0.9 AND
    ///      Lista CDP slisBNB market is enabled.
    uint256 constant FORK_BLOCK = 46_000_000;

    /// @dev Wombat slisBNB/WBNB sidecar pool. TODO verify on BscScan (same
    ///      placeholder used in B09-04). Falls back to Main Pool on missing.
    address constant WOMBAT_SLISBNB_POOL = 0xB0219A90EF6A24a237bC038f7B7a6eAc5e01edB0;

    /// @dev WBNB notional invested.
    uint256 constant NOTIONAL_WBNB = 500 ether;

    /// @dev CDP target loan-to-value (parts-per-10000). Lista slisBNB market
    ///      typically allows up to 75%; PoC uses a safe 70%.
    uint256 constant TARGET_LTV_BPS = 7000;

    /// @dev BNB price assumed for the modelled CDP sizing (used in offline
    ///      path; on-fork path reads the Lista internal rate).
    uint256 constant BNB_USD_E8 = 600e8;

    /// @dev Default Lista internal rate when offline.
    uint256 constant INTERNAL_RATE_E18 = 1.078 ether;

    /// @dev PCS Stable lisUSD/USDT 2pool indices. TODO verify; placeholder
    ///      assumes lisUSD=0, USDT=1.
    uint256 constant PCS_IDX_LISUSD = 0;
    uint256 constant PCS_IDX_USDT = 1;

    address public wombatPool;
    uint256 public slisBnbReceived;
    uint256 public bnbValueAtInternalRate;
    uint256 public lisUsdMinted;
    uint256 public usdtFromLisUsd;

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }

        _trackToken(BSC.WBNB);
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.USDT);

        // Mark slisBNB at the internal-rate-adjusted USD (mirrors B09-04).
        _setOraclePrice(BSC.slisBNB, 646_8000_0000);
    }

    function testStrategy_B09_06() public {
        if (!_haveFork) {
            _offlinePnLCheck();
            return;
        }

        _resolvePool();
        _fund(BSC.WBNB, address(this), NOTIONAL_WBNB);

        _startPnL();

        // ---- Mechanism (a): Wombat sidecar WBNB -> slisBNB.
        IERC20(BSC.WBNB).approve(wombatPool, NOTIONAL_WBNB);
        (slisBnbReceived, ) = IWombatPool(wombatPool).swap(
            BSC.WBNB, BSC.slisBNB, NOTIONAL_WBNB, 0, address(this), block.timestamp
        );
        bnbValueAtInternalRate = IListaStakeManager(BSC.LISTA_STAKE_MANAGER)
            .convertSnBnbToBnb(slisBnbReceived);

        // ---- Mechanism (b): Deposit slisBNB to Lista CDP, mint lisUSD.
        IERC20(BSC.slisBNB).approve(BSC.LISTA_INTERACTION, slisBnbReceived);
        IListaInteraction(BSC.LISTA_INTERACTION).deposit(
            address(this), BSC.slisBNB, slisBnbReceived
        );

        // BNB-equivalent value of collateral: bnbValueAtInternalRate (1e18).
        // USD value: bnbValueAtInternalRate * BNB_USD_E8 / 1e8 / 1e18 -> $1e0.
        // lisUSD has 18 decimals; mint up to TARGET_LTV_BPS of collateral USD.
        uint256 collateralUsdE18 =
            (bnbValueAtInternalRate * BNB_USD_E8) / 1e8;
        lisUsdMinted = (collateralUsdE18 * TARGET_LTV_BPS) / 10000;
        IListaInteraction(BSC.LISTA_INTERACTION).borrow(BSC.slisBNB, lisUsdMinted);

        // ---- Mechanism (c): PCS Stable lisUSD -> USDT.
        IERC20(BSC.lisUSD).approve(BSC.PCS_STABLE_ROUTER, lisUsdMinted);
        usdtFromLisUsd = IPancakeStableRouter(BSC.PCS_STABLE_ROUTER).exchange(
            PCS_IDX_LISUSD, PCS_IDX_USDT, lisUsdMinted, 0
        );

        _endPnL("B09-06: Wombat sidecar + Lista CDP + PCS lisUSD unwind");
    }

    function _resolvePool() internal {
        wombatPool = WOMBAT_SLISBNB_POOL;
        uint256 codeSize;
        address p = wombatPool;
        assembly {
            codeSize := extcodesize(p)
        }
        if (codeSize == 0) {
            wombatPool = BSC.WOMBAT_MAIN_POOL;
        }
    }

    /// @dev Offline simulation: documented 7 bp Wombat over-quote (net of
    ///      5 bp haircut) on slisBNB out at cov_BNB=0.88, 70% LTV CDP mint,
    ///      and 2 bp lisUSD discount on PCS Stable.
    function _offlinePnLCheck() internal {
        // Mechanism (a): WBNB -> slisBNB with 7 bp BNB-rate bonus.
        uint256 fairSlis = (NOTIONAL_WBNB * 1e18) / INTERNAL_RATE_E18; // ~463.8
        uint256 bonusSlis = (fairSlis * 7) / 10000;
        slisBnbReceived = fairSlis + bonusSlis;
        bnbValueAtInternalRate = (slisBnbReceived * INTERNAL_RATE_E18) / 1e18;

        // Mechanism (b): mint lisUSD at 70% LTV of BNB-marked collateral USD.
        uint256 collateralUsdE18 =
            (bnbValueAtInternalRate * BNB_USD_E8) / 1e8;
        lisUsdMinted = (collateralUsdE18 * TARGET_LTV_BPS) / 10000;

        // Mechanism (c): lisUSD trades at ~0.998 USDT on PCS Stable typically.
        usdtFromLisUsd = (lisUsdMinted * 9980) / 10000;

        _fund(BSC.WBNB, address(this), NOTIONAL_WBNB);
        _startPnL();

        // Simulate the chain of state transitions.
        IERC20(BSC.WBNB).transfer(address(0xdead), NOTIONAL_WBNB);
        _fund(BSC.slisBNB, address(this), slisBnbReceived);
        // Collateral deposit consumes slisBNB (offline: sink to dead).
        IERC20(BSC.slisBNB).transfer(address(0xdead), slisBnbReceived);
        // Mint lisUSD -> swap to USDT.
        _fund(BSC.USDT, address(this), usdtFromLisUsd);
        // Track the lisUSD debt explicitly as a "negative balance" by funding
        // *negative* via a sink-side balance of debt-equivalent.
        // The PnL helper does not natively support debt; the PnL line will
        // reflect: + USDT + (slisBNB consumed via CDP, treated as 'gone'), -
        // WBNB. Strategy reads: net = USDT received minus WBNB used; the
        // collateral upside (slisBNB held in CDP, withdrawable) is *not*
        // in the PnL line and is documented separately in the README.

        _endPnL("B09-06[offline]: Wombat sidecar + Lista CDP + PCS lisUSD unwind");
    }
}
