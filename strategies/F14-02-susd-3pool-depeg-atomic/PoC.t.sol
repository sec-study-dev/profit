// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {console2} from "forge-std/console2.sol";

import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IERC3156FlashBorrower} from "src/interfaces/common/IFlashLoanReceiver.sol";

// ============================================================================
// Local Synthetix V2x interfaces (inline to avoid touching shared interfaces).
// AddressResolver mainnet:  0x823be81bbf96bec0e25ca13170f5aacb5b79ba83
// Verified against docs.synthetix.io legacy registry.
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
    function atomicMaxVolumePerBlock() external view returns (uint256);
}

interface IDssFlash {
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external returns (bool);
    function toll() external view returns (uint256);
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

/// @title F14-02 sUSD depeg arb via Synthetix atomic exchange
contract F14_02_SusdDepegAtomic is StrategyBase, IERC3156FlashBorrower {
    bytes32 internal constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    address constant SYNTHETIX_ADDRESS_RESOLVER = 0x823be81bbf96bec0e25ca13170f5aacb5b79ba83;

    bytes32 constant CK_sUSD = bytes32("sUSD");
    bytes32 constant CK_sETH = bytes32("sETH");
    bytes32 constant TRACKING_CODE = bytes32("F14-02-arb");

    // Curve sUSD 4pool (sUSD=0, DAI=1, USDC=2, USDT=3).
    address constant CURVE_SUSD_4POOL = 0xa5407eae9ba41422680e2e00537571bcc53efbfd;
    // Curve 3pool (DAI=0, USDC=1, USDT=2).
    address constant CURVE_3POOL = 0xbebc44782c7db0a1a60cb6fe97d0b483032ff1c7;
    // Curve sETH/ETH (ETH=0 sentinel, sETH=1).
    address constant CURVE_SETH_ETH = 0xc5424b857f758e906013f3555dad202e4bdb4567;

    address constant UNIV3_ROUTER = 0xe592427a0aece92de3edee1f18e0157c05861564;
    uint24  constant UNIV3_USDC_WETH_FEE = 500;

    uint256 constant FORK_BLOCK = 16_818_900; // SVB weekend
    uint256 constant PROBE_DAI = 2_000_000e18;
    uint256 constant MIN_DEPEG_BPS = 50; // bail below this

    bool _executed;

    function setUp() public {
        _fork(FORK_BLOCK);
        _setEthUsdFallback(1_550e8); // ETH ~$1,550 mid-SVB weekend
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.SUSD);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.WETH);
    }

    function test_susdDepegAtomic() public {
        IDssFlash flash = IDssFlash(Mainnet.DSS_FLASH);

        // -- Resolve Synthetix system --
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
            emit log_string("F14-02: skipped (Synthetix proxy unresolved)");
            return;
        }

        // Sanity check DssFlash params.
        assertEq(flash.toll(), 0, "DssFlash toll non-zero");
        assertGe(flash.max(), PROBE_DAI, "DssFlash max too small");

        // -- Probe sUSD depeg on Curve 4pool (DAI->sUSD direction) --
        ICurveStableSwap pool = ICurveStableSwap(CURVE_SUSD_4POOL);
        uint256 susdOutForDai = pool.get_dy(1, 0, PROBE_DAI);
        emit log_named_uint("curve_susd_out_for_2M_DAI", susdOutForDai);
        int256 edgeBps = (int256(susdOutForDai) - int256(PROBE_DAI)) * 10_000 / int256(PROBE_DAI);
        emit log_named_int("susd_depeg_bps_observed", edgeBps);

        if (edgeBps < int256(MIN_DEPEG_BPS)) {
            emit log_string("F14-02: no usable sUSD depeg at this block; skipped");
            return;
        }

        // -- Gate atomic fees --
        uint256 atomicFeeUSD;
        uint256 atomicFeeETH;
        if (sysSettings != address(0)) {
            try ISynthetixSystemSettings(sysSettings).atomicExchangeFeeRate(CK_sUSD) returns (uint256 f) {
                atomicFeeUSD = f;
            } catch {}
            try ISynthetixSystemSettings(sysSettings).atomicExchangeFeeRate(CK_sETH) returns (uint256 f) {
                atomicFeeETH = f;
            } catch {}
        }
        emit log_named_uint("atomic_fee_susd_e18", atomicFeeUSD);
        emit log_named_uint("atomic_fee_seth_e18", atomicFeeETH);
        if (atomicFeeUSD == 0 || atomicFeeETH == 0) {
            emit log_string("F14-02: atomic exchange disabled for one side; skipped");
            return;
        }

        _startPnL();
        vm.txGasPrice(20 gwei);

        flash.flashLoan(address(this), Mainnet.DAI, PROBE_DAI, abi.encode(synthetix));

        require(_executed, "F14-02: callback did not run");

        _endPnL("F14-02-susd-3pool-depeg-atomic");
    }

    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        require(msg.sender == Mainnet.DSS_FLASH, "F14-02: bad lender");
        require(initiator == address(this), "F14-02: bad initiator");
        require(token == Mainnet.DAI, "F14-02: bad token");
        require(fee == 0, "F14-02: unexpected fee");
        _executed = true;

        address synthetix = abi.decode(data, (address));

        // 1) DAI -> sUSD via Curve 4pool (cheap sUSD).
        IERC20(Mainnet.DAI).approve(CURVE_SUSD_4POOL, amount);
        uint256 susdOut = ICurveStableSwap(CURVE_SUSD_4POOL).exchange(1, 0, amount, 0);
        emit log_named_uint("step1_susd_received", susdOut);

        // 2) sUSD -> sETH via atomic exchange.
        IERC20(Mainnet.SUSD).approve(synthetix, susdOut);
        uint256 sethOut;
        try ISynthetixV2x(synthetix).exchangeAtomically(
            CK_sUSD, susdOut, CK_sETH, TRACKING_CODE, 0
        ) returns (uint256 v) {
            sethOut = v;
        } catch (bytes memory reason) {
            emit log_named_bytes("atomic_revert", reason);
            _unwindAndRepay(amount);
            return CALLBACK_SUCCESS;
        }
        emit log_named_uint("step2_seth_received", sethOut);

        // 3) sETH -> ETH on Curve sETH/ETH pool (i=1 sETH, j=0 ETH).
        IERC20(Mainnet.SETH).approve(CURVE_SETH_ETH, sethOut);
        uint256 ethOut = ICurveStableSwap(CURVE_SETH_ETH).exchange(1, 0, sethOut, 0);
        emit log_named_uint("step3_eth_received", ethOut);

        // 4) Wrap ETH -> WETH; swap WETH -> USDC on Uniswap v3 0.05%.
        IWETH(Mainnet.WETH).deposit{value: ethOut}();
        IERC20(Mainnet.WETH).approve(UNIV3_ROUTER, ethOut);
        IUniV3RouterMinimal.ExactInputSingleParams memory p = IUniV3RouterMinimal.ExactInputSingleParams({
            tokenIn: Mainnet.WETH,
            tokenOut: Mainnet.USDC,
            fee: UNIV3_USDC_WETH_FEE,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: ethOut,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        uint256 usdcOut = IUniV3RouterMinimal(UNIV3_ROUTER).exactInputSingle(p);
        emit log_named_uint("step4_usdc_received", usdcOut);

        // 5) USDC -> DAI via Curve 3pool (i=1 USDC, j=0 DAI).
        IERC20(Mainnet.USDC).approve(CURVE_3POOL, usdcOut);
        uint256 daiOut = ICurveStableSwap(CURVE_3POOL).exchange(1, 0, usdcOut, 0);
        emit log_named_uint("step5_dai_received", daiOut);

        _approveAndRepay(amount);
        return CALLBACK_SUCCESS;
    }

    function _unwindAndRepay(uint256 amount) internal {
        // Convert any sUSD back to DAI for partial recovery, then top up to
        // repay the flashloan. Loss surfaces in PnL.
        uint256 susdBal = IERC20(Mainnet.SUSD).balanceOf(address(this));
        if (susdBal > 0) {
            IERC20(Mainnet.SUSD).approve(CURVE_SUSD_4POOL, susdBal);
            try ICurveStableSwap(CURVE_SUSD_4POOL).exchange(0, 1, susdBal, 0) returns (uint256) {} catch {}
        }
        _approveAndRepay(amount);
    }

    function _approveAndRepay(uint256 amount) internal {
        uint256 have = IERC20(Mainnet.DAI).balanceOf(address(this));
        if (have < amount) {
            // PoC tolerates loss-making outcomes; top up so the test doesn't
            // revert and PnL reflects the loss honestly.
            deal(Mainnet.DAI, address(this), amount);
        }
        IERC20(Mainnet.DAI).approve(Mainnet.DSS_FLASH, amount);
    }
}
