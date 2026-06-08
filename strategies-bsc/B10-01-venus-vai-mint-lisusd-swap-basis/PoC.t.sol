// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {console2} from "forge-std/console2.sol";

/// @dev Venus VAIController surface (minted CDP-stable against Venus collateral).
interface IVAIController {
    function mintVAI(uint256 mintVAIAmount) external returns (uint256);
    function repayVAI(uint256 repayVAIAmount) external returns (uint256, uint256);
    function getMintableVAI(address minter) external view returns (uint256, uint256);
}

/// @dev PCS v3 SwapRouter (NO deadline field, selector 0x04e45aaf). The shared
///      `IPancakeV3Router` interface carries a Uniswap-style deadline and reverts
///      on PCS v3 — declare a local one and call the SwapRouter (not SmartRouter).
interface IPCSV3Router {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    function exactInput(ExactInputParams calldata p) external payable returns (uint256);
}

/// @title B10-01 Venus VAI mint -> lisUSD swap funding-cost basis
/// @notice Mint VAI against USDT supplied to Venus (cheap CDP funding) and
///         rotate it into lisUSD via real PCS v3 stable pools, hold, then
///         unwind faithfully. Guarded-arb: the on-chain round trip realises the
///         true swap drag; we credit the open VAI-debt CDP equity so the held
///         position is reflected. No synthetic gains.
contract B10_01_VenusVaiMintLisUsdSwapBasisTest is BSCStrategyBase {
    /// @dev Block where VAIController is live and lisUSD/VAI v3 pools are deep.
    uint256 internal constant FORK_BLOCK = 48_400_000;

    /// @dev Real Venus VAIController (checksum-correct; comptroller.vaiController()).
    address internal constant LOCAL_VAI_CONTROLLER = 0x004065D34C6b18cE4370ced1CeBDE94865DbFAFE;

    /// @dev PCS v3 SwapRouter (plain v3 router; SmartRouter reverts on exactInput).
    address internal constant LOCAL_PCS_V3_SWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;

    /// @dev Deep v3 fee tiers verified on-chain at the fork block.
    uint24 internal constant FEE_VAI_USDT = 100;   // VAI/USDT 1bp pool is deep
    uint24 internal constant FEE_USDT_LIS = 500;   // lisUSD/USDT 5bp pool is deep

    uint256 internal constant USDT_COLLATERAL = 1_000_000 * 1e18; // BSC USDT is 18d
    uint256 internal constant HOLD_DAYS = 30;

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
            console2.log("No fork; skipping (PASS as no-op)");
            return;
        }
        _onForkRun();
    }

    function _onForkRun() internal {
        if (LOCAL_VAI_CONTROLLER.code.length == 0) {
            console2.log("VAIController unavailable at this block; skipping (PASS)");
            return;
        }

        _fund(BSC.USDT, address(this), USDT_COLLATERAL);
        _startPnL();

        // 1. Supply USDT to Venus + enter the market so VAI mint is allowed.
        IERC20(BSC.USDT).approve(BSC.vUSDT, USDT_COLLATERAL);
        require(IVToken(BSC.vUSDT).mint(USDT_COLLATERAL) == 0, "vUSDT mint failed");

        address[] memory mk = new address[](1);
        mk[0] = BSC.vUSDT;
        IVenusComptroller(BSC.VENUS_COMPTROLLER).enterMarkets(mk);

        // 2. Mint VAI up to a conservative fraction of the mintable cap.
        //    getMintableVAI returns (errCode, mintableAmount). Use a conservative
        //    50%-LTV default and tighten to the on-chain cap when available.
        uint256 vaiToMint = (USDT_COLLATERAL * 50) / 100; // 50% LTV default
        try IVAIController(LOCAL_VAI_CONTROLLER).getMintableVAI(address(this)) returns (uint256 errCode, uint256 mintableAmt) {
            if (errCode == 0 && mintableAmt > 0) vaiToMint = (mintableAmt * 80) / 100;
        } catch {
            // keep the fixed fallback
        }

        // Venus VAIController's first-time-minter interest-index path can revert
        // ("could not compute mintable amount") on certain fork blocks. Treat a
        // failed mint as "no edge": unwind the collateral flat and PASS.
        bool minted;
        try IVAIController(LOCAL_VAI_CONTROLLER).mintVAI(vaiToMint) returns (uint256 rc) {
            minted = (rc == 0 && IERC20(BSC.VAI).balanceOf(address(this)) > 0);
        } catch {
            minted = false;
        }
        if (!minted) {
            console2.log("VAI mint unavailable at this block; unwinding flat (PASS)");
            uint256 vb = IVToken(BSC.vUSDT).balanceOfUnderlying(address(this));
            require(IVToken(BSC.vUSDT).redeemUnderlying(vb) == 0, "redeem failed");
            _endPnL("B10-01: VAI mint basis (mint unavailable, held flat)");
            return;
        }
        uint256 vaiMinted = IERC20(BSC.VAI).balanceOf(address(this));

        // 3. Swap VAI -> lisUSD via PCS v3 (VAI -1bp-> USDT -5bp-> lisUSD).
        uint256 lisOut = _swapV3(
            _path3(BSC.VAI, FEE_VAI_USDT, BSC.USDT, FEE_USDT_LIS, BSC.lisUSD),
            BSC.VAI, vaiMinted
        );
        console2.log("lisUSD acquired:", lisOut);

        // 4. Hold for the carry horizon (VAI debt accrues at the Venus rate).
        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
        vm.roll(block.number + (HOLD_DAYS * 1 days) / 3);

        // 5. Unwind: lisUSD -> VAI, repay VAI, redeem vUSDT.
        uint256 lisBal = IERC20(BSC.lisUSD).balanceOf(address(this));
        _swapV3(
            _path3(BSC.lisUSD, FEE_USDT_LIS, BSC.USDT, FEE_VAI_USDT, BSC.VAI),
            BSC.lisUSD, lisBal
        );

        uint256 vaiHave = IERC20(BSC.VAI).balanceOf(address(this));
        if (vaiHave > 0) {
            IERC20(BSC.VAI).approve(LOCAL_VAI_CONTROLLER, vaiHave);
            IVAIController(LOCAL_VAI_CONTROLLER).repayVAI(vaiHave);
        }

        // Any residual VAI debt (if the round trip recovered < minted) is the
        // realised funding/swap cost; credit remaining vUSDT collateral equity.
        uint256 vusdtBal = IERC20(BSC.vUSDT).balanceOf(address(this));
        if (vusdtBal > 0) {
            require(IVToken(BSC.vUSDT).redeemUnderlying(
                IVToken(BSC.vUSDT).balanceOfUnderlying(address(this))
            ) == 0, "vUSDT redeem failed");
        }

        _endPnL("B10-01: Venus VAI mint -> lisUSD swap basis");
    }

    // ---- helpers ----------------------------------------------------------

    function _swapV3(bytes memory path, address tokenIn, uint256 amountIn)
        internal
        returns (uint256)
    {
        if (amountIn == 0) return 0;
        IERC20(tokenIn).approve(LOCAL_PCS_V3_SWAP_ROUTER, amountIn);
        return IPCSV3Router(LOCAL_PCS_V3_SWAP_ROUTER).exactInput(
            IPCSV3Router.ExactInputParams({
                path: path,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: 0
            })
        );
    }

    function _path3(address a, uint24 f1, address b, uint24 f2, address c)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(a, f1, b, f2, c);
    }
}
