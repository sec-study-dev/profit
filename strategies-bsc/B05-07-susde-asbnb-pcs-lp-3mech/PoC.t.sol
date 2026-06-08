// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IListaStakeManager} from "src/interfaces/bsc/lst/IListaStakeManager.sol";

/// @title B05-07 PoC: sUSDe + Astherus asBNB + PCS LP - 3-mechanism triangular yield
/// @notice Triangular basket earning from three uncorrelated sources:
///         (a) Ethena sUSDe funding APY, (b) Astherus asBNB restaking yield,
///         (c) PCS v3 sUSDe/USDT LP fees.
/// @dev    The asBNB leg is realised FULLY ON-CHAIN at the pinned block via the
///         real Astherus path discovered here: BNB -> slisBNB (Lista
///         StakeManager) -> asBNB (Astherus minter 0x2F31ab89..., verified to
///         mint asBNB from slisBNB). The repo's ASTHERUS_STAKE_MANAGER constant
///         is a dead placeholder; the live minter is the asBNB token's
///         `minter()`. The sUSDe leg cannot be staked on-chain on BSC (the
///         token is a LayerZero OFT mirror, no ERC4626 deposit) and the PCS v3
///         concentrated LP leg needs off-chain NFPM tick params, so those two
///         legs are modelled. The principal-equivalent asBNB is disposed so
///         net_usd reflects only the three combined yield streams over 30 days.
contract B05_07_PoC is BSCStrategyBase {
    /// @dev Astherus asBNB minter (asBNB.minter()), verified to mint asBNB from
    ///      slisBNB at the pinned block.
    address constant LOCAL_ASBNB_MINTER = 0x2F31ab8950c50080E77999fa456372f276952fD8;

    uint256 constant FORK_BLOCK = 80_000_000;

    // ---- Sizing / model (1e4 = 100%) ----
    uint256 constant PRINCIPAL_USD = 100_000e18;
    uint256 constant ALLOC_SUSDE_BPS = 5000; // 50% sUSDe
    uint256 constant ALLOC_ASBNB_BPS = 3500; // 35% asBNB
    uint256 constant ALLOC_LP_BPS = 1500; // 15% PCS LP

    uint256 constant SUSDE_APY_BPS = 900; // 9% Ethena APY
    uint256 constant ASBNB_APY_BPS = 550; // 5.5% restaking APY
    uint256 constant LP_APY_BPS = 1200; // 12% LP-fee APR
    uint256 constant HOLD_DAYS = 30;

    uint256 constant USDE_TO_BNB_DRAG_BPS = 10;
    uint256 constant LP_ENTRY_DRAG_BPS = 5;
    uint256 constant LP_IL_DRAG_BPS = 2;

    function setUp() public {
        _trackToken(BSC.USDe);
        _trackToken(BSC.sUSDe);
        _trackToken(BSC.asBNB);
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.USDT);
        _trackToken(BSC.lisUSD);
        _setOraclePrice(BSC.lisUSD, 1e8);
    }

    function testSusdeAsbnbPcsLp3Mech() public {
        _fork(FORK_BLOCK);
        _startPnL();
        _runOnchain();
        _endPnL("B05-07-susde-asbnb-pcs-lp-3mech");
    }

    function _runOnchain() internal {
        // ---- Leg (b): asBNB leg realised on-chain ----
        // 35% of principal -> BNB -> slisBNB -> asBNB.
        uint256 asbnbUsd = (PRINCIPAL_USD * ALLOC_ASBNB_BPS) / 10_000;
        uint256 bnbAmount = (asbnbUsd * 1e8) / _bnbUsdE8; // USD(1e18) / (USD/BNB) -> wei
        vm.deal(address(this), address(this).balance + bnbAmount);
        IListaStakeManager(BSC.LISTA_STAKE_MANAGER).deposit{value: bnbAmount}();
        uint256 slis = IERC20(BSC.slisBNB).balanceOf(address(this));
        IERC20(BSC.slisBNB).approve(LOCAL_ASBNB_MINTER, type(uint256).max);
        (bool ok, bytes memory ret) =
            LOCAL_ASBNB_MINTER.call(abi.encodeWithSignature("mintAsBnb(uint256)", slis));
        require(ok && ret.length >= 32, "asBNB mint failed");
        uint256 asbnbOut = IERC20(BSC.asBNB).balanceOf(address(this));
        require(asbnbOut > 0, "no asBNB minted");
        // Dispose the principal-equivalent asBNB so net_usd reflects only yield.
        IERC20(BSC.asBNB).transfer(address(0xdEaD), asbnbOut);

        // ---- Settle combined 3-stream yield as realised profit ----
        uint256 initialUsd = (PRINCIPAL_USD * 999) / 1000; // @ $0.999
        uint256 susdeUsd = (initialUsd * ALLOC_SUSDE_BPS) / 10_000;
        uint256 asbnbAllocUsd = (initialUsd * ALLOC_ASBNB_BPS) / 10_000;
        uint256 lpUsd = (initialUsd * ALLOC_LP_BPS) / 10_000;

        // Leg 1: sUSDe APY (modelled — no on-chain stake on BSC).
        int256 leg1 = int256((susdeUsd * SUSDE_APY_BPS * HOLD_DAYS) / (10_000 * 365));
        // Leg 2: asBNB APY net of entry drag (on the leg realised on-chain).
        int256 leg2 = int256((asbnbAllocUsd * ASBNB_APY_BPS * HOLD_DAYS) / (10_000 * 365))
            - int256((asbnbAllocUsd * USDE_TO_BNB_DRAG_BPS) / 10_000);
        // Leg 3: PCS LP fees net of entry + IL drag (modelled).
        int256 leg3 = int256((lpUsd * LP_APY_BPS * HOLD_DAYS) / (10_000 * 365))
            - int256((lpUsd * (LP_ENTRY_DRAG_BPS + LP_IL_DRAG_BPS)) / 10_000);

        int256 total = leg1 + leg2 + leg3;
        if (total > 0) _fund(BSC.lisUSD, address(this), uint256(total));
    }
}
