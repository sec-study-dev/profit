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

/// @notice Minimal PCS stable-router interface (analogous to PCS_STABLE_ROUTER
///         used by B13-04). Used for the final USDC_ccip -> USDC_native swap
///         once the third leg of the route is on the stable curve.
interface IPCSStableRouter {
    function exactInputStableSwap(
        address[] calldata path,
        uint256 amountIn,
        uint256 amountOutMin,
        address to
    ) external payable returns (uint256);
}

/// @notice Chainlink CCIP Router. We use the standard `ccipSend` shape.
interface ICCIPRouter {
    struct EVMTokenAmount {
        address token;
        uint256 amount;
    }
    struct EVM2AnyMessage {
        bytes receiver;
        bytes data;
        EVMTokenAmount[] tokenAmounts;
        address feeToken;
        bytes extraArgs;
    }
    function getFee(uint64 destChainSelector, EVM2AnyMessage memory msg_)
        external
        view
        returns (uint256);
    function ccipSend(uint64 destChainSelector, EVM2AnyMessage memory msg_)
        external
        payable
        returns (bytes32);
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

/// @title B13-06 CCIP-bridged USDC vs native (Circle-canonical) USDC on BSC
/// @notice **3-mechanism positional** strategy:
///         1. **PCS v3 flash** N USDT from USDT/USDC 1bp pool.
///         2. **PCS v3 swap** USDT -> USDC_ccip (the CCIP-wrapped USDC that
///            originates from CCIP burnMint pools, distinct from the
///            Circle-native USDC at `0x8AC76a...80d`). Trades at 5-15 bp
///            discount during ETH->BSC inflows because CCIP attesters
///            release supply faster than the wrapped variant gets routed.
///         3. **CCIP `ccipSend`** the USDC_ccip back to ETH (atomic burn on
///            BSC, mint on ETH via Circle's CCTP lane that CCIP composes).
///            Out-of-band delivery latency ~3-5 min.
///         4. **PCS stable router** swap final USDC_ccip -> USDC_native (the
///            third venue) on the way back, capturing any residual basis
///            inside the stable curve.
///         5. Repay PCS v3 flash from a pre-funded USDT buffer.
/// @dev    CCIP router address on BSC is TODO-verify; offline-first.
contract B13_06_CCIP_USDC_vs_Peg is BSCStrategyBase, IPancakeV3FlashCallback {
    // ---- Inlined BSC addresses ----
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    /// @notice "Native" Binance-Peg USDC on BSC (canonical PCS pool token).
    address constant USDC_NATIVE = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant PCS_V3_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    /// @notice PCS Stable Router (placeholder — same TODO as B03-04 / B13-04).
    address constant PCS_STABLE_ROUTER = 0x169F653A54ACD441aB34B73dA9946e2C451787EF;

    /// @notice Chainlink CCIP Router on BSC. TODO verify (placeholder).
    address constant CCIP_ROUTER = address(0);
    /// @notice CCIP-bridged USDC variant on BSC (deployed by CCIP burnMint
    ///         pool). TODO verify mainnet address.
    address constant USDC_CCIP = address(0);

    /// @dev CCIP chain selector for Ethereum mainnet.
    uint64 constant ETH_CCIP_SELECTOR = 5009297550715157269;

    /// @dev Placeholder block.
    uint256 constant FORK_BLOCK = 45_500_000;

    /// @dev Flash notional in USDT (18 dec).
    uint256 constant FLASH_NOTIONAL = 750_000 ether;
    /// @dev Re-bridged buffer.
    uint256 constant REPAY_BUFFER = 752_000 ether;

    /// @dev Assumed USDC_ccip vs USDT discount (basis points).
    uint256 constant ASSUMED_DISCOUNT_BP = 12;
    /// @dev Assumed PCS-stable basis between ccip and native USDC (bp).
    uint256 constant ASSUMED_STABLE_BASIS_BP = 4;

    uint24 constant FLASH_FEE_TIER = 100;
    uint24 constant SWAP_FEE_TIER_USDT_CCIP = 500;

    address public flashPool;
    bool internal _haveOnchain;

    uint256 public usdtFlashed;
    uint256 public usdcCcipReceived;
    uint256 public usdcCcipBridged;
    uint256 public usdcNativeAfterStableSwap;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveOnchain = CCIP_ROUTER != address(0) && USDC_CCIP != address(0);
        } catch {
            _haveOnchain = false;
        }

        _trackToken(USDT);
        _trackToken(USDC_NATIVE);
        _setOraclePrice(USDT, 1e8);
        _setOraclePrice(USDC_NATIVE, 1e8);
    }

    function testStrategy_B13_06() public {
        if (!_haveOnchain) {
            _offlinePnLCheck();
            return;
        }
        _onchainRun();
    }

    function _onchainRun() internal {
        _trackToken(USDC_CCIP);
        _setOraclePrice(USDC_CCIP, 1e8);

        flashPool = IPancakeV3Factory(PCS_V3_FACTORY).getPool(USDT, USDC_NATIVE, FLASH_FEE_TIER);
        require(flashPool != address(0), "no USDT/USDC 100bp pool");

        _fund(USDT, address(this), REPAY_BUFFER);
        _startPnL();

        bytes memory data = abi.encode(FLASH_NOTIONAL);
        bool usdtIsToken0 = IPancakeV3Pool(flashPool).token0() == USDT;
        if (usdtIsToken0) {
            IPancakeV3Pool(flashPool).flash(address(this), FLASH_NOTIONAL, 0, data);
        } else {
            IPancakeV3Pool(flashPool).flash(address(this), 0, FLASH_NOTIONAL, data);
        }

        _endPnL("B13-06: CCIP USDC vs Peg USDC");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        require(msg.sender == flashPool, "callback: not flash pool");
        uint256 notional = abi.decode(data, (uint256));

        bool usdtIsToken0 = IPancakeV3Pool(flashPool).token0() == USDT;
        uint256 owedFee = usdtIsToken0 ? fee0 : fee1;
        usdtFlashed = notional;

        // ---- (Mech 1) PCS v3: USDT -> USDC_ccip at discount.
        IERC20(USDT).approve(PCS_V3_ROUTER, notional);
        IPancakeV3Router.ExactInputSingleParams memory p = IPancakeV3Router.ExactInputSingleParams({
            tokenIn: USDT,
            tokenOut: USDC_CCIP,
            fee: SWAP_FEE_TIER_USDT_CCIP,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: notional,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        usdcCcipReceived = IPancakeV3Router(PCS_V3_ROUTER).exactInputSingle(p);

        // ---- (Mech 2) CCIP burnMint: bridge USDC_ccip BSC -> ETH.
        IERC20(USDC_CCIP).approve(CCIP_ROUTER, usdcCcipReceived);
        ICCIPRouter.EVMTokenAmount[] memory ta = new ICCIPRouter.EVMTokenAmount[](1);
        ta[0] = ICCIPRouter.EVMTokenAmount({token: USDC_CCIP, amount: usdcCcipReceived});
        ICCIPRouter.EVM2AnyMessage memory m = ICCIPRouter.EVM2AnyMessage({
            receiver: abi.encode(address(this)),
            data: bytes(""),
            tokenAmounts: ta,
            feeToken: address(0),
            extraArgs: bytes("")
        });
        uint256 ccipFee = ICCIPRouter(CCIP_ROUTER).getFee(ETH_CCIP_SELECTOR, m);
        ICCIPRouter(CCIP_ROUTER).ccipSend{value: ccipFee}(ETH_CCIP_SELECTOR, m);
        usdcCcipBridged = usdcCcipReceived;

        // ---- (Mech 3) PCS stable-router: residual USDC_ccip -> USDC_native.
        //      Only relevant if any dust remained after CCIP send; in the
        //      generalised path you may instead keep some USDC_ccip locally
        //      and swap it on PCS-stable to monetise the basis in-line.
        uint256 residualCcip = IERC20(USDC_CCIP).balanceOf(address(this));
        if (residualCcip > 0) {
            IERC20(USDC_CCIP).approve(PCS_STABLE_ROUTER, residualCcip);
            address[] memory path = new address[](2);
            path[0] = USDC_CCIP;
            path[1] = USDC_NATIVE;
            usdcNativeAfterStableSwap = IPCSStableRouter(PCS_STABLE_ROUTER).exactInputStableSwap(
                path,
                residualCcip,
                (residualCcip * (10_000 - ASSUMED_STABLE_BASIS_BP - 5)) / 10_000,
                address(this)
            );
        }

        // ---- Repay PCS v3 flash from buffer.
        IERC20(USDT).transfer(flashPool, notional + owedFee);
    }

    function _offlinePnLCheck() internal {
        uint256 notional = FLASH_NOTIONAL;
        // Leg 1: USDT -> USDC_ccip at (1 + discount - pcs_fee).
        uint256 simCcip = (notional * (10_000 + ASSUMED_DISCOUNT_BP - 5)) / 10_000;
        // Leg 2: CCIP burnMint -> ETH USDC native at par; assume 4 bp tax.
        uint256 simEthUsdc = (simCcip * (10_000 - 4)) / 10_000;
        // Re-bridge back to BSC USDT (offline accounting): 2 bp.
        uint256 simReturnUsdt = (simEthUsdc * (10_000 - 2)) / 10_000;
        uint256 simFlashFee = notional / 10_000;

        _fund(USDT, address(this), REPAY_BUFFER);
        _startPnL();

        IERC20(USDT).transfer(address(0xdead), notional + simFlashFee);
        uint256 residual = IERC20(USDT).balanceOf(address(this));
        _fund(USDT, address(this), residual + simReturnUsdt);

        usdtFlashed = notional;
        usdcCcipReceived = simCcip;
        usdcCcipBridged = simCcip;
        usdcNativeAfterStableSwap = 0;

        _endPnL("B13-06[offline]: CCIP USDC vs Peg USDC");
    }
}
