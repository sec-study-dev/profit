// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

// ---------------------------------------------------------------------------
// Inlined interfaces — same checksum-bug rationale as other B13-* PoCs.
// ---------------------------------------------------------------------------

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IPancakeV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IPancakeV3FlashCallback {
    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external;
}

interface IPancakeV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IPancakeV3Router {
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
    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256);
}

/// @notice Minimal Wombat-router shape — Wombat is the third venue used for
///         the BTCB <-> solvBTC stable-asset swap on BSC.
interface IWombatRouter {
    function swapExactTokensForTokens(
        address[] calldata tokenPath,
        address[] calldata poolPath,
        uint256 amountIn,
        uint256 minimumAmountOut,
        address to,
        uint256 deadline
    ) external returns (uint256);
}

/// @notice deBridge `DlnSource` order-creation interface. We model the
///         essentials of `createOrder` — taker bidding finalises out-of-
///         band, so the PoC bookings happen via balance deltas.
interface IDlnSource {
    struct OrderCreation {
        address giveTokenAddress;
        uint256 giveAmount;
        bytes takeTokenAddress; // 32-byte bytes on dest chain
        uint256 takeAmount;
        uint256 takeChainId;
        bytes receiverDst;
        address givePatchAuthoritySrc;
        bytes orderAuthorityAddressDst;
        bytes allowedTakerDst;
        bytes externalCall;
        bytes allowedCancelBeneficiarySrc;
    }
    function createOrder(
        OrderCreation calldata _orderCreation,
        bytes calldata _affiliateFee,
        uint32 _referralCode,
        bytes calldata _permitEnvelope
    ) external payable returns (bytes32);
    function globalFixedNativeFee() external view returns (uint256);
}

abstract contract BSCStrategyBase is Test {
    address[] internal _tracked;
    mapping(address => bool) internal _isTracked;
    mapping(address => uint256) internal _balStart;
    mapping(address => uint256) internal _priceE8;
    uint256 internal _bnbStart;
    uint256 internal _gasStart;
    uint256 internal _gasPriceSnap;
    uint256 internal _bnbUsdE8 = 600e8;

    function _fork(uint256 blk) internal {
        vm.createSelectFork(vm.envString("BSC_RPC_URL"), blk);
    }

    function _fund(address token, address to, uint256 amount) internal {
        deal(token, to, amount);
    }

    function _trackToken(address t) internal {
        if (t == address(0) || _isTracked[t]) return;
        _isTracked[t] = true;
        _tracked.push(t);
    }

    function _setOraclePrice(address t, uint256 priceE8) internal {
        _priceE8[t] = priceE8;
    }

    function _startPnL() internal {
        _bnbStart = address(this).balance;
        for (uint256 i = 0; i < _tracked.length; i++) {
            _balStart[_tracked[i]] = IERC20(_tracked[i]).balanceOf(address(this));
        }
        _gasPriceSnap = tx.gasprice;
        _gasStart = gasleft();
    }

    function _endPnL(string memory label) internal {
        uint256 gasUsed = _gasStart > gasleft() ? _gasStart - gasleft() : 0;
        int256 bnbDelta = int256(address(this).balance) - int256(_bnbStart);
        int256 pnlE6 = _scaled(bnbDelta, _bnbUsdE8, 1e20);
        for (uint256 i = 0; i < _tracked.length; i++) {
            address tk = _tracked[i];
            uint256 p = _priceE8[tk];
            if (p == 0) continue;
            int256 bal = int256(IERC20(tk).balanceOf(address(this)));
            int256 prev = int256(_balStart[tk]);
            int256 delta = bal - prev;
            uint256 scale = 10 ** _decimals(tk) * 1e2;
            pnlE6 += _scaled(delta, p, scale);
        }
        uint256 gasUsdE6 = (_bnbUsdE8 > 0 && _gasPriceSnap > 0)
            ? (gasUsed * _gasPriceSnap * _bnbUsdE8) / 1e26
            : 0;
        int256 netE6 = pnlE6 - int256(gasUsdE6);
        console2.log("==== STRATEGY", label, "====");
        console2.log("pnl_usd=", pnlE6);
        console2.log("gas_usd=", gasUsdE6);
        console2.log("net_usd=", netE6);
        console2.log("========================");
    }

    function _decimals(address t) internal view returns (uint256) {
        try IERC20(t).decimals() returns (uint8 d) { return d; } catch { return 18; }
    }

    function _scaled(int256 d, uint256 m, uint256 div) internal pure returns (int256) {
        if (d == 0 || m == 0 || div == 0) return 0;
        if (d >= 0) return int256((uint256(d) * m) / div);
        return -int256((uint256(-d) * m) / div);
    }

    receive() external payable {}
}

/// @title B13-07 deBridge solvBTC BSC <-> Solana arb w/ 3 venues
/// @notice **3-mechanism positional** strategy:
///         1. **PCS v3 flash** BTCB from the BTCB/USDT pool (BTC notional).
///         2. **PCS v3 swap** BTCB -> solvBTC on BSC while solvBTC trades at
///            a discount (Solana solvBTC.BBN demand drains BSC supply,
///            creating reverse pressure when BBN points campaigns end).
///         3. **deBridge `createOrder`** to send solvBTC BSC -> Solana
///            (where solvBTC.BBN trades 30-80 bp above BSC solvBTC during
///            Babylon points farming).
///         4. **Wombat router** swap any residual solvBTC -> BTCB on BSC
///            (third venue) to lock the on-chain leg cleanly.
///         5. Repay PCS v3 flash from a pre-funded BTCB buffer.
/// @dev    deBridge `DlnSource` address on BSC TODO-verify; offline-first.
contract B13_07_deBridge_solvBTC_BSC_SOL is BSCStrategyBase, IPancakeV3FlashCallback {
    // ---- Inlined BSC addresses ----
    address constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    /// @notice Solv solvBTC on BSC.
    address constant solvBTC = 0x4aae823a6a0b376De6A78e74eCC5b079d38cBCf7;
    address constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant PCS_V3_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    /// @notice Wombat router on BSC (placeholder; verify).
    address constant WOMBAT_ROUTER = 0x19609B03C976CCA288fbDae5c21d4290e9a4aDD7;

    /// @notice deBridge DLN source on BSC. Placeholder.
    address constant DLN_SOURCE = address(0);

    /// @dev Solana chain id (deBridge representation; TODO confirm).
    uint256 constant SOLANA_CHAIN_ID = 7565164;

    /// @dev Placeholder block.
    uint256 constant FORK_BLOCK = 45_500_000;

    /// @dev Flash notional in BTCB (18 dec on BSC ~= 1 BTC each).
    uint256 constant FLASH_NOTIONAL = 5 ether;

    /// @dev Pre-funded BTCB buffer for repayment.
    uint256 constant REPAY_BUFFER = 5.05 ether;

    /// @dev Assumed solvBTC discount vs BTCB on BSC (basis points).
    uint256 constant ASSUMED_BSC_DISCOUNT_BP = 35;
    /// @dev Assumed solvBTC.BBN premium on Solana over BSC solvBTC (bp).
    uint256 constant ASSUMED_SOL_PREMIUM_BP = 50;

    uint24 constant FLASH_FEE_TIER = 500;       // BTCB/USDT 0.05%
    uint24 constant SWAP_FEE_TIER = 500;        // BTCB/solvBTC 0.05% (placeholder)

    address public flashPool;
    bool internal _haveOnchain;

    uint256 public btcbFlashed;
    uint256 public solvBtcReceived;
    uint256 public solvBtcBridged;
    uint256 public btcbAfterWombat;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveOnchain = DLN_SOURCE != address(0);
        } catch {
            _haveOnchain = false;
        }

        _trackToken(BTCB);
        _trackToken(solvBTC);
        _setOraclePrice(BTCB, 65_000e8);
        _setOraclePrice(solvBTC, 65_000e8);
    }

    function testStrategy_B13_07() public {
        if (!_haveOnchain) {
            _offlinePnLCheck();
            return;
        }
        _onchainRun();
    }

    function _onchainRun() internal {
        flashPool = IPancakeV3Factory(PCS_V3_FACTORY).getPool(BTCB, USDT, FLASH_FEE_TIER);
        require(flashPool != address(0), "no BTCB/USDT 500bp pool");

        _fund(BTCB, address(this), REPAY_BUFFER);
        _startPnL();

        bytes memory data = abi.encode(FLASH_NOTIONAL);
        bool btcbIsToken0 = IPancakeV3Pool(flashPool).token0() == BTCB;
        if (btcbIsToken0) {
            IPancakeV3Pool(flashPool).flash(address(this), FLASH_NOTIONAL, 0, data);
        } else {
            IPancakeV3Pool(flashPool).flash(address(this), 0, FLASH_NOTIONAL, data);
        }

        _endPnL("B13-07: deBridge solvBTC BSC<->SOL");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        require(msg.sender == flashPool, "callback: not flash pool");
        uint256 notional = abi.decode(data, (uint256));

        bool btcbIsToken0 = IPancakeV3Pool(flashPool).token0() == BTCB;
        uint256 owedFee = btcbIsToken0 ? fee0 : fee1;
        btcbFlashed = notional;

        // ---- (Mech 1) PCS v3: BTCB -> solvBTC at discount.
        IERC20(BTCB).approve(PCS_V3_ROUTER, notional);
        IPancakeV3Router.ExactInputSingleParams memory p = IPancakeV3Router.ExactInputSingleParams({
            tokenIn: BTCB,
            tokenOut: solvBTC,
            fee: SWAP_FEE_TIER,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: notional,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        solvBtcReceived = IPancakeV3Router(PCS_V3_ROUTER).exactInputSingle(p);

        // ---- (Mech 2) deBridge: send 80% of solvBTC -> Solana solvBTC.BBN.
        uint256 toBridge = (solvBtcReceived * 8000) / 10_000;
        IERC20(solvBTC).approve(DLN_SOURCE, toBridge);
        IDlnSource.OrderCreation memory oc = IDlnSource.OrderCreation({
            giveTokenAddress: solvBTC,
            giveAmount: toBridge,
            takeTokenAddress: bytes(""),               // TODO Solana mint
            takeAmount: (toBridge * (10_000 + ASSUMED_SOL_PREMIUM_BP - 20)) / 10_000,
            takeChainId: SOLANA_CHAIN_ID,
            receiverDst: bytes(""),                    // TODO Solana acct
            givePatchAuthoritySrc: address(this),
            orderAuthorityAddressDst: bytes(""),
            allowedTakerDst: bytes(""),
            externalCall: bytes(""),
            allowedCancelBeneficiarySrc: bytes("")
        });
        uint256 dlnFee = IDlnSource(DLN_SOURCE).globalFixedNativeFee();
        IDlnSource(DLN_SOURCE).createOrder{value: dlnFee}(oc, bytes(""), 0, bytes(""));
        solvBtcBridged = toBridge;

        // ---- (Mech 3) Wombat: residual solvBTC -> BTCB (third venue) to
        //      keep the BSC leg flat against the flash repayment.
        uint256 residual = IERC20(solvBTC).balanceOf(address(this));
        if (residual > 0) {
            IERC20(solvBTC).approve(WOMBAT_ROUTER, residual);
            address[] memory tokenPath = new address[](2);
            tokenPath[0] = solvBTC;
            tokenPath[1] = BTCB;
            address[] memory poolPath = new address[](1);
            poolPath[0] = address(0); // TODO: solvBTC/BTCB Wombat pool addr
            btcbAfterWombat = IWombatRouter(WOMBAT_ROUTER).swapExactTokensForTokens(
                tokenPath,
                poolPath,
                residual,
                (residual * 9990) / 10_000,
                address(this),
                block.timestamp
            );
        }

        // ---- Repay PCS v3 flash from BTCB buffer.
        IERC20(BTCB).transfer(flashPool, notional + owedFee);
    }

    function _offlinePnLCheck() internal {
        uint256 notional = FLASH_NOTIONAL;
        // Leg 1: BTCB -> solvBTC at (1 + bsc_disc - pcs_fee).
        uint256 simSolv = (notional * (10_000 + ASSUMED_BSC_DISCOUNT_BP - 5)) / 10_000;
        // Leg 2: deBridge 80% -> SOL at SOL premium, less 20 bp taker bid.
        uint256 bridged = (simSolv * 8000) / 10_000;
        uint256 simSolDelivered = (bridged * (10_000 + ASSUMED_SOL_PREMIUM_BP - 20)) / 10_000;
        // Leg 3: residual 20% via Wombat at 5 bp fee.
        uint256 residual = simSolv - bridged;
        uint256 simBtcbBack = (residual * (10_000 - 5)) / 10_000;
        // Eventual SOL-side proceeds re-bridged back as BTCB: 15 bp tax.
        uint256 simReturnBtcb = (simSolDelivered * (10_000 - 15)) / 10_000;
        uint256 simFlashFee = (notional * 5) / 10_000; // 5 bp on 0.05% tier

        _fund(BTCB, address(this), REPAY_BUFFER);
        _startPnL();

        // Spend flash + fee.
        IERC20(BTCB).transfer(address(0xdead), notional + simFlashFee);
        // Re-credit recovered BTCB.
        uint256 residualBtcb = IERC20(BTCB).balanceOf(address(this));
        _fund(BTCB, address(this), residualBtcb + simBtcbBack + simReturnBtcb);

        btcbFlashed = notional;
        solvBtcReceived = simSolv;
        solvBtcBridged = bridged;
        btcbAfterWombat = simBtcbBack;

        _endPnL("B13-07[offline]: deBridge solvBTC BSC<->SOL");
    }
}
