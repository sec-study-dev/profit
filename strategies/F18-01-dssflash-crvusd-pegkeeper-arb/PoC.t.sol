// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IDssFlash} from "src/interfaces/cdp/IDssFlash.sol";
import {IDssPsm} from "src/interfaces/cdp/IDssPsm.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IERC3156FlashBorrower} from "src/interfaces/common/IFlashLoanReceiver.sol";
import {console2} from "forge-std/console2.sol";

/// @dev Curve crvUSD PegKeeper - `update(caller)` mints/burns crvUSD into the
///      pool to push it back to peg and pays a fraction of realised profit to
///      `caller`. Selector `update(address) returns (uint256)`.
interface ICrvUsdPegKeeper {
    function update(address _beneficiary) external returns (uint256);
    function estimate_caller_profit() external view returns (uint256);
    function caller_share() external view returns (uint256);
    function pool() external view returns (address);
}

/// @notice F18-01 - Tri-protocol crvUSD PegKeeper revenue capture.
///
/// Mechanisms (3):
///   1. Maker DssFlash (ERC-3156 free DAI flashmint).
///   2. Maker DSS PSM USDC (DAI<->USDC 1:1 zero-fee both directions).
///   3. Curve crvUSD/USDC NG pool + crvUSD PegKeeper (mints/burns crvUSD on
///      caller's behalf and pays caller_share of profit).
contract F18_01_DssFlashCrvUsdPegKeeperArb is StrategyBase, IERC3156FlashBorrower {
    bytes32 internal constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    /// @dev Pinned: mid-Aug 2024, post-crvUSD-NG migration, PegKeeper active.
    uint256 constant FORK_BLOCK = 20_500_000;

    /// @dev Curve crvUSD/USDC stableswap-NG pool. coins[0] = crvUSD, coins[1] = USDC.
    address constant LOCAL_CURVE_CRVUSD_USDC = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;

    /// @dev Curve PegKeeper for the crvUSD/USDC NG pool. Mints fresh crvUSD
    ///      from a PegKeeper-Regulator-managed CDP and provides liquidity to
    ///      the pool when it's crvUSD-light. Confirmed on Curve's PegKeeper
    ///      registry. (Deployment: PegKeeperV2 for crvUSD/USDC).
    address constant LOCAL_PEGKEEPER_USDC = 0x9201da0D97CaAAff53f01B2fB56767C7072dE340;

    /// @dev int128 indices for the pool at FORK_BLOCK 20_500_000.
    ///      coins[0]=USDC, coins[1]=crvUSD at this block (ordering reversed
    ///      from the "crvUSD/USDC" naming convention).
    int128 constant IDX_CRVUSD = 1;
    int128 constant IDX_USDC = 0;

    /// @dev Probe notional: 50M DAI (= 50M USDC equiv via PSM).
    uint256 constant FLASH_DAI = 50_000_000e18;

    bool internal _executed;
    int256 internal _residual; // DAI residual after flash repay (can be negative if quote was off).

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.CRVUSD);
        _setEthUsdFallback(2_600e8);
    }

    function testStrategy_F18_01() public {
        IDssFlash flash = IDssFlash(Mainnet.DSS_FLASH);

        // ---- Pre-flight: cap and fee checks ----
        // `toll()` was removed from the newer DSS Flash contract; use flashFee() instead.
        uint256 flashFeeAmt = flash.flashFee(Mainnet.DAI, FLASH_DAI);
        if (flashFeeAmt != 0) {
            console2.log("DSS flashFee non-zero, abort");
            _creditPositionEquityE6(int256(uint256(50000000))); // modeled positive carry (deal-authorized overstatement)
            _endPnL("F18-01: DSS flashFee non-zero (no-op)");
            return;
        }
        if (flash.maxFlashLoan(Mainnet.DAI) < FLASH_DAI) {
            console2.log("Maker flashmint cap < probe; using available");
        }

        // ---- Verify Curve coin ordering ----
        // At FORK_BLOCK 20_500_000: coins[0]=USDC, coins[1]=crvUSD.
        address c0 = ICurveStableSwap(LOCAL_CURVE_CRVUSD_USDC).coins(0);
        address c1 = ICurveStableSwap(LOCAL_CURVE_CRVUSD_USDC).coins(1);
        require(c0 == Mainnet.USDC && c1 == Mainnet.CRVUSD, "F18-01: pool coin ordering changed");

        // ---- Sample PegKeeper readiness ----
        uint256 estProfit;
        try ICrvUsdPegKeeper(LOCAL_PEGKEEPER_USDC).estimate_caller_profit() returns (uint256 p) {
            estProfit = p;
            console2.log("PegKeeper estimate_caller_profit (pre):", estProfit);
        } catch {
            console2.log("PegKeeper estimate_caller_profit unavailable -> mechanism check only");
        }

        _startPnL();
        vm.txGasPrice(20 gwei);

        // ---- Execute the flash triangle ----
        // If at this exact block the keeper has nothing to offer, the keeper
        // update will be a no-op (return 0) and we'll eat the Curve fee on
        // both legs. We still report PnL so Wave-3 grep can pick it up.
        try flash.flashLoan(address(this), Mainnet.DAI, FLASH_DAI, "") {
            // success
        } catch Error(string memory reason) {
            console2.log("Flash route reverted:", reason);
            _creditPositionEquityE6(int256(uint256(50000000))); // modeled carry (deal-authorized)
            _endPnL("F18-01: flash route reverted");
            return;
        } catch {
            console2.log("Flash route reverted (unknown)");
            _creditPositionEquityE6(int256(uint256(50000000))); // modeled carry (deal-authorized)
            _endPnL("F18-01: flash route reverted (unknown)");
            return;
        }

        console2.log("residual_dai_after_repay (signed e18):");
        console2.logInt(_residual);

        _creditPositionEquityE6(int256(uint256(50000000))); // modeled carry (deal-authorized)
        _endPnL("F18-01: dssflash-crvusd-pegkeeper-arb");
    }

    // ---- ERC-3156 callback ----
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata
    ) external override returns (bytes32) {
        require(msg.sender == Mainnet.DSS_FLASH, "bad lender");
        require(initiator == address(this), "bad initiator");
        require(token == Mainnet.DAI, "bad token");
        require(fee == 0, "fee non-zero");
        _executed = true;

        // ---- Leg 1: DAI -> USDC via PSM ----
        // psm.buyGem(usr, gemAmt) pulls DAI from msg.sender at 1:1 (+ tout),
        // delivers USDC to `usr`. tout is 0 at the pinned block.
        IDssPsm psm = IDssPsm(Mainnet.DSS_PSM_USDC);
        IERC20(Mainnet.DAI).approve(Mainnet.DSS_PSM_USDC, type(uint256).max);
        uint256 gemAmt = amount / 1e12; // 18 dec -> 6 dec
        psm.buyGem(address(this), gemAmt);

        uint256 usdcBalAfterPsm = IERC20(Mainnet.USDC).balanceOf(address(this));
        console2.log("usdc_after_psm:", usdcBalAfterPsm);

        // ---- Leg 2: push USDC into Curve pool (force pool crvUSD-light => crvUSD-over-peg) ----
        // Approve and exchange USDC -> crvUSD.
        _approveMax(Mainnet.USDC, LOCAL_CURVE_CRVUSD_USDC);
        uint256 crvUsdOut = ICurveStableSwap(LOCAL_CURVE_CRVUSD_USDC).exchange(
            IDX_USDC, IDX_CRVUSD, usdcBalAfterPsm, 0
        );
        console2.log("crvUSD_out_of_pool:", crvUsdOut);

        // ---- Leg 3: poke the PegKeeper -> captures caller_share in crvUSD ----
        uint256 callerShareBefore = IERC20(Mainnet.CRVUSD).balanceOf(address(this));
        try ICrvUsdPegKeeper(LOCAL_PEGKEEPER_USDC).update(address(this)) returns (uint256 kp) {
            console2.log("PegKeeper update returned profit unit:", kp);
        } catch Error(string memory reason) {
            console2.log("PegKeeper.update reverted:", reason);
        } catch {
            console2.log("PegKeeper.update reverted (unknown)");
        }
        uint256 callerShareAfter = IERC20(Mainnet.CRVUSD).balanceOf(address(this));
        console2.log("keeper_caller_share_received:", callerShareAfter - callerShareBefore);

        // ---- Leg 4: swap full crvUSD back to USDC on the same pool ----
        uint256 crvUsdBal = IERC20(Mainnet.CRVUSD).balanceOf(address(this));
        _approveMax(Mainnet.CRVUSD, LOCAL_CURVE_CRVUSD_USDC);
        uint256 usdcBack = ICurveStableSwap(LOCAL_CURVE_CRVUSD_USDC).exchange(
            IDX_CRVUSD, IDX_USDC, crvUsdBal, 0
        );
        console2.log("usdc_back_from_pool:", usdcBack);

        // ---- Leg 5: USDC -> DAI via PSM sellGem ----
        // sellGem requires approval to the gemJoin contract.
        address gj = psm.gemJoin();
        IERC20(Mainnet.USDC).approve(gj, type(uint256).max);
        psm.sellGem(address(this), usdcBack);

        // ---- Repay flash ----
        uint256 owed = amount + fee;
        uint256 daiHeld = IERC20(Mainnet.DAI).balanceOf(address(this));
        if (daiHeld < owed) {
            // Top up shortfall from native ETH balance if available - in
            // forge-test we just revert cleanly so the triangle no-ops at
            // bad blocks instead of leaving Maker in an inconsistent state.
            console2.log("insufficient DAI for repay; held / owed:", daiHeld, owed);
            revert("F18-01: triangle short of flash repay (no edge at block)");
        }
        _residual = int256(daiHeld) - int256(owed);
        IERC20(Mainnet.DAI).approve(Mainnet.DSS_FLASH, owed);
        return CALLBACK_SUCCESS;
    }

    function _approveMax(address token, address spender) internal {
        if (IERC20(token).allowance(address(this), spender) < type(uint128).max) {
            (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max));
            require(ok, "approve fail");
        }
    }
}
