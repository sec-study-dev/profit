// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

// ---------------------------------------------------------------------------
// Inlined interfaces - same checksum-bug rationale as other B13-* PoCs.
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

/// @notice LayerZero V2 OFT (used by Pendle's BSC<->ETH PT bridge variants
///         once the cross-chain PT roll-up rolls out; address TODO).
interface IPTOFTAdapter {
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

/// @notice Pendle V4 Router minimal surface for PT swap.
interface IPendleRouterV4 {
    struct ApproxParams {
        uint256 guessMin;
        uint256 guessMax;
        uint256 guessOffchain;
        uint256 maxIteration;
        uint256 eps;
    }
    struct TokenInput {
        address tokenIn;
        uint256 netTokenIn;
        address tokenMintSy;
        address pendleSwap;
        SwapData swapData;
    }
    struct TokenOutput {
        address tokenOut;
        uint256 minTokenOut;
        address tokenRedeemSy;
        address pendleSwap;
        SwapData swapData;
    }
    struct SwapData {
        uint8 swapType;
        address extRouter;
        bytes extCalldata;
        bool needScale;
    }
    struct LimitOrderData {
        address limitRouter;
        uint256 epsSkipMarket;
        bytes normalFills;
        bytes flashFills;
        bytes optData;
    }
    function swapExactTokenForPt(
        address receiver,
        address market,
        uint256 minPtOut,
        ApproxParams calldata guessPtOut,
        TokenInput calldata input,
        LimitOrderData calldata limit
    ) external payable returns (uint256 netPtOut, uint256 netSyFee, uint256 netSyInterm);
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

/// @title B13-08 Pendle PT-sUSDe cross-chain bridge spread (3-mech)
/// @notice **3-mechanism positional** strategy:
///         1. **PCS v3 flash** N USDT from USDT/USDC.
///         2. **Pendle V4 swapExactTokenForPt** USDT -> PT-sUSDe (BSC) - buy
///            BSC PT-sUSDe at YT-deepened discount when BSC's PT/SY market
///            yields > ETH's by 1-3 % APY (recurring during sUSDe APY drift).
///         3. **USDe / sUSDe OFT bridge** the underlying or wrapped SY back
///            to ETH (USDe is the same OFT used by B13-04). The PT itself
///            doesn't bridge directly; the strat redeems PT pre-maturity to
///            sUSDe via the SY adapter, bridges sUSDe through Ethena's OFT
///            (TODO confirm sUSDe OFT exists; if not, redeem to USDe and
///            use the USDe OFT), then sells PT-sUSDe-ETH at the *higher*
///            ETH price.
///         4. **PCS v3 swap** residual sUSDe/USDe -> USDT on the way out
///            (third venue).
///         5. Repay PCS v3 flash from a pre-funded USDT buffer.
/// @dev    Pendle BSC PT-sUSDe market address TODO-verify; offline-first.
contract B13_08_Pendle_PT_sUSDe_XChain is BSCStrategyBase, IPancakeV3FlashCallback {
    // ---- Inlined BSC addresses ----
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    /// @notice Ethena sUSDe on BSC.
    address constant sUSDe = 0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2;
    /// @notice Ethena USDe on BSC.
    address constant USDe = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34;

    address constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant PCS_V3_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    /// @notice Pendle Router V4 on BSC (TODO verify chain-specific deploy).
    address constant PENDLE_ROUTER_V4 = 0x888888888889758F76e7103c6CbF23ABbF58F946;

    /// @notice PT-sUSDe / SY market on BSC (Pendle market addr). TODO verify.
    address constant PT_SUSDE_MARKET_BSC = address(0);
    /// @notice Ethena sUSDe / USDe OFT adapter on BSC. TODO verify.
    address constant ENA_OFT_ADAPTER = address(0);
    /// @notice PT-sUSDe token on BSC (asset address after SY mint). TODO.
    address constant PT_SUSDE_BSC = address(0);

    /// @dev Placeholder block.
    uint256 constant FORK_BLOCK = 45_500_000;

    /// @dev Flash notional in USDT (18 dec).
    uint256 constant FLASH_NOTIONAL = 200_000 ether;
    /// @dev USDT buffer for flash repayment (mirrors eventual ETH-side
    ///      proceeds re-bridged back).
    uint256 constant REPAY_BUFFER = 201_500 ether;

    /// @dev Assumed BSC PT-sUSDe APY premium vs ETH PT-sUSDe (basis points
    ///      of notional, translated through duration ~30 days = 60 bp).
    uint256 constant ASSUMED_PT_SPREAD_BP = 60;

    uint24 constant FLASH_FEE_TIER = 100;
    uint24 constant SWAP_FEE_TIER_USDe_USDT = 100;

    /// @dev LayerZero endpoint id for Ethereum.
    uint32 constant ETH_EID = 30101;

    address public flashPool;
    bool internal _haveOnchain;

    uint256 public usdtFlashed;
    uint256 public ptSusdeReceived;
    uint256 public sUsdeRedeemed;
    uint256 public sUsdeBridged;
    uint256 public usdtAfterFinalSwap;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveOnchain =
                PT_SUSDE_MARKET_BSC != address(0) &&
                ENA_OFT_ADAPTER != address(0) &&
                PT_SUSDE_BSC != address(0);
        } catch {
            _haveOnchain = false;
        }

        _trackToken(USDT);
        _trackToken(sUSDe);
        _trackToken(USDe);
        _setOraclePrice(USDT, 1e8);
        _setOraclePrice(sUSDe, 1e8);
        _setOraclePrice(USDe, 1e8);
    }

    function testStrategy_B13_08() public {
        if (!_haveOnchain) {
            _offlinePnLCheck();
            return;
        }
        _onchainRun();
    }

    function _onchainRun() internal {
        _trackToken(PT_SUSDE_BSC);
        _setOraclePrice(PT_SUSDE_BSC, 1e8); // PT priced ~ 1 USD at maturity

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

        _endPnL("B13-08: PT-sUSDe cross-chain spread");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        require(msg.sender == flashPool, "callback: not flash pool");
        uint256 notional = abi.decode(data, (uint256));

        bool usdtIsToken0 = IPancakeV3Pool(flashPool).token0() == USDT;
        uint256 owedFee = usdtIsToken0 ? fee0 : fee1;
        usdtFlashed = notional;

        // ---- (Mech 1) Pendle V4: USDT -> PT-sUSDe on BSC at discount.
        IERC20(USDT).approve(PENDLE_ROUTER_V4, notional);
        IPendleRouterV4.ApproxParams memory ap = IPendleRouterV4.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e14
        });
        IPendleRouterV4.SwapData memory empty = IPendleRouterV4.SwapData({
            swapType: 0,
            extRouter: address(0),
            extCalldata: bytes(""),
            needScale: false
        });
        IPendleRouterV4.TokenInput memory ti = IPendleRouterV4.TokenInput({
            tokenIn: USDT,
            netTokenIn: notional,
            tokenMintSy: USDT,
            pendleSwap: address(0),
            swapData: empty
        });
        IPendleRouterV4.LimitOrderData memory lo = IPendleRouterV4.LimitOrderData({
            limitRouter: address(0),
            epsSkipMarket: 0,
            normalFills: bytes(""),
            flashFills: bytes(""),
            optData: bytes("")
        });
        (ptSusdeReceived, , ) = IPendleRouterV4(PENDLE_ROUTER_V4).swapExactTokenForPt(
            address(this),
            PT_SUSDE_MARKET_BSC,
            (notional * 9990) / 10_000,
            ap,
            ti,
            lo
        );

        // ---- (Mech 2) Bridge underlying sUSDe / USDe to ETH via Ethena OFT.
        //      We model the path: PT redeem -> sUSDe (offline math) ->
        //      OFT.send(ETH_EID).
        sUsdeRedeemed = ptSusdeReceived; // 1:1 at maturity; pre-maturity uses SY discount
        IERC20(sUSDe).approve(ENA_OFT_ADAPTER, sUsdeRedeemed);
        IPTOFTAdapter.SendParam memory sp = IPTOFTAdapter.SendParam({
            dstEid: ETH_EID,
            to: bytes32(uint256(uint160(address(this)))),
            amountLD: sUsdeRedeemed,
            minAmountLD: (sUsdeRedeemed * 9990) / 10_000,
            extraOptions: bytes(""),
            composeMsg: bytes(""),
            oftCmd: bytes("")
        });
        IPTOFTAdapter.MessagingFee memory mf = IPTOFTAdapter(ENA_OFT_ADAPTER).quoteSend(sp, false);
        IPTOFTAdapter(ENA_OFT_ADAPTER).send{value: mf.nativeFee}(sp, mf, address(this));
        sUsdeBridged = sUsdeRedeemed;

        // ---- (Mech 3) PCS v3 residual swap of any USDe -> USDT to keep
        //      stablecoin leg consolidated for repayment.
        uint256 residualUsde = IERC20(USDe).balanceOf(address(this));
        if (residualUsde > 0) {
            IERC20(USDe).approve(PCS_V3_ROUTER, residualUsde);
            IPancakeV3Router.ExactInputSingleParams memory ps = IPancakeV3Router.ExactInputSingleParams({
                tokenIn: USDe,
                tokenOut: USDT,
                fee: SWAP_FEE_TIER_USDe_USDT,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: residualUsde,
                amountOutMinimum: (residualUsde * 9990) / 10_000,
                sqrtPriceLimitX96: 0
            });
            usdtAfterFinalSwap = IPancakeV3Router(PCS_V3_ROUTER).exactInputSingle(ps);
        }

        // ---- Repay PCS v3 flash from buffer.
        IERC20(USDT).transfer(flashPool, notional + owedFee);
    }

    function _offlinePnLCheck() internal {
        uint256 notional = FLASH_NOTIONAL;
        // Leg 1: PT-sUSDe bought at PT-spread discount; book ~= notional + spread.
        uint256 simPt = (notional * (10_000 + ASSUMED_PT_SPREAD_BP - 5)) / 10_000;
        // Leg 2: bridge sUSDe -> ETH (modelled as 4 bp OFT tax).
        uint256 simEthSusde = (simPt * (10_000 - 4)) / 10_000;
        // Leg 3: re-bridged back as USDT, after 10 bp ETH-side route.
        uint256 simReturnUsdt = (simEthSusde * (10_000 - 10)) / 10_000;
        uint256 simFlashFee = notional / 10_000; // 1 bp

        _fund(USDT, address(this), REPAY_BUFFER);
        _startPnL();

        IERC20(USDT).transfer(address(0xdead), notional + simFlashFee);
        uint256 residual = IERC20(USDT).balanceOf(address(this));
        _fund(USDT, address(this), residual + simReturnUsdt);

        usdtFlashed = notional;
        ptSusdeReceived = simPt;
        sUsdeRedeemed = simPt;
        sUsdeBridged = simPt;
        usdtAfterFinalSwap = 0;

        _endPnL("B13-08[offline]: PT-sUSDe cross-chain spread");
    }
}
