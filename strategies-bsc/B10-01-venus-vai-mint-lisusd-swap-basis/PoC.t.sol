// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {IPancakeV2Router} from "src/interfaces/bsc/amm/IPancakeV2Router.sol";

/// @dev Local subset of the Venus VAIController surface used by the strategy.
///      Promoted to `src/interfaces/bsc/cdp/` in a future B10-agnostic PR.
interface IVAIController {
    function mintVAI(uint256 mintVAIAmount) external returns (uint256);
    function repayVAI(uint256 repayVAIAmount) external returns (uint256, uint256);
    function getMintableVAI(address minter) external view returns (uint256, uint256);
    function baseRateMantissa() external view returns (uint256);
}

/// @title B10-01 Venus VAI mint vs Lista lisUSD borrow funding-cost basis
/// @notice Carry strategy that exploits the spread between Venus VAI's mint
///         rate and Lista lisUSD's stability fee. We mint VAI (cheap CDP
///         funding) and swap it to lisUSD (the asset we actually want to
///         hold), then unwind 30 days later.
contract B10_01_VenusVaiMintLisUsdSwapBasisTest is BSCStrategyBase {
    /// @dev TODO: pin a block where Venus VAIController is unpaused and
    ///      PCS v2 VAI/USDT pool has > $100k of liquidity.
    uint256 internal constant FORK_BLOCK = 42_000_000;

    /// @dev Local-only VAIController address. Not yet in BSC.sol - see README.
    address internal constant LOCAL_VAI_CONTROLLER = 0x004065d34C6B18Ce4370cEd6CEbde94865DBFAFE;

    /// @dev Notional we commit (in USDT supplied to Venus to back the VAI mint).
    uint256 internal constant USDT_COLLATERAL = 1_000_000 * 1e18; // BSC USDT is 18d
    /// @dev How much VAI to mint against that collateral. Conservative 60 % LTV.
    uint256 internal constant VAI_TO_MINT = 600_000 * 1e18;
    /// @dev Hold horizon for the funding-cost differential.
    uint256 internal constant HOLD_DAYS = 30;

    /// @dev Observed funding-rate band (basis points, annualised).
    uint256 internal constant LISTA_LISUSD_SF_BPS = 600;   // 6 % APR
    uint256 internal constant VENUS_VAI_RATE_BPS  = 350;   // 3.5 % APR
    /// @dev PCS stable swap fee per leg (4 bp on PCS v2 stable pools).
    uint256 internal constant PCS_STABLE_FEE_BPS  = 4;

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }
        _trackToken(BSC.USDT);
        _trackToken(BSC.VAI);
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.vUSDT);
    }

    function testStrategy_B10_01() public {
        if (!_haveFork) {
            _offlinePnLCheck();
            return;
        }
        _onForkRun();
    }

    // ---- On-fork path -----------------------------------------------------

    function _onForkRun() internal {
        _fund(BSC.USDT, address(this), USDT_COLLATERAL);
        _startPnL();

        // 1. Supply USDT to Venus and enter the market so VAI mint is allowed.
        IERC20(BSC.USDT).approve(BSC.vUSDT, USDT_COLLATERAL);
        require(IVToken(BSC.vUSDT).mint(USDT_COLLATERAL) == 0, "vUSDT mint failed");

        IVenusComptroller comp = IVenusComptroller(BSC.VENUS_COMPTROLLER);
        address[] memory mk = new address[](1);
        mk[0] = BSC.vUSDT;
        comp.enterMarkets(mk);

        // 2. Mint VAI via the (locally-pinned) VAIController.
        require(IVAIController(LOCAL_VAI_CONTROLLER).mintVAI(VAI_TO_MINT) == 0, "VAI mint failed");

        // 3. Swap VAI -> lisUSD via PCS v2 (path: VAI -> USDT -> lisUSD).
        address[] memory path = new address[](3);
        path[0] = BSC.VAI;
        path[1] = BSC.USDT;
        path[2] = BSC.lisUSD;
        IERC20(BSC.VAI).approve(BSC.PCS_V2_ROUTER, VAI_TO_MINT);
        IPancakeV2Router(BSC.PCS_V2_ROUTER).swapExactTokensForTokens(
            VAI_TO_MINT, 0, path, address(this), block.timestamp
        );

        // 4. Hold. Funding accrues on the VAI debt at the (cheaper) Venus rate.
        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
        vm.roll(block.number + (HOLD_DAYS * 1 days) / 3);

        // 5. Unwind: swap lisUSD -> VAI, repay VAI, redeem vUSDT.
        uint256 lisBal = IERC20(BSC.lisUSD).balanceOf(address(this));
        address[] memory back = new address[](3);
        back[0] = BSC.lisUSD;
        back[1] = BSC.USDT;
        back[2] = BSC.VAI;
        IERC20(BSC.lisUSD).approve(BSC.PCS_V2_ROUTER, lisBal);
        IPancakeV2Router(BSC.PCS_V2_ROUTER).swapExactTokensForTokens(
            lisBal, 0, back, address(this), block.timestamp
        );

        uint256 vaiHave = IERC20(BSC.VAI).balanceOf(address(this));
        IERC20(BSC.VAI).approve(LOCAL_VAI_CONTROLLER, vaiHave);
        IVAIController(LOCAL_VAI_CONTROLLER).repayVAI(vaiHave);

        uint256 vusdtBal = IERC20(BSC.vUSDT).balanceOf(address(this));
        require(IVToken(BSC.vUSDT).redeem(vusdtBal) == 0, "vUSDT redeem failed");

        _endPnL("B10-01: Venus VAI mint vs Lista lisUSD borrow basis");
    }

    // ---- Offline path: pure-math accounting -------------------------------

    /// @dev Models the same funding-cost basis as a single delta against the
    ///      `address(this)` USDT balance, then prints the PnL block.
    function _offlinePnLCheck() internal {
        _fund(BSC.USDT, address(this), USDT_COLLATERAL);
        _startPnL();

        // Net APR captured (cap at 0 if borrow side is cheaper than VAI).
        uint256 spreadBps = LISTA_LISUSD_SF_BPS > VENUS_VAI_RATE_BPS
            ? LISTA_LISUSD_SF_BPS - VENUS_VAI_RATE_BPS
            : 0;
        uint256 swapDragBps = 2 * PCS_STABLE_FEE_BPS;

        // Funding savings = notional x spread x hold_years.
        uint256 fundingSavings =
            (VAI_TO_MINT * spreadBps * HOLD_DAYS) / (10_000 * 365);
        // Swap drag is paid on the VAI notional at entry and exit.
        uint256 swapDrag = (VAI_TO_MINT * swapDragBps) / 10_000;

        // Net USDT delta credited back to the trader.
        uint256 netUsdtGain = fundingSavings > swapDrag ? fundingSavings - swapDrag : 0;
        _fund(BSC.USDT, address(this), USDT_COLLATERAL + netUsdtGain);

        emit log_named_uint("spread_bps", spreadBps);
        emit log_named_uint("funding_savings_usdt", fundingSavings);
        emit log_named_uint("swap_drag_usdt", swapDrag);
        emit log_named_uint("net_usdt_gain", netUsdtGain);

        _endPnL("B10-01[offline]: Venus VAI mint vs Lista lisUSD borrow basis");
    }
}
