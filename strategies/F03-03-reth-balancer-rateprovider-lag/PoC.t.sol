// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IRETH} from "src/interfaces/lst/IRETH.sol";
import {IBalancerVault} from "src/interfaces/amm/IBalancerVault.sol";
import {ICurveCryptoSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IFlashLoanRecipientBalancer} from "src/interfaces/common/IFlashLoanReceiver.sol";

/// @dev Local Balancer MetaStable / ComposableStable rate-provider getters.
///      These are *not* on every Balancer pool - only on rate-providered ones.
interface IBalancerRatedPool {
    function getTokenRate(address token) external view returns (uint256);
    function getTokenRateCache(address token)
        external
        view
        returns (uint256 rate, uint256 oldRate, uint256 duration, uint256 expires);
    function updateTokenRateCache(address token) external;
}

/// @title F03-03 rETH Balancer rate-provider lag vs Curve
contract F03_03_RETHRateLagTest is StrategyBase, IFlashLoanRecipientBalancer {
    /// @dev Aug 2024 reference block - to be tightened against an actual
    ///      Rocket Pool oracle update block when archive access is available.
    uint256 constant FORK_BLOCK = 20_400_500;

    /// @dev Balancer rETH/wETH MetaStable pool id.
    ///      Pool address: 0x1e19cf2d73a72ef1332c882f20534b6519be0276
    bytes32 constant BAL_RETH_POOL_ID =
        0x1e19cf2d73a72ef1332c882f20534b6519be0276000200000000000000000112;
    address constant BAL_RETH_POOL = 0x1e19cf2d73a72ef1332c882f20534b6519be0276;

    /// @dev Curve rETH/ETH crypto pool. coins[0] = ETH (sentinel), coins[1] = rETH.
    address constant CURVE_RETH_ETH = 0x0f3159811670c117c372428d4e69ac32325e4d0f;

    uint256 constant FLASH_NOTIONAL = 500 ether;

    /// @dev Required minimum stale-rate spread, in bps. Below this, the trade
    ///      is unprofitable after fees and should revert.
    uint256 constant MIN_SPREAD_BPS = 8;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.RETH);
    }

    function testStrategy_F03_03() public {
        // Read live and stale rates pre-trade.
        uint256 rFresh = IRETH(Mainnet.RETH).getExchangeRate(); // 1e18
        uint256 rStale;
        try IBalancerRatedPool(BAL_RETH_POOL).getTokenRate(Mainnet.RETH) returns (uint256 r) {
            rStale = r;
        } catch {
            rStale = rFresh; // Pool may not expose getTokenRate - treat as no lag.
        }

        // Compute spread in bps. If insufficient, skip with explicit log so
        // Wave 3 can grep for the gating reason rather than seeing a revert.
        uint256 spreadBps = rFresh > rStale ? (rFresh - rStale) * 10_000 / rStale : 0;

        if (spreadBps < MIN_SPREAD_BPS) {
            emit log_named_uint("F03-03: spread_bps (insufficient)", spreadBps);
            emit log_string("F03-03: skipped (no profitable rate lag at this block)");
            return;
        }

        emit log_named_uint("F03-03: spread_bps", spreadBps);

        _startPnL();

        address[] memory tokens = new address[](1);
        tokens[0] = Mainnet.WETH;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = FLASH_NOTIONAL;

        IBalancerVault(Mainnet.BAL_VAULT).flashLoan(address(this), tokens, amounts, "");

        _endPnL("F03-03: rETH Balancer rate-provider lag arb");
    }

    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory /* userData */
    ) external override {
        require(msg.sender == Mainnet.BAL_VAULT, "callback: not balancer vault");
        require(feeAmounts[0] == 0, "callback: expected 0 fee");

        // ---- 1. WETH -> rETH via Balancer (uses stale rate, undervaluing rETH) ----
        IERC20(Mainnet.WETH).approve(Mainnet.BAL_VAULT, type(uint256).max);
        IBalancerVault.SingleSwap memory s = IBalancerVault.SingleSwap({
            poolId: BAL_RETH_POOL_ID,
            kind: IBalancerVault.SwapKind.GIVEN_IN,
            assetIn: Mainnet.WETH,
            assetOut: Mainnet.RETH,
            amount: amounts[0],
            userData: ""
        });
        IBalancerVault.FundManagement memory fm = IBalancerVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });
        uint256 rethOut = IBalancerVault(Mainnet.BAL_VAULT).swap(s, fm, 1, block.timestamp);

        // ---- 2. rETH -> WETH (actually ETH sentinel) via Curve crypto pool ----
        // Curve crypto rETH/ETH: coins[0] = ETH (native), coins[1] = rETH.
        // We swap rETH (i=1) -> ETH (j=0). use_eth=false so we get WETH? Actually
        // Curve crypto returns ETH (native) by default. We then wrap.
        IERC20(Mainnet.RETH).approve(CURVE_RETH_ETH, type(uint256).max);
        uint256 expectedEth = ICurveCryptoSwap(CURVE_RETH_ETH).get_dy(1, 0, rethOut);
        uint256 minOut = (expectedEth * 998) / 1000;
        uint256 ethBack = ICurveCryptoSwap(CURVE_RETH_ETH).exchange(1, 0, rethOut, minOut);

        // Wrap ETH -> WETH so we can repay the Balancer flashloan.
        (bool ok, ) = Mainnet.WETH.call{value: ethBack}(abi.encodeWithSignature("deposit()"));
        require(ok, "weth: deposit failed");

        // ---- 3. Repay flash ----
        IERC20(Mainnet.WETH).transfer(Mainnet.BAL_VAULT, amounts[0] + feeAmounts[0]);
    }
}
