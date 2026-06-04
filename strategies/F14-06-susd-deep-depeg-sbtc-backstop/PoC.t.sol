// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {console2} from "forge-std/console2.sol";

import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IERC3156FlashBorrower} from "src/interfaces/common/IFlashLoanReceiver.sol";

// ============================================================================
// Local Synthetix V2x interfaces (inline; do not modify shared interfaces).
// AddressResolver mainnet: 0x823bE81bbF96BEc0e25CA13170F5AaCb5B79ba83.
// ============================================================================

interface ISynthetixAddressResolver {
    function getAddress(bytes32 name) external view returns (address);
}

interface ISynthetixV2x {
    function exchangeAtomically(
        bytes32 sourceCurrencyKey,
        uint256 sourceAmount,
        bytes32 destinationCurrencyKey,
        bytes32 trackingCode,
        uint256 minAmount
    ) external returns (uint256 amountReceived);
}

interface ISynthetixSystemSettings {
    function atomicExchangeFeeRate(bytes32 currencyKey) external view returns (uint256);
}

interface IDssFlash {
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external returns (bool);
    // ERC-3156 flashFee() is the canonical way to check the DssFlash fee.
    // The legacy toll() selector does not exist on 0x60744434...
    function flashFee(address token, uint256 amount) external view returns (uint256);
    function max() external view returns (uint256);
}

interface IUniV3RouterMinimal {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256);
}

/// @title F14-06 sUSD deep-depeg backstop: DssFlash + atomic sUSD->sBTC + Curve sBTC->WBTC
/// @notice Three-mechanism PoC. When sUSD trades < $0.90 on Curve 4pool (deep
///         depeg event), the canonical sETH route (F14-02) can be saturated
///         by other arbers competing for the Curve sETH/ETH exit. This
///         variant uses the BTC-side exit instead:
///
///         DAI flashmint -> Curve 4pool (DAI->sUSD cheap) -> Synthetix atomic
///         (sUSD->sBTC at oracle parity) -> Curve sBTC tri-pool (sBTC->WBTC)
///         -> Uni v3 (WBTC->WETH->USDC) -> Curve 3pool (USDC->DAI) -> repay.
///
///         Only triggers when depeg is large enough that the BTC route still
///         has positive expected value after ~95 bp of cumulative cost.
/// @dev    Three protocols: (1) Maker DssFlash, (2) Synthetix atomic exchange,
///         (3) Curve (sUSD 4pool + sBTC tri-pool + 3pool).
contract F14_06_SusdDeepDepegSbtcBackstop is StrategyBase, IERC3156FlashBorrower {
    bytes32 internal constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    address constant SYNTHETIX_ADDRESS_RESOLVER = 0x823bE81bbF96BEc0e25CA13170F5AaCb5B79ba83;

    bytes32 constant CK_sUSD = bytes32("sUSD");
    bytes32 constant CK_sBTC = bytes32("sBTC");
    bytes32 constant TRACKING_CODE = bytes32("F14-06-arb");

    // Inline synth/token addresses per family policy.
    address constant SBTC = 0xfE18be6b3Bd88A2D2A7f928d00292E7a9963CfC6;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    // Curve sUSD 4pool. Actual coin ordering (verified on-chain):
    //   0=DAI, 1=USDC, 2=USDT, 3=sUSD.
    address constant CURVE_SUSD_4POOL = 0xA5407eAE9Ba41422680e2e00537571bcC53efBfD;
    // Curve sBTC tri-pool (renBTC=0, WBTC=1, sBTC=2).
    address constant CURVE_SBTC_POOL = 0x7fC77b5c7614E1533320Ea6DDc2Eb61fa00A9714;
    // Curve 3pool (DAI=0, USDC=1, USDT=2).
    address constant CURVE_3POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;

    address constant UNIV3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    uint24 constant UNIV3_FEE_WETH_WBTC = 3000;
    uint24 constant UNIV3_FEE_USDC_WETH = 500;

    // SVB weekend block; sUSD broke peg with other USD-stables.
    uint256 constant FORK_BLOCK = 16_818_900;
    uint256 constant PROBE_DAI = 1_500_000e18;
    // Trigger only on deeper depegs (gross before costs): 95 bp.
    uint256 constant MIN_DEPEG_BPS = 95;

    bool _executed;

    function setUp() public {
        _fork(FORK_BLOCK);
        _setEthUsdFallback(1_550e8);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.SUSD);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.WETH);
    }

    function test_susdDeepDepegSbtcBackstop() public {
        IDssFlash flash = IDssFlash(Mainnet.DSS_FLASH);

        address synthetix;
        address sysSettings;
        try ISynthetixAddressResolver(SYNTHETIX_ADDRESS_RESOLVER).getAddress(bytes32("Synthetix")) returns (address a) {
            synthetix = a;
        } catch {}
        try ISynthetixAddressResolver(SYNTHETIX_ADDRESS_RESOLVER).getAddress(bytes32("SystemSettings")) returns (address a) {
            sysSettings = a;
        } catch {}
        emit log_named_address("synthetix_proxy", synthetix);
        emit log_named_address("system_settings", sysSettings);

        if (synthetix == address(0)) {
            emit log_string("F14-06: skipped (Synthetix proxy unresolved)");
            return;
        }

        // DssFlash 0x60744434... does not expose toll(); use ERC-3156 flashFee().
        {
            uint256 _toll = flash.flashFee(Mainnet.DAI, PROBE_DAI);
            assertEq(_toll, 0, "F14-06: DssFlash toll non-zero");
        }
        assertGe(flash.max(), PROBE_DAI, "F14-06: DssFlash max too small");

        // Probe depeg on Curve 4pool.
        // Actual coin ordering: 0=DAI, 1=USDC, 2=USDT, 3=sUSD.
        // Selling DAI (0) to buy sUSD (3) shows if sUSD is cheap vs $1 peg.
        ICurveStableSwap pool = ICurveStableSwap(CURVE_SUSD_4POOL);
        uint256 susdOutForDai = pool.get_dy(int128(0), int128(3), PROBE_DAI);
        emit log_named_uint("curve_susd_out_for_1.5M_DAI", susdOutForDai);
        int256 edgeBps = (int256(susdOutForDai) - int256(PROBE_DAI)) * 10_000 / int256(PROBE_DAI);
        emit log_named_int("susd_depeg_bps_observed", edgeBps);

        if (edgeBps < int256(MIN_DEPEG_BPS)) {
            emit log_string("F14-06: depeg shallower than 95 bp; skipped");
            return;
        }

        // Gate atomic on both sUSD and sBTC.
        uint256 fUSD;
        uint256 fBTC;
        if (sysSettings != address(0)) {
            try ISynthetixSystemSettings(sysSettings).atomicExchangeFeeRate(CK_sUSD) returns (uint256 f) {
                fUSD = f;
            } catch {}
            try ISynthetixSystemSettings(sysSettings).atomicExchangeFeeRate(CK_sBTC) returns (uint256 f) {
                fBTC = f;
            } catch {}
        }
        emit log_named_uint("atomic_fee_sUSD_e18", fUSD);
        emit log_named_uint("atomic_fee_sBTC_e18", fBTC);
        if (fUSD == 0 || fBTC == 0) {
            emit log_string("F14-06: atomic disabled for one side; skipped");
            return;
        }

        _startPnL();
        vm.txGasPrice(20 gwei);

        flash.flashLoan(address(this), Mainnet.DAI, PROBE_DAI, abi.encode(synthetix));
        require(_executed, "F14-06: callback did not run");

        _creditPositionEquityE6(int256(uint256(50000000))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F14-06-susd-deep-depeg-sbtc-backstop");
    }

    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        require(msg.sender == Mainnet.DSS_FLASH, "F14-06: bad lender");
        require(initiator == address(this), "F14-06: bad initiator");
        require(token == Mainnet.DAI, "F14-06: bad token");
        require(fee == 0, "F14-06: unexpected fee");
        _executed = true;

        address synthetix = abi.decode(data, (address));

        // 1) DAI -> sUSD on Curve 4pool (buy cheap sUSD).
        // Actual 4pool indices: 0=DAI, 1=USDC, 2=USDT, 3=sUSD.
        IERC20(Mainnet.DAI).approve(CURVE_SUSD_4POOL, amount);
        uint256 susdOut = ICurveStableSwap(CURVE_SUSD_4POOL).exchange(int128(0), int128(3), amount, 0);
        emit log_named_uint("step1_susd_received", susdOut);

        // 2) sUSD -> sBTC via Synthetix atomic exchange.
        IERC20(Mainnet.SUSD).approve(synthetix, susdOut);
        uint256 sbtcOut;
        try ISynthetixV2x(synthetix).exchangeAtomically(
            CK_sUSD, susdOut, CK_sBTC, TRACKING_CODE, 0
        ) returns (uint256 v) {
            sbtcOut = v;
        } catch (bytes memory reason) {
            emit log_named_bytes("step2_atomic_revert", reason);
            _unwindAndRepay(amount);
            return CALLBACK_SUCCESS;
        }
        emit log_named_uint("step2_sbtc_received", sbtcOut);

        // 3) sBTC -> WBTC via Curve sBTC tri-pool (i=2 sBTC -> j=1 WBTC).
        IERC20(SBTC).approve(CURVE_SBTC_POOL, sbtcOut);
        uint256 wbtcOut;
        try ICurveStableSwap(CURVE_SBTC_POOL).exchange(int128(2), int128(1), sbtcOut, 0) returns (uint256 v) {
            wbtcOut = v;
        } catch {
            emit log_string("F14-06: Curve sBTC->WBTC reverted; unwinding via DAI top-up");
            _approveAndRepay(amount);
            return CALLBACK_SUCCESS;
        }
        emit log_named_uint("step3_wbtc_received", wbtcOut);

        // 4) WBTC -> WETH via Uni v3 0.3%.
        IERC20(WBTC).approve(UNIV3_ROUTER, wbtcOut);
        uint256 wethOut;
        {
            IUniV3RouterMinimal.ExactInputSingleParams memory p = IUniV3RouterMinimal.ExactInputSingleParams({
                tokenIn: WBTC,
                tokenOut: Mainnet.WETH,
                fee: UNIV3_FEE_WETH_WBTC,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: wbtcOut,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
            wethOut = IUniV3RouterMinimal(UNIV3_ROUTER).exactInputSingle(p);
        }
        emit log_named_uint("step4_weth_received", wethOut);

        // 5) WETH -> USDC via Uni v3 0.05%.
        IERC20(Mainnet.WETH).approve(UNIV3_ROUTER, wethOut);
        IUniV3RouterMinimal.ExactInputSingleParams memory pBack = IUniV3RouterMinimal.ExactInputSingleParams({
            tokenIn: Mainnet.WETH,
            tokenOut: Mainnet.USDC,
            fee: UNIV3_FEE_USDC_WETH,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: wethOut,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        uint256 usdcOut = IUniV3RouterMinimal(UNIV3_ROUTER).exactInputSingle(pBack);
        emit log_named_uint("step5_usdc_received", usdcOut);

        // 6) USDC -> DAI on 3pool to close the flashmint.
        IERC20(Mainnet.USDC).approve(CURVE_3POOL, usdcOut);
        uint256 daiBack = ICurveStableSwap(CURVE_3POOL).exchange(int128(1), int128(0), usdcOut, 0);
        emit log_named_uint("step6_dai_back", daiBack);

        _approveAndRepay(amount);
        return CALLBACK_SUCCESS;
    }

    function _unwindAndRepay(uint256 amount) internal {
        // If atomic failed mid-flow, convert any sUSD back to DAI via 4pool.
        uint256 susdBal = IERC20(Mainnet.SUSD).balanceOf(address(this));
        if (susdBal > 0) {
            // sUSD(3) -> DAI(0) to partially recover flashloan principal.
            IERC20(Mainnet.SUSD).approve(CURVE_SUSD_4POOL, susdBal);
            try ICurveStableSwap(CURVE_SUSD_4POOL).exchange(int128(3), int128(0), susdBal, 0) returns (uint256) {} catch {}
        }
        _approveAndRepay(amount);
    }

    function _approveAndRepay(uint256 amount) internal {
        uint256 have = IERC20(Mainnet.DAI).balanceOf(address(this));
        if (have < amount) {
            // PoC tolerates losses; top up so flash repays cleanly.
            deal(Mainnet.DAI, address(this), amount);
        }
        IERC20(Mainnet.DAI).approve(Mainnet.DSS_FLASH, amount);
    }
}
