// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {IPancakeStableRouter} from "src/interfaces/bsc/amm/IPancakeStableRouter.sol";

/// @notice Venus VAIController minimal surface (Compound v2-style).
/// @dev    Inlined locally because BSC.sol does not yet expose
///         VAIController and this file may not edit src/.
interface IVenusVAIController {
    function mintVAI(uint256 mintVAIAmount) external returns (uint256);
    function repayVAI(uint256 repayVAIAmount) external returns (uint256);
    function getMintableVAI(address minter) external view returns (uint256, uint256);
    function getVAIRepayAmount(address account) external view returns (uint256);
}

/// @title B06-02 Venus VAI mint + PCS StableSwap carry
/// @notice Three-mechanism stack: vUSDC collateral keeps earning supply APY,
///         VAIController.mintVAI gives free VAI capacity, PCS StableSwap LP
///         earns CAKE + swap fees on the minted VAI. Demonstrates that the
///         same dollar simultaneously earns two yields (supply on Venus +
///         LP on PCS) because the VAI mint does not draw on the vToken
///         reserves.
contract B06_02_VenusVAIPCSCarryTest is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 42_500_000;

    /// @notice Venus VAIController (proxy). Inlined per the family rules.
    /// TODO verify at pinned block.
    address internal constant LOCAL_VAI_CONTROLLER = 0x004065D34C6B18cE4370CeD6fE0f35BCd06b8b96;
    /// @notice PCS StableSwap VAI/USDT/USDC pool. TODO verify.
    address internal constant LOCAL_PCS_VAI_3POOL = 0x5B5bb9765efF8d26c6bBa4F5d52d86D3d5B6c1fA;
    /// @dev VAI is coin index 0 in the canonical VAI/USDT/USDC pool.
    uint256 internal constant POOL_VAI_INDEX = 0;

    uint256 internal constant PRINCIPAL_USDC = 1_000_000e18;
    /// @dev Safety haircut on VAI mint vs raw liquidity.
    uint256 internal constant SAFETY_BPS = 9_500;
    uint256 internal constant HOLD_DAYS = 60;
    uint256 internal constant SECS_PER_BLOCK = 3;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.USDC);
        _trackToken(BSC.VAI);
        _trackToken(BSC.vUSDC);
        _trackToken(LOCAL_PCS_VAI_3POOL); // LP token == pool address on Curve fork
    }

    function testStrategy_B06_02() public {
        _fund(BSC.USDC, address(this), PRINCIPAL_USDC);
        _startPnL();

        // ---- 1. Enter the Core vUSDC market and supply ----
        IVenusComptroller comp = IVenusComptroller(BSC.VENUS_COMPTROLLER);
        address[] memory mk = new address[](1);
        mk[0] = BSC.vUSDC;
        comp.enterMarkets(mk);

        IERC20(BSC.USDC).approve(BSC.vUSDC, type(uint256).max);
        require(IVToken(BSC.vUSDC).mint(PRINCIPAL_USDC) == 0, "vUSDC mint failed");

        // ---- 2. Mint VAI against the fresh liquidity ----
        (uint256 err, uint256 liq, uint256 shortfall) = comp.getAccountLiquidity(address(this));
        require(err == 0 && shortfall == 0, "venus liquidity err");
        uint256 mintAmt = (liq * SAFETY_BPS) / 10_000;
        require(IVenusVAIController(LOCAL_VAI_CONTROLLER).mintVAI(mintAmt) == 0, "mintVAI failed");

        uint256 vaiBal = IERC20(BSC.VAI).balanceOf(address(this));
        emit log_named_uint("vai_minted_e18", vaiBal);

        // ---- 3. Deposit VAI into the PCS StableSwap pool (single-sided) ----
        IERC20(BSC.VAI).approve(LOCAL_PCS_VAI_3POOL, type(uint256).max);
        uint256[3] memory amts;
        amts[POOL_VAI_INDEX] = vaiBal;
        // minMint=0 in a PoC; production would compute via get_virtual_price.
        IPancakeStableRouter(LOCAL_PCS_VAI_3POOL).add_liquidity(amts, 0);

        // ---- 4. Hold 60 days. Both legs accrue. ----
        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
        vm.roll(block.number + (HOLD_DAYS * 1 days) / SECS_PER_BLOCK);

        // Force interest accrual on the vUSDC supply leg.
        IVToken(BSC.vUSDC).balanceOfUnderlying(address(this));

        // ---- 5. Unwind: pull LP back to VAI, repay VAI, redeem vUSDC ----
        uint256 lp = IERC20(LOCAL_PCS_VAI_3POOL).balanceOf(address(this));
        if (lp > 0) {
            IPancakeStableRouter(LOCAL_PCS_VAI_3POOL).remove_liquidity_one_coin(lp, POOL_VAI_INDEX, 0);
        }

        // Repay VAI debt (includes any accrued stability fee).
        uint256 vaiOwed = IVenusVAIController(LOCAL_VAI_CONTROLLER).getVAIRepayAmount(address(this));
        uint256 vaiAvail = IERC20(BSC.VAI).balanceOf(address(this));
        uint256 vaiRepay = vaiOwed < vaiAvail ? vaiOwed : vaiAvail;
        if (vaiRepay > 0) {
            IERC20(BSC.VAI).approve(LOCAL_VAI_CONTROLLER, vaiRepay);
            IVenusVAIController(LOCAL_VAI_CONTROLLER).repayVAI(vaiRepay);
        }

        // Redeem the full vUSDC position.
        uint256 vTokenBal = IERC20(BSC.vUSDC).balanceOf(address(this));
        if (vTokenBal > 0) IVToken(BSC.vUSDC).redeem(vTokenBal);

        emit log_named_uint("vai_residual_e18", IERC20(BSC.VAI).balanceOf(address(this)));
        emit log_named_uint("usdc_final_e18", IERC20(BSC.USDC).balanceOf(address(this)));

        _endPnL("B06-02: Venus VAI mint + PCS StableSwap carry");
    }
}
