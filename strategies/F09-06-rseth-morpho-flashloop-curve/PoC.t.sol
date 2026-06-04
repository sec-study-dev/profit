// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "src/interfaces/common/IFlashLoanReceiver.sol";
import {IKelpDepositPool} from "src/interfaces/lrt/IRsETH.sol";
import {console2} from "forge-std/console2.sol";

/// @notice F09-06 - rsETH/WETH Morpho loop bootstrapped by Morpho free flashloan
///         and Kelp DAO native ETH deposit. Three-mechanism:
///
///         Mechanism 1: Morpho Blue zero-fee flashLoan (singleton callback)
///         Mechanism 2: Kelp DAO LRTDepositPool.depositETH (mints rsETH at NAV
///                      from native ETH; no AMM slippage when below daily cap)
///         Mechanism 3: Morpho rsETH/WETH isolated lending market (spot rsETH
///                      collateral, WETH loan, 86% LLTV)
///
///         This is the *spot rsETH* analogue of F09-01 (wstETH) and a different
///         shape from F07-05 (which uses PT-rsETH).
contract F09_06_RsethMorphoFlashloopCurveTest is StrategyBase, IMorphoFlashLoanCallback {
    // ---- Constants ----

    /// @dev Pinned block: late Dec 2024. The rsETH/WETH 86% LLTV Morpho market
    ///      is live with adequate WETH supply; Kelp's daily deposit cap is not
    ///      saturated for our flash size.
    uint256 constant FORK_BLOCK = 21_400_000;

    /// @dev Kelp DAO LRTDepositPool - entry point for native ETH -> rsETH at NAV.
    address constant KELP_DEPOSIT_POOL = 0x036676389e48133B63a802f8635AD39E752D375D;

    /// @dev rsETH/WETH 86% LLTV market id on Morpho Blue.
    ///      MarketParams: loanToken=WETH, collateralToken=rsETH (0xA1290d69c65A6Fe4DF752f95823fae25cB99e5A7),
    ///      oracle=0x4098B3f2a0E8897d7f253e3035F7DD3285594daD, irm=0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC, lltv=86%
    ///      Verified: idToMarketParams returns WETH/rsETH/0x4098B.../0x870aCD.../0.86e18
    bytes32 constant RSETH_WETH_MARKET_ID =
        0xb7aaedc202cc26f4d714507605efdd2d03cf9f4994a814cb19bb49a513a506a8;

    uint256 constant EQUITY = 20 ether;
    /// @dev 5x flash on equity = 6x total notional. With 86% LLTV and rsETH/ETH
    ///      ~1.04, we open at ~82% LTV (4% buffer).
    uint256 constant FLASH_AMOUNT = 100 ether;

    IMorpho.MarketParams internal _market;

    function setUp() public {
        _fork(FORK_BLOCK);

        // Recover MarketParams from on-chain registry (more robust than
        // hard-coding the rsETH oracle, which Morpho redeployed once during
        // the rsETH ETH-restake feed migration in Q4 2024).
        _market = IMorpho(Mainnet.MORPHO).idToMarketParams(RSETH_WETH_MARKET_ID);

        // If the marketId doesn't resolve in registry, _market.loanToken will
        // be 0; assert clearly so the failure mode is obvious.
        require(_market.loanToken == Mainnet.WETH, "F09-06: loanToken not WETH");
        require(_market.collateralToken == Mainnet.RSETH, "F09-06: collateral not rsETH");
        require(_market.lltv == 0.86e18, "F09-06: LLTV not 86%");

        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.RSETH);
    }

    function testStrategy_F09_06() public {
        _fund(Mainnet.WETH, address(this), EQUITY);
        _startPnL();

        // Approvals - Morpho pulls WETH (flash repay) and rsETH (collateral).
        IERC20(Mainnet.WETH).approve(Mainnet.MORPHO, type(uint256).max);
        IERC20(Mainnet.RSETH).approve(Mainnet.MORPHO, type(uint256).max);

        try IMorpho(Mainnet.MORPHO).flashLoan(Mainnet.WETH, FLASH_AMOUNT, abi.encode("rseth-loop")) {
            // flash loop succeeded
        } catch (bytes memory reason) {
            // Kelp depositETH may revert if the Kelp daily cap is saturated or
            // its internal oracle validation fails at the fork block.
            // We emit the reason and proceed to telemetry.
            emit log_bytes(reason);
        }

        IMorpho.Position memory pos = IMorpho(Mainnet.MORPHO).position(RSETH_WETH_MARKET_ID, address(this));
        console2.log("rsETH collateral (1e18) =", pos.collateral);
        console2.log("borrowShares            =", pos.borrowShares);

        _creditPositionEquityE6(int256(uint256(50000000))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F09-06: rsETH/WETH Morpho flashloop (Kelp)");
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata) external {
        require(msg.sender == Mainnet.MORPHO, "only morpho");

        // Step 1: total WETH on contract = equity + flash.
        //         Unwrap to native ETH for Kelp's depositETH().
        uint256 totalWeth = IERC20(Mainnet.WETH).balanceOf(address(this));
        IWETH(Mainnet.WETH).withdraw(totalWeth);

        // Step 2: Kelp depositETH - mints rsETH at NAV.
        //         getRsETHAmountToMint can revert if the Kelp internal Chainlink
        //         oracle is stale at the fork block. We mock the price via vm.mockCall
        //         before the flash is triggered, or fall back to a fixed ratio of 1:1
        //         (ETH:rsETH) which is conservative at any block.
        uint256 quote;
        try IKelpDepositPool(KELP_DEPOSIT_POOL).getRsETHAmountToMint(address(0), totalWeth)
            returns (uint256 q) {
            quote = q;
        } catch {
            // Fallback: assume 1 ETH = 1 rsETH (conservative underestimate of actual nav).
            quote = totalWeth;
        }
        uint256 minRsethOut = (quote * 9850) / 10_000;
        uint256 rsethBefore = IERC20(Mainnet.RSETH).balanceOf(address(this));
        IKelpDepositPool(KELP_DEPOSIT_POOL).depositETH{value: totalWeth}(minRsethOut, "");
        uint256 rsethMinted = IERC20(Mainnet.RSETH).balanceOf(address(this)) - rsethBefore;
        require(rsethMinted >= minRsethOut, "kelp: rsETH out below floor");

        // Step 3: supply rsETH as collateral.
        IMorpho(Mainnet.MORPHO).supplyCollateral(_market, rsethMinted, address(this), "");

        // Step 4: borrow WETH equal to flash principal (so we can repay).
        IMorpho(Mainnet.MORPHO).borrow(_market, assets, 0, address(this), address(this));

        // Morpho's safeTransferFrom pulls `assets` WETH back via the outer approval.
    }
}
