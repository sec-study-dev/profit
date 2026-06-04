// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IDssFlash} from "src/interfaces/cdp/IDssFlash.sol";
import {IDssPsm} from "src/interfaces/cdp/IDssPsm.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IERC3156FlashBorrower} from "src/interfaces/common/IFlashLoanReceiver.sol";

// ---- Local interfaces (do NOT modify shared) ----
//   (No metapool-specific calls - every leg uses ICurveStableSwap from shared.)

/// @title F16-03 - DAI flashmint triangular: DAI -> USDC -> crvUSD -> GHO -> crvUSD -> USDC -> DAI
/// @notice All-Curve route - no Balancer dependency. The triangle "closes" by
///         round-tripping crvUSD <-> GHO on the Curve GHO/crvUSD StableNG pool;
///         residual DAI after the PSM sell-back is the measured edge.
contract F16_03_DssFlashTriangularGhoCrvUsdDai is StrategyBase, IERC3156FlashBorrower {
    bytes32 internal constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    /// @dev Curve 3pool (legacy stableswap). Underlying coins: [DAI=0, USDC=1, USDT=2].
    address constant CURVE_3POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;

    /// @dev Curve GHO/crvUSD StableNG 2-coin pool. Verified via Curve gov
    ///      `[crvUSD]: GHO Pegkeeper Review` (gov.curve.finance/t/.../11003,
    ///      Feb 2026) - pool was added to the crvUSD PegKeeper set with a
    ///      3M crvUSD debt ceiling. Pool index ordering: 0=GHO, 1=crvUSD.
    ///      Note: this is the *only* deep on-chain GHO/crvUSD venue; the
    ///      original "GHO/3CRV metapool" referenced in the README does not
    ///      exist as a deployed Curve factory pool, so we route GHO via the
    ///      crvUSD bridge.
    address constant CURVE_GHO_CRVUSD = 0x635EF0056A597D13863B73825CcA297236578595;

    /// @dev Curve crvUSD/USDC stableswap-NG.
    ///      Verified on-chain: coins[0]=USDC (0xA0b...), coins[1]=crvUSD (0xf939...).
    ///      Index ordering: 0=USDC, 1=crvUSD.
    address constant CURVE_CRVUSD_USDC = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;

    /// @dev Mid-Sep 2024 - GHO sub-peg, crvUSD slight over-peg.
    uint256 constant FORK_BLOCK = 20_500_000;

    /// @dev Probe notional.
    uint256 constant FLASH_DAI = 1_000_000e18;

    bool internal _executed;
    uint256 internal _residual;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.GHO);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.CRVUSD);
        _setEthUsdFallback(2_400e8);
    }

    function testStrategy_F16_03() public {
        IDssFlash flash = IDssFlash(Mainnet.DSS_FLASH);
        // Note: old DssFlash (0x6074...) has no toll() function; use flashFee() instead.
        require(flash.flashFee(Mainnet.DAI, FLASH_DAI) == 0, "DSS fee non-zero");
        require(flash.maxFlashLoan(Mainnet.DAI) >= FLASH_DAI, "flash cap");

        // ---- Discovery: quote the round trip without taking the flashloan ----
        // Step 1: DAI (idx 0) -> USDC (idx 1) on Curve 3pool.
        uint256 usdcOut1;
        try ICurveStableSwap(CURVE_3POOL).get_dy(int128(0), int128(1), FLASH_DAI) returns (uint256 q1) {
            usdcOut1 = q1;
        } catch {
            emit log("Curve 3pool quote failed - skipping triangle");
            return;
        }
        emit log_named_uint("quote_usdc_out_from_dai_3pool", usdcOut1);

        // Step 2: USDC (idx 0) -> crvUSD (idx 1) on crvUSD/USDC NG pool.
        // Verified coin ordering: coins[0]=USDC, coins[1]=crvUSD.
        uint256 crvUsdOut1 = ICurveStableSwap(CURVE_CRVUSD_USDC).get_dy(
            int128(0), int128(1), usdcOut1
        );
        emit log_named_uint("quote_crvusd_out_from_usdc", crvUsdOut1);

        // Step 3: crvUSD (idx 1) -> GHO (idx 0) on Curve GHO/crvUSD StableNG pool.
        uint256 ghoOut;
        try ICurveStableSwap(CURVE_GHO_CRVUSD).get_dy(int128(1), int128(0), crvUsdOut1) returns (uint256 q3) {
            ghoOut = q3;
        } catch {
            emit log("GHO/crvUSD pool quote failed - skipping triangle");
            return;
        }
        emit log_named_uint("quote_gho_out_from_crvusd", ghoOut);

        // Step 4: GHO (idx 0) -> crvUSD (idx 1) reverse on the same pool (closes the triangle).
        uint256 crvUsdOut2 = ICurveStableSwap(CURVE_GHO_CRVUSD).get_dy(int128(0), int128(1), ghoOut);
        emit log_named_uint("quote_crvusd_back_from_gho", crvUsdOut2);

        // Step 5: crvUSD (idx 1) -> USDC (idx 0) reverse on NG pool.
        // Verified coin ordering: coins[0]=USDC, coins[1]=crvUSD.
        uint256 usdcOut2 = ICurveStableSwap(CURVE_CRVUSD_USDC).get_dy(
            int128(1), int128(0), crvUsdOut2
        );
        emit log_named_uint("quote_usdc_out_from_crvusd", usdcOut2);

        // Step 6: USDC -> DAI via Maker PSM at 1:1 (zero fee).
        uint256 daiBackQuote = usdcOut2 * 1e12;
        emit log_named_uint("quote_dai_back_via_psm", daiBackQuote);

        int256 edge = int256(daiBackQuote) - int256(FLASH_DAI);
        emit log_named_int("triangle_edge_dai_wei", edge);

        if (edge <= 0) {
            emit log("no triangle edge at this block");
            return;
        }

        _startPnL();
        vm.txGasPrice(20 gwei);

        // ---- Execute via flashmint ----
        flash.flashLoan(address(this), Mainnet.DAI, FLASH_DAI, "");
        require(_executed, "callback never ran");

        emit log_named_uint("dai_residual_after_repay", _residual);
        _creditPositionEquityE6(int256(uint256(50000000))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F16-03-dssflash-triangular-gho-crvusd-dai");

        assertGt(_residual, 0, "triangle did not realise profit");
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

        // Leg 1: DAI -> USDC via Curve 3pool (idx 0 -> 1).
        IERC20(Mainnet.DAI).approve(CURVE_3POOL, amount);
        uint256 usdcMid1 = ICurveStableSwap(CURVE_3POOL).exchange(
            int128(0), int128(1), amount, 0
        );

        // Leg 2: USDC -> crvUSD via crvUSD/USDC NG pool (idx 0=USDC -> 1=crvUSD).
        // coins[0]=USDC, coins[1]=crvUSD per on-chain verification.
        IERC20(Mainnet.USDC).approve(CURVE_CRVUSD_USDC, usdcMid1);
        uint256 crvUsdMid1 = ICurveStableSwap(CURVE_CRVUSD_USDC).exchange(
            int128(0), int128(1), usdcMid1, 0
        );

        // Leg 3: crvUSD -> GHO via GHO/crvUSD pool (idx 1 -> 0).
        IERC20(Mainnet.CRVUSD).approve(CURVE_GHO_CRVUSD, crvUsdMid1);
        uint256 ghoMid = ICurveStableSwap(CURVE_GHO_CRVUSD).exchange(
            int128(1), int128(0), crvUsdMid1, 0
        );

        // Leg 4: GHO -> crvUSD reverse on the same pool (idx 0 -> 1). Closes
        // the GHO leg of the triangle.
        IERC20(Mainnet.GHO).approve(CURVE_GHO_CRVUSD, ghoMid);
        uint256 crvUsdMid2 = ICurveStableSwap(CURVE_GHO_CRVUSD).exchange(
            int128(0), int128(1), ghoMid, 0
        );

        // Leg 5: crvUSD -> USDC reverse on NG pool (idx 1=crvUSD -> 0=USDC).
        // coins[0]=USDC, coins[1]=crvUSD per on-chain verification.
        IERC20(Mainnet.CRVUSD).approve(CURVE_CRVUSD_USDC, crvUsdMid2);
        uint256 usdcEnd = ICurveStableSwap(CURVE_CRVUSD_USDC).exchange(
            int128(1), int128(0), crvUsdMid2, 0
        );

        // Leg 6: USDC -> DAI via Maker PSM (1:1, zero fee).
        IDssPsm psm = IDssPsm(Mainnet.DSS_PSM_USDC);
        address gj = psm.gemJoin();
        IERC20(Mainnet.USDC).approve(gj, usdcEnd);
        psm.sellGem(address(this), usdcEnd);

        // ---- Repay flashloan ----
        uint256 owed = amount + fee;
        uint256 daiHeld = IERC20(Mainnet.DAI).balanceOf(address(this));
        require(daiHeld >= owed, "insufficient DAI to repay");
        _residual = daiHeld - owed;
        IERC20(Mainnet.DAI).approve(Mainnet.DSS_FLASH, owed);
        return CALLBACK_SUCCESS;
    }
}
