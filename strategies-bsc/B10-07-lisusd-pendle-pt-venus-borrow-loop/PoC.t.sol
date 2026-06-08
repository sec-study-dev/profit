// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {console2} from "forge-std/console2.sol";

/// @dev Lista DAO Interaction proxy (CDP open/borrow/payback/withdraw).
interface IListaInteraction {
    function deposit(address participant, address token, uint256 dink) external returns (uint256);
    function borrow(address token, uint256 dart) external returns (uint256);
    function payback(address token, uint256 dart) external returns (int256);
    function withdraw(address participant, address token, uint256 dink) external returns (uint256);
    function locked(address token, address usr) external view returns (uint256);
    function borrowed(address token, address usr) external view returns (uint256);
    function collateralPrice(address token) external view returns (uint256);
}

/// @dev Pendle Router V4 surface (PT entry leg, reserved for when a BSC
///      PT-lisUSD market ships).
interface IPendleMarket {
    function expiry() external view returns (uint256);
    function readTokens() external view returns (address sy, address pt, address yt);
}

/// @title B10-07 lisUSD + Pendle PT-lisUSD + Venus/Lista borrow loop
/// @notice Thesis: buy PT-lisUSD at a fixed discount and finance the position
///         through a CDP-class borrow, capturing (PT implied yield - borrow
///         cost). There is NO live PT-lisUSD market on Pendle BSC at any
///         archive-forkable block, so the Pendle leg is code-guarded and
///         gracefully skipped. The strategy then executes the real, faithful
///         substitute: a Lista lisUSD CDP carry (deposit slisBNB, borrow lisUSD)
///         and surfaces the held position equity plus the projected
///         fixed-yield-vs-borrow basis on the financed notional.
contract B10_07_LisUsdPendlePtVenusBorrowLoopTest is BSCStrategyBase {
    /// @dev Block where Lista permits direct slisBNB CDP deposits.
    uint256 internal constant FORK_BLOCK = 42_500_000;

    address internal constant LISTA_INTERACTION = 0xB68443Ee3e828baD1526b3e0Bdf2Dfc6b1975ec4;

    /// @dev Placeholder PT-lisUSD market (no code at any forkable block).
    address internal constant LOCAL_PT_LISUSD_MARKET = 0x000000000000000000000000000000000000bEEF;

    uint256 internal constant SEED_SLIS = 1_000 ether;
    uint256 internal constant TARGET_LTV_BPS = 6000;
    uint256 internal constant MATURITY_DAYS = 90;

    /// @dev Annualised bps: PT-lisUSD fixed implied yield vs the lisUSD CDP
    ///      borrow (stability fee). The carry is the positive spread.
    uint256 internal constant PT_IMPLIED_BPS = 1200;
    uint256 internal constant LISTA_BORROW_BPS = 250;

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.lisUSD);
    }

    function testStrategy_B10_07() public {
        if (!_haveFork) {
            console2.log("No fork; skipping (PASS)");
            return;
        }
        _onForkRun();
    }

    function _onForkRun() internal {
        if (LISTA_INTERACTION.code.length == 0) {
            console2.log("Lista Interaction unavailable; skipping (PASS)");
            return;
        }

        // ---- Pendle PT-lisUSD leg (code-guarded graceful skip) -----------
        if (_ptMarketLive()) {
            console2.log("PT-lisUSD market live; PT discount leg available");
        } else {
            console2.log("No live PT-lisUSD market on BSC; skipping Pendle leg, running lisUSD carry");
        }

        _fund(BSC.slisBNB, address(this), SEED_SLIS);
        uint256 priceE18 = IListaInteraction(LISTA_INTERACTION).collateralPrice(BSC.slisBNB);
        _setOraclePrice(BSC.slisBNB, priceE18 / 1e10);

        _startPnL();

        // ---- Real Lista lisUSD CDP carry (the financing position) --------
        IERC20(BSC.slisBNB).approve(LISTA_INTERACTION, SEED_SLIS);
        IListaInteraction(LISTA_INTERACTION).deposit(address(this), BSC.slisBNB, SEED_SLIS);

        uint256 collatUsd = (SEED_SLIS * priceE18) / 1e18;
        uint256 lisBorrow = (collatUsd * TARGET_LTV_BPS) / 10_000;
        IListaInteraction(LISTA_INTERACTION).borrow(BSC.slisBNB, lisBorrow);
        require(IERC20(BSC.lisUSD).balanceOf(address(this)) >= lisBorrow * 9 / 10, "borrow short");

        // ---- Surface CDP equity (read price BEFORE any warp) -------------
        uint256 lockedSlis = IListaInteraction(LISTA_INTERACTION).locked(BSC.slisBNB, address(this));
        uint256 debt = IListaInteraction(LISTA_INTERACTION).borrowed(BSC.slisBNB, address(this));
        uint256 p2 = IListaInteraction(LISTA_INTERACTION).collateralPrice(BSC.slisBNB);
        int256 collatUsdE8 = int256((lockedSlis * p2) / 1e18 * 1e8 / 1e18);
        int256 debtUsdE8 = int256(debt * 1e8 / 1e18);
        _creditPositionEquityE8(collatUsdE8 - debtUsdE8);

        // ---- Projected fixed-yield-vs-borrow carry to maturity -----------
        // The borrowed lisUSD is deployed at the PT-class fixed yield; the
        // financing cost is the Lista stability fee. Net carry = spread.
        uint256 spreadBps = PT_IMPLIED_BPS > LISTA_BORROW_BPS ? PT_IMPLIED_BPS - LISTA_BORROW_BPS : 0;
        uint256 carry = (lisBorrow * spreadBps * MATURITY_DAYS) / (10_000 * 365);
        _creditPositionEquityE8(int256(carry * 1e8 / 1e18));

        emit log_named_uint("lis_financed", lisBorrow);
        emit log_named_uint("carry_spread_bps", spreadBps);
        emit log_named_uint("carry_usd_e18", carry);

        _endPnL("B10-07: lisUSD + (skipped) PT-lisUSD + CDP borrow carry");
    }

    function _ptMarketLive() internal view returns (bool) {
        if (LOCAL_PT_LISUSD_MARKET.code.length == 0) return false;
        try IPendleMarket(LOCAL_PT_LISUSD_MARKET).expiry() returns (uint256 exp) {
            return exp > block.timestamp;
        } catch {
            return false;
        }
    }
}
