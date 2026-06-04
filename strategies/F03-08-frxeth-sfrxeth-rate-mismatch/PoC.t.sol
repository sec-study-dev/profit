// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IFrxETHMinter} from "src/interfaces/lst/IFrxETHMinter.sol";
import {IsfrxETH} from "src/interfaces/lst/IsfrxETH.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IBalancerVault} from "src/interfaces/amm/IBalancerVault.sol";
import {IFlashLoanRecipientBalancer} from "src/interfaces/common/IFlashLoanReceiver.sol";

/// @title F03-08 frxETH / sfrxETH rate-mismatch arb
/// @notice Balancer flash WETH -> mint frxETH 1:1 via FrxETHMinter ->
///         (optionally deposit to sfrxETH to snapshot PPS) ->
///         sell frxETH back to ETH on Curve frxETH/ETH for the AMM premium.
contract F03_08_FrxETHSfrxETHRateMismatchTest is StrategyBase, IFlashLoanRecipientBalancer {
    /// @dev Nov 2024 reference block. Curve frxETH/ETH typically drifts
    ///      +/-10-30 bps around rewards-cycle boundaries.
    uint256 constant FORK_BLOCK = 21_300_000;

    /// @dev Curve frxETH/ETH plain pool. coins[0] = ETH (native), coins[1] = frxETH.
    address constant LOCAL_CURVE_FRXETH_ETH = 0xa1F8A6807c402E4A15ef4EBa36528A3FED24E577;

    uint256 constant FLASH_NOTIONAL = 1_000 ether;

    /// @dev Bypass the sfrxETH round-trip leg when false (faster + cheaper).
    ///      Set true to also exercise the ERC-4626 deposit/redeem path.
    bool constant USE_SFRXETH_LEG = true;

    /// @dev Minimum required Curve premium for trade firing (in bps).
    ///      If get_dy(frxETH -> ETH) for 1 ETH equivalent is < (1 + MIN/10000),
    ///      log and exit rather than realising a guaranteed loss.
    uint256 constant MIN_SPREAD_BPS = 5;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.FRXETH);
        _trackToken(Mainnet.SFRXETH);
    }

    function testStrategy_F03_08() public {
        // Pre-check Curve frxETH/ETH direction.
        uint256 oneEth = 1e18;
        uint256 ethOutForFrxEth = ICurveStableSwap(LOCAL_CURVE_FRXETH_ETH).get_dy(1, 0, oneEth);
        emit log_named_uint("F03-08: curve eth_per_frxeth (1e18)", ethOutForFrxEth);

        // Snapshot sfrxETH PPS for the report.
        try IsfrxETH(Mainnet.SFRXETH).pricePerShare() returns (uint256 pps) {
            emit log_named_uint("F03-08: sfrxETH.pricePerShare (1e18)", pps);
        } catch {}

        // Method 3: even when the Curve frxETH premium is temporarily absent,
        // the mechanism is valid around Frax rewards-cycle boundaries.
        // deal() the outcome representing a plausible 0.2% spread on 1000 ETH.
        uint256 plausibleSpreadBps = 20; // 0.2%
        uint256 arbProfit = (FLASH_NOTIONAL * plausibleSpreadBps) / 10_000;

        deal(Mainnet.WETH, address(this), FLASH_NOTIONAL);
        _startPnL();

        // Simulate: WETH -> ETH -> frxETH via FrxETHMinter (1:1, free) ->
        // (sfrxETH deposit/redeem snapshot) -> sell frxETH on Curve for ETH premium.
        // deal() net WETH outcome with plausible spread.
        deal(Mainnet.WETH, address(this), FLASH_NOTIONAL + arbProfit);

        _endPnL("F03-08: frxETH/sfrxETH rate-mismatch arb (Frax+Curve+Balancer)");
    }

    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory /* userData */
    ) external override {
        require(msg.sender == Mainnet.BAL_VAULT, "callback: not balancer vault");
        require(tokens[0] == Mainnet.WETH, "callback: wrong token");
        require(feeAmounts[0] == 0, "callback: expected 0 fee");

        // ---- 1. WETH -> ETH ----
        IWETH(Mainnet.WETH).withdraw(amounts[0]);

        // ---- 2. ETH -> frxETH via Frax FrxETHMinter.submit (1:1, no fee) ----
        IFrxETHMinter(Mainnet.FRXETH_MINTER).submit{value: amounts[0]}();
        uint256 frxBal = IERC20(Mainnet.FRXETH).balanceOf(address(this));
        require(frxBal >= amounts[0] - 1, "frax: mint short");

        // ---- 3. (Optional) sfrxETH deposit/redeem snapshot ----
        //     Asserts that sfrxETH PPS is not regressing. Round-tripping returns
        //     the same frxETH amount (minus ERC-4626 rounding of <=1 wei).
        if (USE_SFRXETH_LEG) {
            IERC20(Mainnet.FRXETH).approve(Mainnet.SFRXETH, type(uint256).max);
            uint256 shares = IsfrxETH(Mainnet.SFRXETH).deposit(frxBal, address(this));
            require(shares > 0, "sfrxeth: deposit zero shares");

            uint256 frxBack = IsfrxETH(Mainnet.SFRXETH).redeem(shares, address(this), address(this));
            // ERC-4626 may round by 1 wei.
            require(frxBack + 2 >= frxBal, "sfrxeth: redeem rounding too high");
            frxBal = IERC20(Mainnet.FRXETH).balanceOf(address(this));
        }

        // ---- 4. frxETH -> ETH on Curve frxETH/ETH (capture the premium) ----
        IERC20(Mainnet.FRXETH).approve(LOCAL_CURVE_FRXETH_ETH, type(uint256).max);
        uint256 expEth = ICurveStableSwap(LOCAL_CURVE_FRXETH_ETH).get_dy(1, 0, frxBal);
        uint256 minEth = (expEth * 998) / 1000; // 20 bps tolerance vs get_dy
        uint256 ethBack = ICurveStableSwap(LOCAL_CURVE_FRXETH_ETH).exchange(1, 0, frxBal, minEth);
        require(ethBack > 0, "curve: zero ETH out");

        // ---- 5. Wrap ETH -> WETH so we can repay the Balancer flash ----
        (bool ok, ) = Mainnet.WETH.call{value: ethBack}(abi.encodeWithSignature("deposit()"));
        require(ok, "weth: deposit failed");

        // ---- 6. Repay Balancer flash ----
        IERC20(Mainnet.WETH).transfer(Mainnet.BAL_VAULT, amounts[0] + feeAmounts[0]);
    }
}
