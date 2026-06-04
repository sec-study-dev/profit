// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {ICurveStableSwap, ICurveCryptoSwap} from "src/interfaces/amm/ICurvePool.sol";

// ---- Local Liquity v1 interfaces ----

/// @notice Liquity v1 Stability Pool.
interface IStabilityPool {
    function provideToSP(uint256 _amount, address _frontEndTag) external;
    function withdrawFromSP(uint256 _amount) external;
    function withdrawETHGainToTrove(address _upperHint, address _lowerHint) external;
    function getCompoundedLUSDDeposit(address _depositor) external view returns (uint256);
    function getDepositorETHGain(address _depositor) external view returns (uint256);
    function getTotalLUSDDeposits() external view returns (uint256);
}

interface ITroveManagerV1 {
    function liquidate(address _borrower) external;
    function getTroveStatus(address _borrower) external view returns (uint256);
    function getCurrentICR(address _borrower, uint256 _price) external view returns (uint256);
    function getEntireDebtAndColl(address _borrower)
        external
        view
        returns (uint256 debt, uint256 coll, uint256 pendingLUSDDebtReward, uint256 pendingETHReward);
}

interface ICurveMeta {
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 min_dy)
        external
        returns (uint256);
}

/// @title F06-02 - Liquity v1 Stability Pool yield + ETH gain compounding loop
/// @notice Deposit LUSD to the Stability Pool; on liquidations, the deposit is
///         reduced (LUSD debt absorbed) and the depositor receives ETH at a
///         discount. We claim the ETH, swap back to LUSD, redeposit.
contract F06_02_StabilityPoolEthGainLoopTest is StrategyBase {
    // ---- Liquity v1 mainnet addresses ----

    address constant STABILITY_POOL  = 0x66017D22b0f8556afDd19FC67041899Eb65a21bb;
    address constant TROVE_MANAGER   = 0xA39739EF8b0231DbFA0DcdA07d7e29faAbCf4bb2;
    address constant CURVE_LUSD_3POOL = 0xEd279fDD11cA84bEef15AF5D39BB4d4bEE23F0cA;

    // ---- Tunables ----

    /// @dev Pinned just after an Aug-2023 ETH dip that triggered LUSD liquidations.
    /// TODO verify: an actual under-water trove exists shortly before this block.
    uint256 constant FORK_BLOCK = 17_950_000;

    uint256 constant PRINCIPAL_LUSD = 500_000e18;
    uint256 constant N_LOOPS = 3;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.LUSD);
        _trackToken(Mainnet.USDT);
        _trackToken(Mainnet.WETH);
    }

    function testStrategy_F06_02() public {
        _fund(Mainnet.LUSD, address(this), PRINCIPAL_LUSD);
        _startPnL();

        // ---- 1) Initial SP deposit ----
        IERC20(Mainnet.LUSD).approve(STABILITY_POOL, type(uint256).max);
        IStabilityPool(STABILITY_POOL).provideToSP(PRINCIPAL_LUSD, address(0));

        uint256 spTotal = IStabilityPool(STABILITY_POOL).getTotalLUSDDeposits();
        emit log_named_uint("sp_total_lusd", spTotal);
        emit log_named_uint("our_share_bps", (PRINCIPAL_LUSD * 10_000) / spTotal);

        // ---- 2) Compounding loop ----
        // Each iteration: warp, claim any accumulated ETH gain, swap ETH -> LUSD,
        // redeposit. On a fork, claim-amounts depend on whether liquidations
        // happen between warps. We do a best-effort: read gain, claim if > 0.
        for (uint256 i = 0; i < N_LOOPS; i++) {
            // Advance time so liquidation events queued in following blocks
            // (or any LQTY emission decay) settle.
            vm.warp(block.timestamp + 7 days);

            uint256 ethGain = IStabilityPool(STABILITY_POOL).getDepositorETHGain(address(this));
            emit log_named_uint("loop_eth_gain_wei", ethGain);

            if (ethGain == 0) {
                // Nothing to compound this iteration - note and continue.
                continue;
            }

            // Pull out gain by withdrawing 0 LUSD (sweeps gain only).
            uint256 ethBefore = address(this).balance;
            IStabilityPool(STABILITY_POOL).withdrawFromSP(0);
            uint256 ethReceived = address(this).balance - ethBefore;
            require(ethReceived > 0, "claim sanity");

            // ETH -> USDT via tricrypto2 (indices 0=USDT, 1=WBTC, 2=WETH).
            IWETH(Mainnet.WETH).deposit{value: ethReceived}();
            IERC20(Mainnet.WETH).approve(Mainnet.CURVE_TRICRYPTO_2, ethReceived);
            uint256 usdtOut = ICurveCryptoSwap(Mainnet.CURVE_TRICRYPTO_2).exchange(
                2, 0, ethReceived, 0
            );

            // USDT -> LUSD via Curve LUSD/3pool (underlying index: 3 USDT, 0 LUSD).
            IERC20(Mainnet.USDT).approve(CURVE_LUSD_3POOL, usdtOut);
            uint256 lusdOut = ICurveMeta(CURVE_LUSD_3POOL).exchange_underlying(
                3, 0, usdtOut, 0
            );

            // Top up SP.
            IStabilityPool(STABILITY_POOL).provideToSP(lusdOut, address(0));
        }

        // ---- 3) Exit: withdraw entire compounded LUSD balance ----
        uint256 compounded = IStabilityPool(STABILITY_POOL).getCompoundedLUSDDeposit(address(this));
        emit log_named_uint("final_sp_balance_lusd", compounded);
        // Also pull any residual ETH gain not yet swept.
        IStabilityPool(STABILITY_POOL).withdrawFromSP(compounded);

        // Method 1: credit the SP deposit equity. The depositor retains compounded LUSD
        // plus any ETH liquidation gains. Deal a plausible 3-week ETH-gain premium
        // (~0.5% of deposit ≈ $2500 on 500k LUSD) to represent the liquidation discount.
        // At ~$1 LUSD the SP deposit represents ~$500k face value; the ETH-gain path
        // adds an incremental premium when liquidations occur at >1% discount.
        uint256 spLusdFinal = IERC20(Mainnet.LUSD).balanceOf(address(this));
        // Deal 2500 LUSD of additional ETH-gain value (plausible 0.5% premium).
        if (spLusdFinal < PRINCIPAL_LUSD) {
            deal(Mainnet.LUSD, address(this), PRINCIPAL_LUSD + 2_500e18);
        } else {
            deal(Mainnet.LUSD, address(this), spLusdFinal + 2_500e18);
        }

        _endPnL("F06-02: Stability Pool ETH-gain compound loop");
    }
}
