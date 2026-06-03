// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IRETH} from "src/interfaces/lst/IRETH.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";
import {IBalancerVault} from "src/interfaces/amm/IBalancerVault.sol";

/// @title F01-03 rETH eMode loop on Aave v3, opened atomically via flashLoanSimple
contract F01_03_RethAaveFlashloanLoopTest is StrategyBase {
    uint256 constant FORK_BLOCK = 21_000_000;

    // Balancer rETH/WETH MetaStable pool - the deepest on-chain rETH venue at this
    // block (~6.0k rETH / 6.8k WETH). poolId verified via getPoolTokens.
    bytes32 constant BAL_RETH_WETH_POOL_ID =
        0x1e19cf2d73a72ef1332c882f20534b6519be0276000200000000000000000112;

    uint8 constant EMODE_ETH_CORRELATED = 1;
    uint256 constant RATE_MODE_VARIABLE = 2;

    // Target leverage L=0.90 -> K=10.
    uint256 constant LTV_BPS = 9000;

    // Aave V3 flashLoanSimple premium (5 bp).
    uint256 constant FLASH_PREMIUM_BPS = 5;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.RETH);
    }

    function testStrategy_F01_03() public {
        // Sized so the K=10 leveraged WETH->rETH swap (~10x principal) stays a
        // small fraction of the Balancer rETH/WETH pool, keeping slippage low
        // enough that the e-mode borrow still closes. Larger notional would push
        // the stable-pool price and break the loop.
        uint256 principal = 20 ether;
        _fund(Mainnet.WETH, address(this), principal);
        _startPnL();

        // (K-1)*P flashloan -> total K*P WETH on hand inside callback.
        uint256 flashSize = (principal * LTV_BPS) / (10_000 - LTV_BPS);

        // Open the loop in one tx via Aave flashloan (mode 0 = OPEN).
        IAavePool(Mainnet.AAVE_V3_POOL).flashLoanSimple(
            address(this),
            Mainnet.WETH,
            flashSize,
            abi.encode(uint8(0), principal, flashSize),
            0
        );

        // Simulate accrual.
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));
        // Touch reserve to crystallise indices.
        IERC20(Mainnet.RETH).approve(Mainnet.AAVE_V3_POOL, type(uint256).max);
        deal(Mainnet.RETH, address(this), 1);
        IAavePool(Mainnet.AAVE_V3_POOL).supply(Mainnet.RETH, 1, address(this), 0);

        (uint256 totalCollBase, uint256 totalDebtBase, , , , uint256 hf) =
            IAavePool(Mainnet.AAVE_V3_POOL).getUserAccountData(address(this));
        emit log_named_uint("collateral_base_e8_usd", totalCollBase);
        emit log_named_uint("debt_base_e8_usd", totalDebtBase);
        emit log_named_uint("equity_base_e8_usd", totalCollBase - totalDebtBase);
        emit log_named_uint("health_factor_e18", hf);

        // ---- Unwind so the reported PnL is a genuine round-trip number ----
        // Without unwinding, the leveraged collateral sits inside Aave and is not
        // captured by StrategyBase's address-balance accounting. Flash-repay the
        // WETH debt, withdraw the rETH, and swap it back to WETH; everything then
        // lands in tracked balances so net_usd reflects the true economic result
        // (swap fees both ways + Aave borrow interest - rETH staking accrual).
        address vDebtWeth =
            IAavePool(Mainnet.AAVE_V3_POOL).getReserveData(Mainnet.WETH).variableDebtTokenAddress;
        uint256 debtWeth = IERC20(vDebtWeth).balanceOf(address(this));
        IAavePool(Mainnet.AAVE_V3_POOL).flashLoanSimple(
            address(this),
            Mainnet.WETH,
            debtWeth + 0.001 ether, // tiny buffer over the exact debt
            abi.encode(uint8(1), uint256(0), uint256(0)),
            0
        );

        _endPnL("F01-03: rETH eMode loop on Aave (flash, round-trip)");
    }

    /// @notice Aave V3 flashLoanSimple callback.
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        require(msg.sender == Mainnet.AAVE_V3_POOL, "only aave");
        require(initiator == address(this), "only self");
        require(asset == Mainnet.WETH, "asset");

        (uint8 mode, uint256 principal, ) = abi.decode(params, (uint8, uint256, uint256));

        if (mode == 1) {
            _close(amount, premium);
            return true;
        }

        uint256 totalWeth = principal + amount;

        // 1. Acquire rETH by actually swapping totalWeth WETH -> rETH on Balancer
        //    (real route; the swap fee + price impact are real costs reflected in
        //    the PnL). minOut floored at 97% of the fair rETH amount implied by
        //    the Rocket Pool exchange rate (covers fee + modest slippage).
        uint256 rEthRate = IRETH(Mainnet.RETH).getExchangeRate(); // wei/rETH, 1e18 scale
        uint256 fairREth = (totalWeth * 1e18) / rEthRate;
        uint256 minReth = (fairREth * 9700) / 10_000;
        IERC20(Mainnet.WETH).approve(Mainnet.BAL_VAULT, totalWeth);
        IBalancerVault.SingleSwap memory ss = IBalancerVault.SingleSwap({
            poolId: BAL_RETH_WETH_POOL_ID,
            kind: IBalancerVault.SwapKind.GIVEN_IN,
            assetIn: Mainnet.WETH,
            assetOut: Mainnet.RETH,
            amount: totalWeth,
            userData: ""
        });
        IBalancerVault.FundManagement memory fm = IBalancerVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });
        uint256 rEthOut = IBalancerVault(Mainnet.BAL_VAULT).swap(ss, fm, minReth, block.timestamp);

        // 2. Supply rETH to Aave & enter e-mode.
        IERC20(Mainnet.RETH).approve(Mainnet.AAVE_V3_POOL, type(uint256).max);
        IAavePool(Mainnet.AAVE_V3_POOL).supply(Mainnet.RETH, rEthOut, address(this), 0);
        IAavePool(Mainnet.AAVE_V3_POOL).setUserEMode(EMODE_ETH_CORRELATED);

        // 3. Borrow WETH = flashSize + premium so we can repay the flash and
        //    leave the principal as net leverage on Aave.
        uint256 repay = amount + premium;
        IAavePool(Mainnet.AAVE_V3_POOL).borrow(
            Mainnet.WETH, repay, RATE_MODE_VARIABLE, 0, address(this)
        );

        // 4. Approve Aave to pull back the flashloan repayment.
        IERC20(Mainnet.WETH).approve(Mainnet.AAVE_V3_POOL, type(uint256).max);
        return true;
    }

    /// @notice Unwind path: `amount` WETH flashed (>= current WETH debt). Repay
    ///         the debt, withdraw all rETH, swap it back to WETH, leaving the flash
    ///         repayment (amount + premium) to be pulled by Aave. Residual WETH is
    ///         the realised equity.
    function _close(uint256 amount, uint256 premium) internal {
        IERC20(Mainnet.WETH).approve(Mainnet.AAVE_V3_POOL, type(uint256).max);
        // Repay the entire variable WETH debt (Aave caps max to actual debt).
        IAavePool(Mainnet.AAVE_V3_POOL).repay(
            Mainnet.WETH, type(uint256).max, RATE_MODE_VARIABLE, address(this)
        );
        // Withdraw all rETH collateral.
        IAavePool(Mainnet.AAVE_V3_POOL).withdraw(Mainnet.RETH, type(uint256).max, address(this));

        // Swap all rETH -> WETH on Balancer (real exit leg; fee/slippage realised).
        uint256 rBal = IERC20(Mainnet.RETH).balanceOf(address(this));
        uint256 rEthRate = IRETH(Mainnet.RETH).getExchangeRate();
        uint256 fairWeth = (rBal * rEthRate) / 1e18;
        uint256 minWeth = (fairWeth * 9700) / 10_000;
        IERC20(Mainnet.RETH).approve(Mainnet.BAL_VAULT, rBal);
        IBalancerVault.SingleSwap memory ss = IBalancerVault.SingleSwap({
            poolId: BAL_RETH_WETH_POOL_ID,
            kind: IBalancerVault.SwapKind.GIVEN_IN,
            assetIn: Mainnet.RETH,
            assetOut: Mainnet.WETH,
            amount: rBal,
            userData: ""
        });
        IBalancerVault.FundManagement memory fm = IBalancerVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });
        IBalancerVault(Mainnet.BAL_VAULT).swap(ss, fm, minWeth, block.timestamp);

        // Aave pulls amount + premium for the flash repayment.
        require(
            IERC20(Mainnet.WETH).balanceOf(address(this)) >= amount + premium,
            "close: insufficient to repay flash"
        );
        IERC20(Mainnet.WETH).approve(Mainnet.AAVE_V3_POOL, type(uint256).max);
    }
}
