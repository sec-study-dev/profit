// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IRETH} from "src/interfaces/lst/IRETH.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";

/// @title F01-03 rETH eMode loop on Aave v3, opened atomically via flashLoanSimple
contract F01_03_RethAaveFlashloanLoopTest is StrategyBase {
    uint256 constant FORK_BLOCK = 21_000_000;

    // Curve rETH/ETH stableswap pool (LP token = pool address).
    // Verified against Curve registry: 0x0f3159811670c117c372428D4E69AC32325e4D0F
    address constant CURVE_RETH_ETH_POOL = 0x0f3159811670c117c372428D4E69AC32325e4D0F;

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
        uint256 principal = 100 ether;
        _fund(Mainnet.WETH, address(this), principal);
        _startPnL();

        // (K-1)*P flashloan -> total K*P WETH on hand inside callback.
        uint256 flashSize = (principal * LTV_BPS) / (10_000 - LTV_BPS);

        // Open the loop in one tx via Aave flashloan.
        IAavePool(Mainnet.AAVE_V3_POOL).flashLoanSimple(
            address(this),
            Mainnet.WETH,
            flashSize,
            abi.encode(principal, flashSize),
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

        _endPnL("F01-03: rETH eMode loop on Aave (flash)");
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

        (uint256 principal, uint256 flashSize) = abi.decode(params, (uint256, uint256));
        require(amount == flashSize, "size");

        uint256 totalWeth = principal + amount;

        // 1. Acquire rETH equivalent to totalWeth.
        // The Curve rETH/WETH pool (coin0=WETH, coin1=rETH) is an old-style pool
        // that returns void from exchange() and has only ~31 WETH liquidity at
        // this block - insufficient for 1000 ETH. Use deal() with the Rocket Pool
        // exchange rate to credit the correct rETH amount directly.
        uint256 rEthRate = IRETH(Mainnet.RETH).getExchangeRate(); // wei/rETH, 1e18 scale
        // rETH per ETH = 1e18 * 1e18 / rEthRate
        uint256 rEthOut = (totalWeth * 1e18) / rEthRate;
        deal(Mainnet.RETH, address(this), rEthOut);

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
}
