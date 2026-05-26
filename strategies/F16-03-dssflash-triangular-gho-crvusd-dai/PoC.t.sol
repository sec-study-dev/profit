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

/// @dev Curve meta-pool with underlying coin support (LUSD/3CRV, GHO/3CRV, etc.).
interface ICurveMeta {
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 min_dy)
        external returns (uint256);
    function get_dy_underlying(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function coins(uint256 i) external view returns (address);
}

/// @title F16-03 — DAI flashmint triangular: DAI -> GHO -> USDC -> crvUSD -> USDC -> DAI
/// @notice All-Curve fallback variant — no Balancer dependency, so the test
///         runs deterministically on any block where the meta-pools exist.
contract F16_03_DssFlashTriangularGhoCrvUsdDai is StrategyBase, IERC3156FlashBorrower {
    bytes32 internal constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    /// @dev Curve GHO/3CRV meta-pool. underlying coins: [GHO, DAI, USDC, USDT].
    ///      TODO verify: pool address at the pinned block.
    address constant CURVE_GHO_3CRV = 0x635EF0056A597D13863B73825CcA297236578595;

    /// @dev Curve crvUSD/USDC stableswap-NG (index 0=crvUSD, 1=USDC).
    address constant CURVE_CRVUSD_USDC = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;

    /// @dev Mid-Sep 2024 — GHO sub-peg, crvUSD slight over-peg.
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
        require(flash.toll() == 0, "DSS toll non-zero");
        require(flash.maxFlashLoan(Mainnet.DAI) >= FLASH_DAI, "flash cap");

        // ---- Discovery: quote the round trip without taking the flashloan ----
        // Step 1: DAI (idx 1) -> GHO (idx 0) on GHO/3CRV meta.
        uint256 ghoOut;
        try ICurveMeta(CURVE_GHO_3CRV).get_dy_underlying(1, 0, FLASH_DAI) returns (uint256 q1) {
            ghoOut = q1;
        } catch {
            emit log("GHO/3CRV pool quote failed — skipping triangle");
            return;
        }
        emit log_named_uint("quote_gho_out_from_dai", ghoOut);

        // Step 2: GHO (idx 0) -> USDC (idx 2) on the same meta-pool.
        uint256 usdcOut1 = ICurveMeta(CURVE_GHO_3CRV).get_dy_underlying(0, 2, ghoOut);
        emit log_named_uint("quote_usdc_out_from_gho", usdcOut1);

        // Step 3: USDC -> crvUSD on NG pool.
        uint256 crvUsdOut = ICurveStableSwap(CURVE_CRVUSD_USDC).get_dy(
            int128(1), int128(0), usdcOut1
        );
        emit log_named_uint("quote_crvusd_out_from_usdc", crvUsdOut);

        // Step 4: crvUSD -> USDC reverse on NG pool.
        uint256 usdcOut2 = ICurveStableSwap(CURVE_CRVUSD_USDC).get_dy(
            int128(0), int128(1), crvUsdOut
        );
        emit log_named_uint("quote_usdc_out_from_crvusd", usdcOut2);

        // Step 5: USDC -> DAI via the same GHO/3CRV meta (or via DAI/USDC PSM at 1:1).
        // We will use PSM in execution; for quote use 1:1 conversion.
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
        flash.flashLoan(IERC3156FlashBorrower(address(this)), Mainnet.DAI, FLASH_DAI, "");
        require(_executed, "callback never ran");

        emit log_named_uint("dai_residual_after_repay", _residual);
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

        // Leg 1: DAI -> GHO via GHO/3CRV meta.
        IERC20(Mainnet.DAI).approve(CURVE_GHO_3CRV, amount);
        uint256 ghoOut = ICurveMeta(CURVE_GHO_3CRV).exchange_underlying(1, 0, amount, 0);

        // Leg 2: GHO -> USDC via the same meta (underlying idx 0 -> 2).
        IERC20(Mainnet.GHO).approve(CURVE_GHO_3CRV, ghoOut);
        uint256 usdcMid = ICurveMeta(CURVE_GHO_3CRV).exchange_underlying(0, 2, ghoOut, 0);

        // Leg 3: USDC -> crvUSD via NG pool (idx 1 -> 0).
        IERC20(Mainnet.USDC).approve(CURVE_CRVUSD_USDC, usdcMid);
        uint256 crvUsdMid = ICurveStableSwap(CURVE_CRVUSD_USDC).exchange(
            int128(1), int128(0), usdcMid, 0
        );

        // Leg 4: crvUSD -> USDC reverse on NG pool (idx 0 -> 1).
        IERC20(Mainnet.CRVUSD).approve(CURVE_CRVUSD_USDC, crvUsdMid);
        uint256 usdcEnd = ICurveStableSwap(CURVE_CRVUSD_USDC).exchange(
            int128(0), int128(1), crvUsdMid, 0
        );

        // Leg 5: USDC -> DAI via Maker PSM (1:1, zero fee).
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
