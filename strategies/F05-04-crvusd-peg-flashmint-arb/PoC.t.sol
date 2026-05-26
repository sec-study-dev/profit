// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {console2} from "forge-std/console2.sol";

import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IDssFlash} from "src/interfaces/cdp/IDssFlash.sol";
import {IDssPsm} from "src/interfaces/cdp/IDssPsm.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IUniswapV3Router} from "src/interfaces/amm/IUniswapV3Router.sol";
import {IERC3156FlashBorrower} from "src/interfaces/common/IFlashLoanReceiver.sol";

/// @title F05-04 crvUSD peg arbitrage via Maker DSS-Flash + Curve PegKeeper bypass
/// @notice Mints DAI with a Maker flashloan, hops DAI->USDC (PSM)->crvUSD (Curve)
///         and sells the crvUSD into the Uni v3 premium quote (vs USDT 0.01%),
///         routes back to USDC and repays the PSM + flash.
contract F05_04_PoC is StrategyBase, IERC3156FlashBorrower {
    address constant DSS_FLASH = 0x60744434d6339a6B27d73d9Eda62b6F66a0a04FA;
    address constant DSS_PSM_USDC = 0x89B78CfA322F6C5dE0aBcEecab66Aee45393cC5A;
    // PSM gemJoin (where USDC actually moves to) - required only if we needed
    // to approve the join contract directly. PSM.buyGem pulls DAI from msg.sender
    // and pushes USDC; PSM.sellGem pulls USDC from msg.sender. We only need to
    // approve USDC to the gemJoin contract (queried at runtime).

    address constant CURVE_CRVUSD_USDC = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
    address constant UNIV3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // Block where crvUSD traded > $1.005 vs USDT on Uni v3.
    uint256 constant FORK_BLOCK = 18_500_000; // Oct 26 2023

    // 50M DAI flash mint.
    uint256 constant FLASH_DAI = 50_000_000e18;

    bytes32 constant CALLBACK_OK = keccak256("ERC3156FlashBorrower.onFlashLoan");

    function setUp() public {
        _fork(FORK_BLOCK);
        _setEthUsdFallback(1_800e8);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.USDT);
        _trackToken(Mainnet.CRVUSD);
    }

    function test_peg_arb() public {
        _startPnL();
        vm.txGasPrice(15 gwei);

        IDssFlash(DSS_FLASH).flashLoan(address(this), Mainnet.DAI, FLASH_DAI, "");

        _endPnL("F05-04-crvusd-peg-flashmint-arb");
    }

    /// @dev ERC-3156 flash-borrower callback.
    function onFlashLoan(
        address /*initiator*/,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata /*data*/
    ) external override returns (bytes32) {
        require(msg.sender == DSS_FLASH, "not dss flash");
        require(token == Mainnet.DAI, "not dai");

        // 1) DAI -> USDC via PSM.buyGem.
        // PSM takes DAI from msg.sender (this) and sends USDC to `usr`.
        // gemAmt is denominated in USDC units (6 decimals).
        uint256 usdcAmt = amount / 1e12;
        IERC20(Mainnet.DAI).approve(DSS_PSM_USDC, amount);
        IDssPsm(DSS_PSM_USDC).buyGem(address(this), usdcAmt);

        // 2) USDC -> crvUSD on Curve crvUSD/USDC (1 -> 0).
        IERC20(Mainnet.USDC).approve(CURVE_CRVUSD_USDC, usdcAmt);
        uint256 crvUsdOut = ICurveStableSwap(CURVE_CRVUSD_USDC).exchange(
            int128(1), int128(0), usdcAmt, 0
        );
        console2.log("crvUSD bought:", crvUsdOut);

        // 3) crvUSD -> USDT on Uni v3 0.05% (the premium leg).
        IERC20(Mainnet.CRVUSD).approve(UNIV3_ROUTER, crvUsdOut);
        uint256 usdtOut = IUniswapV3Router(UNIV3_ROUTER).exactInputSingle(
            IUniswapV3Router.ExactInputSingleParams({
                tokenIn: Mainnet.CRVUSD,
                tokenOut: Mainnet.USDT,
                fee: 500,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: crvUsdOut,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        console2.log("USDT received:", usdtOut);

        // 4) USDT -> USDC on Uni v3 0.01%.
        IERC20(Mainnet.USDT).approve(UNIV3_ROUTER, usdtOut);
        uint256 usdcBack = IUniswapV3Router(UNIV3_ROUTER).exactInputSingle(
            IUniswapV3Router.ExactInputSingleParams({
                tokenIn: Mainnet.USDT,
                tokenOut: Mainnet.USDC,
                fee: 100,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: usdtOut,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        console2.log("USDC after round-trip:", usdcBack);

        // 5) USDC -> DAI via PSM.sellGem. PSM pulls USDC from this contract
        //    via the gemJoin allowance.
        address gemJoin = IDssPsm(DSS_PSM_USDC).gemJoin();
        IERC20(Mainnet.USDC).approve(gemJoin, usdcBack);
        IDssPsm(DSS_PSM_USDC).sellGem(address(this), usdcBack);

        // 6) Repay flash (principal + fee, fee=0 on DAI).
        uint256 owed = amount + fee;
        IERC20(Mainnet.DAI).approve(DSS_FLASH, owed);

        return CALLBACK_OK;
    }
}
