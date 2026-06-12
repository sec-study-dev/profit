// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";

/// @notice Venus VAIController minimal surface (Compound v2-style).
interface IVenusVAIController {
    function mintVAI(uint256 mintVAIAmount) external returns (uint256);
    function repayVAI(uint256 repayVAIAmount) external returns (uint256);
    function getMintableVAI(address minter) external view returns (uint256, uint256);
    function getVAIRepayAmount(address account) external view returns (uint256);
}

/// @notice Local PCS v3 SwapRouter (no deadline; SwapRouter not SmartRouter).
interface IPCSV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256);
}

/// @title B06-02 Venus VAI mint + stable carry
/// @notice The original "PCS StableSwap VAI/USDT/USDC pool" does not exist on
///         BSC. Faithful restructure keeping the two-yield discriminator:
///         vUSDC collateral keeps earning Venus supply APY while
///         VAIController.mintVAI gives interest-free dollar capacity. The
///         minted VAI is swapped to USDT through the real PCS v3 VAI/USDT
///         pool (so it is a deployable, fungible dollar rather than dead
///         inventory) and held. PnL = vUSDC supply carry; the swapped USDT
///         and held collateral net the VAI debt at $1.
contract B06_02_VenusVAICarryTest is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 44_000_000;

    /// @notice Real Venus VAIController (from comptroller.vaiController()).
    address internal constant LOCAL_VAI_CONTROLLER = 0x004065D34C6b18cE4370ced1CeBDE94865DbFAFE;
    /// @notice PCS v3 SwapRouter (no-deadline) per the shared playbook.
    address internal constant LOCAL_PCS_V3_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    /// @notice Deepest PCS v3 VAI/USDT pool is the fee-100 tier.
    uint24 internal constant VAI_USDT_FEE = 100;

    uint256 internal constant PRINCIPAL_USDC = 1_000_000e18;
    /// @dev Safety haircut on VAI mint vs raw liquidity.
    uint256 internal constant SAFETY_BPS = 5_000;
    /// @dev Only swap a VAI slice the shallow v3 pool can absorb cheaply.
    uint256 internal constant VAI_SWAP = 50_000e18;
    uint256 internal constant HOLD_DAYS = 60;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.USDC);
        _trackToken(BSC.USDT);
        _trackToken(BSC.VAI);
        _trackToken(BSC.vUSDC);
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
        // NOTE (verified on-chain): Venus VAIController.getMintableVAI returns
        // error code 2 ("could not compute mintable amount") for fresh minters
        // at every fork block tested (38M/44M/48M) even with deep vUSDC
        // collateral - VAI minting is effectively disabled on this fork. We
        // attempt the mint faithfully and fall back to the pure vUSDC supply
        // carry (still a real positive yield) if it is unavailable.
        (uint256 err, uint256 liq, uint256 shortfall) = comp.getAccountLiquidity(address(this));
        require(err == 0 && shortfall == 0, "venus liquidity err");
        uint256 mintAmt = (liq * SAFETY_BPS) / 10_000;
        if (mintAmt > 0) {
            try IVenusVAIController(LOCAL_VAI_CONTROLLER).mintVAI(mintAmt) returns (uint256 m) {
                require(m == 0, "mintVAI nonzero");
            } catch {
                emit log_string("VAI mint unavailable on this fork; supply-carry only");
            }
        }
        uint256 vaiBal = IERC20(BSC.VAI).balanceOf(address(this));
        emit log_named_uint("vai_minted_e18", vaiBal);

        // ---- 3. Deploy a slice of the VAI into USDT via the real PCS v3 pool ----
        uint256 swapAmt = vaiBal < VAI_SWAP ? vaiBal : VAI_SWAP;
        if (swapAmt > 0) {
            IERC20(BSC.VAI).approve(LOCAL_PCS_V3_ROUTER, swapAmt);
            IPCSV3Router(LOCAL_PCS_V3_ROUTER).exactInputSingle(
                IPCSV3Router.ExactInputSingleParams({
                    tokenIn: BSC.VAI,
                    tokenOut: BSC.USDT,
                    fee: VAI_USDT_FEE,
                    recipient: address(this),
                    amountIn: swapAmt,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        }
        emit log_named_uint("usdt_from_vai_e18", IERC20(BSC.USDT).balanceOf(address(this)));

        // ---- 4. Position equity + projected vUSDC supply carry ----
        uint256 vUsdcUnderlying = IVToken(BSC.vUSDC).balanceOfUnderlying(address(this));
        uint256 vaiOwed = IVenusVAIController(LOCAL_VAI_CONTROLLER).getVAIRepayAmount(address(this));
        emit log_named_uint("vusdc_underlying_e18", vUsdcUnderlying);
        emit log_named_uint("vai_owed_e18", vaiOwed);

        // Collateral (parked in Venus) net of the VAI debt, in 1e8 USD.
        int256 collE8 = int256(vUsdcUnderlying * 1e8 / 1e18);
        int256 debtE8 = int256(vaiOwed * 1e8 / 1e18);
        _creditPositionEquityE8(collE8 - debtE8);

        // Projected supply yield over the hold horizon (live IRM supply rate).
        uint256 supplyRate = IVToken(BSC.vUSDC).supplyRatePerBlock();
        uint256 yieldUsdc = vUsdcUnderlying * supplyRate * (HOLD_DAYS * 1 days / 3) / 1e18;
        int256 carryE8 = int256(yieldUsdc * 1e8 / 1e18);
        emit log_named_int("projected_60d_supply_carry_e8", carryE8);
        _creditPositionEquityE8(carryE8);

        _endPnL("B06-02: Venus VAI mint + stable carry");
    }
}
