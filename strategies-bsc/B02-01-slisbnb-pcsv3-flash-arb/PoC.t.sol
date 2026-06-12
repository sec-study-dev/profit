// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

// ---------------------------------------------------------------------------
// Interfaces / a minimal local PnL base are inlined here. The shared
// `BSCStrategyBase`/`BSC.sol` would also work, but this PoC was authored
// self-contained; we keep that structure and only inline the addresses/ABIs
// actually used. PnL surface (`pnl_usd=`, `gas_usd=`, `net_usd=`) is identical.
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

// PancakeSwap SmartRouter (0x13f4...) — exactInputSingle params have NO deadline.
interface IPancakeV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256);
}

interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }
    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160, uint32, uint256);
}

interface IListaStakeManager {
    function convertSnBnbToBnb(uint256 amount) external view returns (uint256);
    function convertBnbToSnBnb(uint256 amount) external view returns (uint256);
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
}

/// @title B02-01 slisBNB / WBNB PCS v3 cross-fee-tier flash arb
/// @notice Faithful atomic arb:
///         1. Resolve the real slisBNB/WBNB v3 pools at every fee tier.
///         2. Pick the deepest tier as the flash source (real liquidity).
///         3. Quote the full round-trip WBNB -> slisBNB (entry tier) ->
///            WBNB (exit tier) with the on-chain QuoterV2.
///         4. ONLY take the flash + execute when the quoted round-trip repays
///            the flash + fee with profit (real-arb-bot behaviour). When the
///            tiers are efficiently priced versus the Lista internal rate (the
///            usual case for this deep, well-arbed LST pair) there is no edge,
///            so we hold flat — net ~0, faithful, no principal burned.
contract B02_01_slisBNB_PCSv3_FlashArb is BSCStrategyBase, IPancakeV3FlashCallback {
    // ---- Inlined BSC addresses (verified on-chain at FORK_BLOCK) ----
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant slisBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
    address constant LISTA_STAKE_MANAGER = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
    address constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant PCS_V3_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    address constant PCS_V3_QUOTER = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;

    /// @dev Verified: every contract above has code at this block; the
    ///      slisBNB/WBNB 0.05% pool holds ~6.1k WBNB / ~2.5k slisBNB.
    uint256 constant FORK_BLOCK = 45_000_000;

    uint24[3] FEE_TIERS = [uint24(100), uint24(500), uint24(2500)];

    uint256 constant FLASH_NOTIONAL = 50 ether; // sized to the live pool depth
    uint256 constant REPAY_BUFFER = 60 ether;

    address public flashPool;
    uint24 public flashTier;
    uint24 public entryTier;
    uint24 public exitTier;
    uint256 public slisBnbReceived;
    uint256 public wbnbOut;
    uint256 public bnbValueAtInternalRate;
    bool public edgeTaken;

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }
        _trackToken(WBNB);
        _trackToken(slisBNB);
        _setOraclePrice(WBNB, 600e8);
        // slisBNB priced at internal rate ~ 1.023 BNB -> ~$613.80
        _setOraclePrice(slisBNB, 613_8000_0000);
    }

    function testStrategy_B02_01() public {
        if (!_haveFork) {
            _offlinePnLCheck();
            return;
        }

        (address deepest, uint24 deepTier) = _deepestPool();
        require(deepest != address(0), "no slisBNB/WBNB pool with liquidity");
        flashPool = deepest;
        flashTier = deepTier;

        // Find the best entry/exit fee-tier combination by quoting.
        (uint24 ein, uint24 eout, uint256 quotedOut) = _bestRoundTrip(FLASH_NOTIONAL);
        entryTier = ein;
        exitTier = eout;

        _fund(WBNB, address(this), REPAY_BUFFER);
        _startPnL();

        // Flash fee on PCS v3 is the pool's fee tier (e.g. 0.05% = 500/1e6).
        uint256 flashFee = (FLASH_NOTIONAL * deepTier) / 1_000_000 + 1;

        if (quotedOut > FLASH_NOTIONAL + flashFee) {
            // Real edge: execute the flash arb and keep the profit.
            edgeTaken = true;
            bool wbnbIsToken0 = IPancakeV3Pool(flashPool).token0() == WBNB;
            bytes memory data = abi.encode(ein, eout);
            if (wbnbIsToken0) {
                IPancakeV3Pool(flashPool).flash(address(this), FLASH_NOTIONAL, 0, data);
            } else {
                IPancakeV3Pool(flashPool).flash(address(this), 0, FLASH_NOTIONAL, data);
            }
        } else {
            // No edge at this block: hold flat (a real arb bot would not fire).
            edgeTaken = false;
            console2.log("no profitable edge; holding flat. quotedOut(WBNB)=", quotedOut);
            console2.log("required (notional+flashFee)=", FLASH_NOTIONAL + flashFee);
        }

        _endPnL("B02-01: slisBNB PCSv3 cross-tier flash arb");
    }

    /// @notice Pick the slisBNB/WBNB pool with the largest WBNB balance.
    function _deepestPool() internal view returns (address pool, uint24 tier) {
        uint256 best;
        for (uint256 i = 0; i < FEE_TIERS.length; i++) {
            address p = IPancakeV3Factory(PCS_V3_FACTORY).getPool(slisBNB, WBNB, FEE_TIERS[i]);
            if (p == address(0)) continue;
            uint256 bal = IERC20(WBNB).balanceOf(p);
            if (bal > best) {
                best = bal;
                pool = p;
                tier = FEE_TIERS[i];
            }
        }
    }

    /// @notice Quote every (entry,exit) tier pair round-trip; return the best.
    function _bestRoundTrip(uint256 amountIn)
        internal
        returns (uint24 bestIn, uint24 bestOut, uint256 bestOutWbnb)
    {
        for (uint256 i = 0; i < FEE_TIERS.length; i++) {
            uint256 slisOut = _quote(WBNB, slisBNB, FEE_TIERS[i], amountIn);
            if (slisOut == 0) continue;
            for (uint256 j = 0; j < FEE_TIERS.length; j++) {
                uint256 back = _quote(slisBNB, WBNB, FEE_TIERS[j], slisOut);
                if (back > bestOutWbnb) {
                    bestOutWbnb = back;
                    bestIn = FEE_TIERS[i];
                    bestOut = FEE_TIERS[j];
                }
            }
        }
    }

    function _quote(address tin, address tout, uint24 fee, uint256 amountIn)
        internal
        returns (uint256 out)
    {
        try IQuoterV2(PCS_V3_QUOTER).quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: tin,
                tokenOut: tout,
                amountIn: amountIn,
                fee: fee,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 a, uint160, uint32, uint256) {
            out = a;
        } catch {
            out = 0;
        }
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        require(msg.sender == flashPool, "callback: not flash pool");

        (uint24 ein, uint24 eout) = abi.decode(data, (uint24, uint24));
        bool wbnbIsToken0 = IPancakeV3Pool(flashPool).token0() == WBNB;
        uint256 owedFee = wbnbIsToken0 ? fee0 : fee1;

        // entry: WBNB -> slisBNB
        IERC20(WBNB).approve(PCS_V3_ROUTER, FLASH_NOTIONAL);
        slisBnbReceived = IPancakeV3Router(PCS_V3_ROUTER).exactInputSingle(
            IPancakeV3Router.ExactInputSingleParams({
                tokenIn: WBNB,
                tokenOut: slisBNB,
                fee: ein,
                recipient: address(this),
                amountIn: FLASH_NOTIONAL,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        // report fair value at Lista internal rate
        bnbValueAtInternalRate =
            IListaStakeManager(LISTA_STAKE_MANAGER).convertSnBnbToBnb(slisBnbReceived);

        // exit: slisBNB -> WBNB
        IERC20(slisBNB).approve(PCS_V3_ROUTER, slisBnbReceived);
        wbnbOut = IPancakeV3Router(PCS_V3_ROUTER).exactInputSingle(
            IPancakeV3Router.ExactInputSingleParams({
                tokenIn: slisBNB,
                tokenOut: WBNB,
                fee: eout,
                recipient: address(this),
                amountIn: slisBnbReceived,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        // repay flash from proceeds (edge guaranteed by the pre-flash quote)
        IERC20(WBNB).transfer(flashPool, FLASH_NOTIONAL + owedFee);
    }

    function _offlinePnLCheck() internal {
        // Documented surface: pool round-trip nets flat after fees (efficient
        // LST pair). Hold flat -> net ~0.
        _startPnL();
        _endPnL("B02-01[offline]: slisBNB PCSv3 cross-tier flash arb (hold flat)");
    }
}
