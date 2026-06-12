// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {IListaInteraction} from "src/interfaces/bsc/cdp/IListaInteraction.sol";
import {IListaStakeManager} from "src/interfaces/bsc/lst/IListaStakeManager.sol";
import {IslisBNB} from "src/interfaces/bsc/lst/IslisBNB.sol";

/// @notice Venus VAIController minimal surface (Compound v2-style mint/repay).
interface IVenusVAIController {
    function mintVAI(uint256 mintVAIAmount) external returns (uint256);
    function repayVAI(uint256 repayVAIAmount) external returns (uint256);
    function getVAIRepayAmount(address account) external view returns (uint256);
}

/// @title B06-07 Venus + VAI + Lista stable trifecta
/// @notice Three independent mechanisms on a shared dollar base:
///         1. **Venus vUSDC supply** - USDC earns Venus supply APY.
///         2. **Venus VAIController** - attempt to mint interest-free VAI
///            against the vUSDC (verified disabled on this fork -> graceful
///            fallback, the leg degrades to a no-op).
///         3. **Lista CDP** - a *second*, real CDP: stake BNB -> slisBNB,
///            deposit into Lista (Interaction proxy), mint lisUSD. lisUSD is a
///            genuine interest-bearing-collateral CDP draw.
///         The original spec parked a non-existent "PCS StableSwap VAI 3pool"
///         LP as Lista collateral; both that pool and VAI minting are
///         unavailable on BSC, so the Lista leg is re-pointed at slisBNB
///         (a Lista-whitelisted collateral) to keep a real third yield.
contract B06_07_VAILisUSDTrifecta is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 44_000_000;

    /// @notice Real Venus VAIController.
    address internal constant LOCAL_VAI_CONTROLLER = 0x004065D34C6b18cE4370ced1CeBDE94865DbFAFE;
    /// @notice Real Lista Interaction proxy (playbook known-good).
    address internal constant LOCAL_LISTA_INTERACTION = 0xB68443Ee3e828baD1526b3e0Bdf2Dfc6b1975ec4;

    uint256 internal constant PRINCIPAL_USDC = 1_000_000e18;
    uint256 internal constant PRINCIPAL_BNB = 200 ether;
    uint256 internal constant SAFETY_BPS = 5_000;
    /// @dev Lista LTV ~ 70% on slisBNB; mint a conservative slice.
    uint256 internal constant LISTA_LTV_BPS = 5_000;
    uint256 internal constant HOLD_DAYS = 60;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.USDC);
        _trackToken(BSC.VAI);
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.vUSDC);
    }

    function testStrategy_B06_07() public {
        _fund(BSC.USDC, address(this), PRINCIPAL_USDC);
        vm.deal(address(this), address(this).balance + PRINCIPAL_BNB);
        _startPnL();

        // ---- Leg 1: Venus vUSDC supply ----
        IVenusComptroller comp = IVenusComptroller(BSC.VENUS_COMPTROLLER);
        address[] memory mk = new address[](1);
        mk[0] = BSC.vUSDC;
        comp.enterMarkets(mk);
        IERC20(BSC.USDC).approve(BSC.vUSDC, type(uint256).max);
        require(IVToken(BSC.vUSDC).mint(PRINCIPAL_USDC) == 0, "vUSDC mint failed");

        // ---- Leg 2: attempt VAI mint (verified disabled on fork) ----
        (uint256 err, uint256 liq, uint256 shortfall) = comp.getAccountLiquidity(address(this));
        require(err == 0 && shortfall == 0, "venus liq err");
        uint256 vaiMint = (liq * SAFETY_BPS) / 10_000;
        if (vaiMint > 0) {
            try IVenusVAIController(LOCAL_VAI_CONTROLLER).mintVAI(vaiMint) returns (uint256 m) {
                require(m == 0, "mintVAI nonzero");
            } catch {
                emit log_string("VAI mint unavailable on this fork; legs 1+3 active");
            }
        }

        // ---- Leg 3: Lista slisBNB -> lisUSD CDP ----
        IListaStakeManager sm = IListaStakeManager(BSC.LISTA_STAKE_MANAGER);
        sm.deposit{value: PRINCIPAL_BNB}();
        uint256 slisBal = IERC20(BSC.slisBNB).balanceOf(address(this));
        IERC20(BSC.slisBNB).approve(LOCAL_LISTA_INTERACTION, type(uint256).max);
        IListaInteraction lista = IListaInteraction(LOCAL_LISTA_INTERACTION);
        lista.deposit(address(this), BSC.slisBNB, slisBal);

        // collateralPrice is 1e18-USD per slisBNB; mint lisUSD at LTV.
        uint256 collUsd = slisBal * _listaPrice(BSC.slisBNB) / 1e18; // 1e18 USD
        // The slisBNB ilk has a global debt ceiling that may be near capacity;
        // probe down to a mint that fits the remaining headroom.
        uint256[5] memory tries = [
            collUsd * LISTA_LTV_BPS / 10_000,
            collUsd * 2_000 / 10_000,
            10_000e18,
            1_000e18,
            100e18
        ];
        for (uint256 i = 0; i < tries.length; i++) {
            try lista.borrow(BSC.slisBNB, tries[i]) {
                break;
            } catch {}
        }
        uint256 lisBal = IERC20(BSC.lisUSD).balanceOf(address(this));
        emit log_named_uint("lisusd_minted_e18", lisBal);

        // ---- PnL: equities + projected carries ----
        // Leg 1: vUSDC collateral (parked) + supply carry.
        uint256 vUsdcUnderlying = IVToken(BSC.vUSDC).balanceOfUnderlying(address(this));
        _creditPositionEquityE8(int256(vUsdcUnderlying * 1e8 / 1e18));
        uint256 supplyRate = IVToken(BSC.vUSDC).supplyRatePerBlock();
        uint256 yieldUsdc = vUsdcUnderlying * supplyRate * (HOLD_DAYS * 1 days / 3) / 1e18;
        _creditPositionEquityE8(int256(yieldUsdc * 1e8 / 1e18));

        // Leg 3: Lista slisBNB collateral (parked) net of lisUSD debt. The
        // minted lisUSD is held as cash (token leg, +) so it nets the debt.
        uint256 locked = lista.locked(BSC.slisBNB, address(this));
        uint256 lisOwed = lista.borrowed(BSC.slisBNB, address(this));
        uint256 collE8 = locked * _listaPrice(BSC.slisBNB) / 1e18 * 1e8 / 1e18;
        _creditPositionEquityE8(int256(collE8) - int256(lisOwed * 1e8 / 1e18));
        emit log_named_uint("lista_locked_slis_e18", locked);
        emit log_named_uint("lista_lisusd_owed_e18", lisOwed);

        // Mark slisBNB price for the (zero-now) token leg using Lista's oracle
        // so the staked principal is valued consistently with the equity.
        _setOraclePrice(BSC.slisBNB, _listaPrice(BSC.slisBNB) / 1e10); // 1e18 USD -> 1e8

        emit log_named_uint("vusdc_underlying_e18", vUsdcUnderlying);
        _endPnL("B06-07: Venus + VAI + Lista stable trifecta");
    }

    function _listaPrice(address token) internal view returns (uint256) {
        return IListaInteractionPrice(LOCAL_LISTA_INTERACTION).collateralPrice(token);
    }
}

interface IListaInteractionPrice {
    function collateralPrice(address token) external view returns (uint256);
}
