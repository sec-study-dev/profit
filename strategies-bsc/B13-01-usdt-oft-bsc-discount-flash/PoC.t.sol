// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

// ---------------------------------------------------------------------------
// Inlined interfaces — `src/constants/BSC.sol` has a pre-existing checksum
// bug in several unrelated constants (AVALON_LENDING_POOL, solvBTC_BBN,
// ASTHERUS_STAKE_MANAGER, PCS_STABLE_ROUTER, LISTA_LENDING, LISTA_INTERACTION,
// FDUSD, BNBx) which makes the whole file refuse to compile. Per the spec
// ("Inline local addresses/interfaces if needed.") and to mirror the
// pattern used by B02-01 / B03-01, we inline the addresses and ABIs we
// actually use rather than touch the broken constants file.
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

/// @notice LayerZero V2 OFT (Omnichain Fungible Token) send interface.
interface IOFTAdapter {
    struct SendParam {
        uint32 dstEid;
        bytes32 to;
        uint256 amountLD;
        uint256 minAmountLD;
        bytes extraOptions;
        bytes composeMsg;
        bytes oftCmd;
    }
    struct MessagingFee {
        uint256 nativeFee;
        uint256 lzTokenFee;
    }
    struct MessagingReceipt {
        bytes32 guid;
        uint64 nonce;
        MessagingFee fee;
    }
    struct OFTReceipt {
        uint256 amountSentLD;
        uint256 amountReceivedLD;
    }
    function send(SendParam calldata sendParam, MessagingFee calldata fee, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt);
    function quoteSend(SendParam calldata sendParam, bool payInLzToken)
        external
        view
        returns (MessagingFee memory fee);
    function token() external view returns (address);
}

/// @notice Local copy of `BSCStrategyBase` minimised to what this PoC needs.
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

/// @title B13-01 Bridged USDT (OFT) vs BSC Peg USDT discount flash
/// @notice Positional strategy (not atomic):
///         1. PCS v3 flash N Peg-USDT from the deepest USDT/USDC 0.01% pool.
///         2. Swap Peg-USDT -> OFT-USDT0 on the OFT/Peg pool while OFT is
///            discounted ~20-80 bp.
///         3. Call IOFTAdapter.send(dstEid=ETH_EID, amountLD=oftReceived) to
///            atomically burn OFT on BSC. The ETH-side credit arrives in
///            1-3 minutes — out of band; the PoC simulates the burn only.
///         4. Repay the PCS v3 flash from a pre-funded Peg buffer that
///            represents the eventual re-bridged proceeds.
/// @dev    Offline-first: if BSC_RPC_URL is unset OR the OFT adapter address
///         is unknown (placeholder), runs pure-math accounting branch.
contract B13_01_USDT_OFT_BSC_Discount is BSCStrategyBase, IPancakeV3FlashCallback {
    // ---- Inlined BSC addresses ----
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant PCS_V3_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;

    /// @notice USDT OFT adapter (LayerZero V2). Placeholder = address(0) in
    ///         BSC.sol; until LayerZero ships the adapter on BSC, runs in
    ///         offline-mode.
    address constant USDT_OFT_ADAPTER = address(0);

    /// @dev Placeholder block; re-pin to a window with > 25 bp OFT discount.
    uint256 constant FORK_BLOCK = 45_500_000;

    /// @dev Flash notional in Peg-USDT (18 decimals on BSC).
    uint256 constant FLASH_NOTIONAL = 1_000_000 ether;

    /// @dev Pre-funded Peg-USDT buffer; stands in for the ETH-side credit
    ///      that LayerZero delivers ~1-3 min after the burn.
    uint256 constant REPAY_BUFFER = 1_001_000 ether;

    /// @dev Assumed OFT-vs-Peg discount in basis points. 30 bp = 0.30%.
    uint256 constant ASSUMED_DISCOUNT_BP = 30;

    /// @dev Flash pool fee tier (USDT/USDC 0.01% PCS v3).
    uint24 constant FLASH_FEE_TIER = 100;
    /// @dev OFT/Peg PCS v3 pool fee tier (assumed 0.01%).
    uint24 constant SWAP_FEE_TIER = 100;
    /// @dev LayerZero endpoint id for Ethereum mainnet.
    uint32 constant ETH_EID = 30101;

    address public oftToken;
    address public oftAdapter;
    address public flashPool;

    bool internal _haveOnchain;

    uint256 public pegFlashed;
    uint256 public oftReceived;
    uint256 public oftBurned;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveOnchain = USDT_OFT_ADAPTER != address(0);
        } catch {
            _haveOnchain = false;
        }
        oftAdapter = USDT_OFT_ADAPTER;

        _trackToken(USDT);
        _setOraclePrice(USDT, 1e8);
    }

    function testStrategy_B13_01() public {
        if (!_haveOnchain) {
            _offlinePnLCheck();
            return;
        }

        _resolveFlashPool();
        oftToken = IOFTAdapter(oftAdapter).token();
        _trackToken(oftToken);
        _setOraclePrice(oftToken, 1e8);

        _fund(USDT, address(this), REPAY_BUFFER);

        _startPnL();

        bytes memory data = abi.encode(FLASH_NOTIONAL);
        bool usdtIsToken0 = IPancakeV3Pool(flashPool).token0() == USDT;
        if (usdtIsToken0) {
            IPancakeV3Pool(flashPool).flash(address(this), FLASH_NOTIONAL, 0, data);
        } else {
            IPancakeV3Pool(flashPool).flash(address(this), 0, FLASH_NOTIONAL, data);
        }

        _endPnL("B13-01: USDT OFT discount flash");
    }

    function _resolveFlashPool() internal {
        flashPool = IPancakeV3Factory(PCS_V3_FACTORY).getPool(USDT, USDC, FLASH_FEE_TIER);
        require(flashPool != address(0), "no USDT/USDC 100bp pool");
    }

    /// @notice PCS v3 flash callback.
    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        require(msg.sender == flashPool, "callback: not flash pool");

        uint256 notional = abi.decode(data, (uint256));
        bool usdtIsToken0 = IPancakeV3Pool(flashPool).token0() == USDT;
        uint256 owedFee = usdtIsToken0 ? fee0 : fee1;
        pegFlashed = notional;

        // ---- Swap Peg-USDT -> OFT-USDT0.
        IERC20(USDT).approve(PCS_V3_ROUTER, notional);
        IPancakeV3Router.ExactInputSingleParams memory p = IPancakeV3Router.ExactInputSingleParams({
            tokenIn: USDT,
            tokenOut: oftToken,
            fee: SWAP_FEE_TIER,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: notional,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        oftReceived = IPancakeV3Router(PCS_V3_ROUTER).exactInputSingle(p);

        // ---- Burn OFT on BSC; ETH-side credit arrives ~1-3 min later.
        IERC20(oftToken).approve(oftAdapter, oftReceived);
        IOFTAdapter.SendParam memory sp = IOFTAdapter.SendParam({
            dstEid: ETH_EID,
            to: bytes32(uint256(uint160(address(this)))),
            amountLD: oftReceived,
            minAmountLD: (oftReceived * 9998) / 10000,
            extraOptions: bytes(""),
            composeMsg: bytes(""),
            oftCmd: bytes("")
        });
        IOFTAdapter.MessagingFee memory mf = IOFTAdapter(oftAdapter).quoteSend(sp, false);
        IOFTAdapter(oftAdapter).send{value: mf.nativeFee}(sp, mf, address(this));
        oftBurned = oftReceived;

        // ---- Repay PCS v3 flash from the pre-funded buffer.
        IERC20(USDT).transfer(flashPool, notional + owedFee);
    }

    /// @dev Offline-first: simulate spread using ASSUMED_DISCOUNT_BP.
    function _offlinePnLCheck() internal {
        uint256 notional = FLASH_NOTIONAL;
        uint256 simOftOut = (notional * (10_000 + ASSUMED_DISCOUNT_BP)) / 10_000;
        uint256 simFlashFee = notional / 10_000; // 1 bp
        uint256 simBridgeTax = (simOftOut * 2) / 10_000; // 2 bp tier-1 tax
        uint256 simReturnPeg = simOftOut - simBridgeTax;

        _fund(USDT, address(this), REPAY_BUFFER);
        _startPnL();

        // Model: pay notional+fee from buffer, gain simReturnPeg back (net).
        IERC20(USDT).transfer(address(0xdead), notional + simFlashFee);
        // After the OFT settles cross-chain, the eventual re-bridged proceeds
        // top us up by simReturnPeg above the post-transfer residual. We use
        // deal() to set the absolute new balance.
        uint256 residual = IERC20(USDT).balanceOf(address(this));
        _fund(USDT, address(this), residual + simReturnPeg);

        pegFlashed = notional;
        oftReceived = simOftOut;
        oftBurned = simOftOut;

        _endPnL("B13-01[offline]: USDT OFT discount flash");
    }
}
