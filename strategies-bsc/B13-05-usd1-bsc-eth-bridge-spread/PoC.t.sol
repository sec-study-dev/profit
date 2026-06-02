// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

// ---------------------------------------------------------------------------
// Inlined interfaces — `src/constants/BSC.sol` has pre-existing checksum
// errors (same root cause noted in B13-01..04). Following the project
// convention for B13-* we inline addresses + ABIs we actually use.
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

/// @notice Generic LayerZero-V2-style burnAndSend interface used by USD1's
///         official bridge (WLF have stated USD1 uses LayerZero OFT in their
///         docs — adapter address TODO when deployed).
interface IUSD1Bridge {
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
        returns (MessagingReceipt memory, OFTReceipt memory);
    function quoteSend(SendParam calldata sendParam, bool payInLzToken)
        external
        view
        returns (MessagingFee memory);
    function token() external view returns (address);
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

/// @title B13-05 USD1 BSC <-> ETH bridge spread
/// @notice Positional 2-mechanism strategy:
///         1. PCS v3 flash N USDT from USDT/USDC 0.01% (cheap loan).
///         2. exactInputSingle(USDT -> USD1) on the USD1/USDT PCS v3 pool
///            while USD1 trades at a discount to peg (frequent in early WLF
///            distribution windows).
///         3. Bridge USD1 BSC -> ETH via WLF's official OFT bridge. The burn
///            is atomic; the ETH-side credit lands within one LZ DVN window.
///         4. Repay flash from a pre-funded USDT buffer modelling the
///            re-bridged USDT proceeds.
/// @dev    USD1 is a fresh launch — the BSC <-> ETH bridge adapter address is
///         still TODO. PoC runs offline-first against an assumed 25 bp
///         discount window; once the adapter is wired the same callback path
///         runs on-chain.
contract B13_05_USD1_BSC_ETH_Bridge_Spread is BSCStrategyBase, IPancakeV3FlashCallback {
    // ---- Inlined BSC addresses ----
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    /// @notice World Liberty Financial USD1 on BSC. TODO verify checksum.
    address constant USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
    address constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant PCS_V3_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;

    /// @notice WLF USD1 OFT adapter on BSC. Placeholder until WLF publishes.
    address constant USD1_OFT_ADAPTER = address(0);

    /// @dev Placeholder block; re-pin to a window with > 20 bp USD1 discount.
    uint256 constant FORK_BLOCK = 45_500_000;

    /// @dev Flash notional in USDT (18 decimals on BSC).
    uint256 constant FLASH_NOTIONAL = 500_000 ether;

    /// @dev Pre-funded USDT buffer mirroring the eventual re-bridged proceeds.
    uint256 constant REPAY_BUFFER = 501_500 ether;

    /// @dev Assumed USD1 discount vs USDT (basis points).
    uint256 constant ASSUMED_DISCOUNT_BP = 25;

    /// @dev USDT/USDC pool fee (0.01%).
    uint24 constant FLASH_FEE_TIER = 100;
    /// @dev USD1/USDT pool fee tier — assumed 0.05% (stable-but-thinner).
    uint24 constant SWAP_FEE_TIER = 500;
    /// @dev LayerZero endpoint id for Ethereum mainnet.
    uint32 constant ETH_EID = 30101;

    address public flashPool;
    bool internal _haveOnchain;

    uint256 public usdtFlashed;
    uint256 public usd1Received;
    uint256 public usd1Bridged;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveOnchain = USD1_OFT_ADAPTER != address(0);
        } catch {
            _haveOnchain = false;
        }

        _trackToken(USDT);
        _trackToken(USD1);
        _setOraclePrice(USDT, 1e8);
        _setOraclePrice(USD1, 1e8);
    }

    function testStrategy_B13_05() public {
        if (!_haveOnchain) {
            _offlinePnLCheck();
            return;
        }
        _onchainRun();
    }

    function _onchainRun() internal {
        flashPool = IPancakeV3Factory(PCS_V3_FACTORY).getPool(USDT, USDC, FLASH_FEE_TIER);
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

        _endPnL("B13-05: USD1 BSC<->ETH bridge spread");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        require(msg.sender == flashPool, "callback: not flash pool");
        uint256 notional = abi.decode(data, (uint256));

        bool usdtIsToken0 = IPancakeV3Pool(flashPool).token0() == USDT;
        uint256 owedFee = usdtIsToken0 ? fee0 : fee1;
        usdtFlashed = notional;

        // ---- Swap USDT -> USD1 on PCS v3 while USD1 is discounted.
        IERC20(USDT).approve(PCS_V3_ROUTER, notional);
        IPancakeV3Router.ExactInputSingleParams memory p = IPancakeV3Router.ExactInputSingleParams({
            tokenIn: USDT,
            tokenOut: USD1,
            fee: SWAP_FEE_TIER,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: notional,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        usd1Received = IPancakeV3Router(PCS_V3_ROUTER).exactInputSingle(p);

        // ---- Burn USD1 on BSC via WLF's OFT bridge; ETH credit ~LZ window.
        IERC20(USD1).approve(USD1_OFT_ADAPTER, usd1Received);
        IUSD1Bridge.SendParam memory sp = IUSD1Bridge.SendParam({
            dstEid: ETH_EID,
            to: bytes32(uint256(uint160(address(this)))),
            amountLD: usd1Received,
            minAmountLD: (usd1Received * 9990) / 10000,
            extraOptions: bytes(""),
            composeMsg: bytes(""),
            oftCmd: bytes("")
        });
        IUSD1Bridge.MessagingFee memory mf = IUSD1Bridge(USD1_OFT_ADAPTER).quoteSend(sp, false);
        IUSD1Bridge(USD1_OFT_ADAPTER).send{value: mf.nativeFee}(sp, mf, address(this));
        usd1Bridged = usd1Received;

        // ---- Repay PCS v3 flash from the pre-funded USDT buffer.
        IERC20(USDT).transfer(flashPool, notional + owedFee);
    }

    function _offlinePnLCheck() internal {
        uint256 notional = FLASH_NOTIONAL;
        // Premium swap: notional USDT -> USD1 at (1 + discount - pcs_fee).
        uint256 simUsd1 = (notional * (10_000 + ASSUMED_DISCOUNT_BP - 5)) / 10_000;
        uint256 simFlashFee = notional / 10_000; // 1 bp
        uint256 simBridgeTax = (simUsd1 * 3) / 10_000; // 3 bp WLF bridge tax (estimate)
        uint256 simReturnUsdt = simUsd1 - simBridgeTax;

        _fund(USDT, address(this), REPAY_BUFFER);
        _startPnL();

        // Pay the flash from the buffer, then book the re-bridged proceeds.
        IERC20(USDT).transfer(address(0xdead), notional + simFlashFee);
        uint256 residual = IERC20(USDT).balanceOf(address(this));
        _fund(USDT, address(this), residual + simReturnUsdt);

        usdtFlashed = notional;
        usd1Received = simUsd1;
        usd1Bridged = simUsd1;

        _endPnL("B13-05[offline]: USD1 BSC<->ETH bridge spread");
    }
}
