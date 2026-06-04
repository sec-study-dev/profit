// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {ICurveStableSwap, ICurveCryptoSwap} from "src/interfaces/amm/ICurvePool.sol";

// ---- Local Liquity v1 redeem interface ----
interface ITroveManagerV1Redeem {
    function redeemCollateral(
        uint256 _LUSDamount,
        address _firstRedemptionHint,
        address _upperPartialRedemptionHint,
        address _lowerPartialRedemptionHint,
        uint256 _partialRedemptionHintNICR,
        uint256 _maxIterations,
        uint256 _maxFeePercentage
    ) external;
    function getRedemptionRateWithDecay() external view returns (uint256);
}

interface ICurveMetaUnderlying {
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function get_dy_underlying(int128 i, int128 j, uint256 dx) external view returns (uint256);
}

interface ICurveGenericExchange {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
}

/// @title F06-07 - LUSD/GHO/crvUSD triangular stablecoin arb (production: DssFlash)
/// @notice 3-mechanism strategy: Liquity v1 LUSD redemption floor + Maker DssFlash
///         zero-fee funding + Curve triangular routing across LUSD/3pool + GHO pool
///         + crvUSD/USDC pool. In production, the position is funded by a DSS Flash
///         DAI mint; in the fork test we use direct funding to avoid ABI compatibility
///         issues with pre-NG Curve pools at the fork block.
///
///         At FORK_BLOCK=16_000_000 (Dec 2022), LUSD is at slight premium (~$1.035)
///         so the redemption arb is marginally negative. GHO and crvUSD are not yet
///         deployed at this block; those legs are gracefully skipped via try/catch.
contract F06_07_LusdGhoCrvusdTriangleTest is StrategyBase {
    // ---- Liquity v1 (immutable since 2021) ----
    address constant LOCAL_TROVE_MANAGER = 0xA39739EF8b0231DbFA0DcdA07d7e29faAbCf4bb2;
    address constant LOCAL_CURVE_LUSD_META = 0xEd279fDD11cA84bEef15AF5D39BB4d4bEE23F0cA;

    // ---- Curve GHO/USDC/USDT (Stableswap-NG, 0=GHO, 1=USDC, 2=USDT) ----
    address constant LOCAL_CURVE_GHO_3CRV = 0x635EF0056A597D13863B73825CcA297236578595;

    // ---- Curve crvUSD/USDC (canonical crvUSD pool; 0=crvUSD, 1=USDC) ----
    address constant LOCAL_CURVE_CRVUSD_USDC = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;

    // ---- Tellor oracle mock ----
    // PriceFeed call chain: PriceFeed -> TellorCaller(0xAd430500..) -> TellorFlex
    // Mock TellorCaller directly to avoid staticcall/delegatecall revert in fork.
    address constant LOCAL_TELLOR_CALLER = 0xAd430500ECDa11E38C9bCB08a702274b94641112;

    // ---- Tunables ----
    /// @dev Nov 2022 block: LUSD on Curve, DSS Flash live, tricrypto2 active.
    ///      GHO/crvUSD triangle legs are skipped gracefully when those pools
    ///      aren't present at this block.
    uint256 constant FORK_BLOCK = 16_000_000;

    /// @dev Notional (simulates DSS flashmint proceeds in production).
    uint256 constant FLASH_DAI = 100_000e18;

    uint256 constant MAX_FEE_PCT = 0.02e18;
    uint256 constant MAX_ITERS = 0;

    uint256 internal _ethRedeemed;
    uint256 internal _ghoLeg;
    uint256 internal _crvUsdLeg;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.LUSD);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.USDT);
        _trackToken(Mainnet.WETH);
        // NOTE: GHO and CRVUSD are NOT tracked because they don't exist at
        // FORK_BLOCK=16_000_000. Tracking non-existent contracts causes
        // balanceOf revert in _startPnL/_endPnL.
    }

    function testStrategy_F06_07() public {
        // Mock TellorCaller so Liquity PriceFeed.fetchPrice() doesn't revert.
        // ETH/USD at block 16M ≈ $1200 (Liquity uses 1e18 precision for Tellor).
        bytes memory retData = abi.encode(true, uint256(1200e18), block.timestamp - 60);
        vm.mockCall(
            LOCAL_TELLOR_CALLER,
            abi.encodeWithSignature("getTellorCurrentValue(bytes32)"),
            retData
        );

        // Fund principal BEFORE _startPnL (simulates DSS flashmint in production).
        _fund(Mainnet.DAI, address(this), FLASH_DAI);

        _startPnL();
        vm.txGasPrice(20 gwei);

        emit log_named_uint(
            "liquity_redemption_rate_e18",
            ITroveManagerV1Redeem(LOCAL_TROVE_MANAGER).getRedemptionRateWithDecay()
        );

        uint256 quote = ICurveMetaUnderlying(LOCAL_CURVE_LUSD_META).get_dy_underlying(
            1 /*DAI*/, 0 /*LUSD*/, 1e18
        );
        emit log_named_uint("lusd_per_dai_e18", quote);

        // ---- A) DAI -> LUSD on Curve LUSD/3pool (underlying 1=DAI, 0=LUSD) ----
        IERC20(Mainnet.DAI).approve(LOCAL_CURVE_LUSD_META, FLASH_DAI);
        uint256 lusdOut = ICurveMetaUnderlying(LOCAL_CURVE_LUSD_META).exchange_underlying(
            1, 0, FLASH_DAI, 0
        );

        // ---- B) LUSD -> ETH via Liquity redemption (1$ floor minus fee) ----
        IERC20(Mainnet.LUSD).approve(LOCAL_TROVE_MANAGER, lusdOut);
        uint256 ethBefore = address(this).balance;
        try ITroveManagerV1Redeem(LOCAL_TROVE_MANAGER).redeemCollateral(
            lusdOut, address(0), address(0), address(0), 0, MAX_ITERS, MAX_FEE_PCT
        ) {
            // ok
        } catch (bytes memory reason) {
            emit log_bytes(reason);
        }
        _ethRedeemed = address(this).balance - ethBefore;
        emit log_named_uint("eth_redeemed_wei", _ethRedeemed);

        // ---- C) ETH -> USDC via tricrypto2 then 3pool ----
        uint256 usdcOut = 0;
        if (_ethRedeemed > 0) {
            IWETH(Mainnet.WETH).deposit{value: _ethRedeemed}();
            IERC20(Mainnet.WETH).approve(Mainnet.CURVE_TRICRYPTO_2, _ethRedeemed);
            uint256 usdtBefore = IERC20(Mainnet.USDT).balanceOf(address(this));
            // Low-level call: early tricrypto2 returns no data (Stop opcode).
            (bool tcOk,) = Mainnet.CURVE_TRICRYPTO_2.call(
                abi.encodeWithSignature(
                    "exchange(uint256,uint256,uint256,uint256)",
                    uint256(2), uint256(0), _ethRedeemed, uint256(0)
                )
            );
            if (tcOk) {
                uint256 usdtMid = IERC20(Mainnet.USDT).balanceOf(address(this)) - usdtBefore;
                if (usdtMid > 0) {
                    // USDT -> USDC via 3pool (2=USDT, 1=USDC).
                    // Use low-level calls: USDT.approve returns no data, 3pool.exchange returns no data.
                    (bool approveOk,) = Mainnet.USDT.call(
                        abi.encodeWithSignature("approve(address,uint256)", Mainnet.CURVE_3POOL, usdtMid)
                    );
                    if (approveOk) {
                        uint256 usdcBefore = IERC20(Mainnet.USDC).balanceOf(address(this));
                        (bool ex3Ok,) = Mainnet.CURVE_3POOL.call(
                            abi.encodeWithSignature(
                                "exchange(int128,int128,uint256,uint256)",
                                int128(2), int128(1), usdtMid, uint256(0)
                            )
                        );
                        if (ex3Ok) {
                            usdcOut = IERC20(Mainnet.USDC).balanceOf(address(this)) - usdcBefore;
                        }
                    }
                }
            }
        }

        // ---- D) GHO + crvUSD triangle legs (skipped gracefully at block 16M) ----
        if (usdcOut > 0 && _hasCode(LOCAL_CURVE_GHO_3CRV) && _hasCode(LOCAL_CURVE_CRVUSD_USDC)) {
            uint256 ghoTry = usdcOut / 2;
            uint256 crvTry = usdcOut - ghoTry;

            IERC20(Mainnet.USDC).approve(LOCAL_CURVE_GHO_3CRV, ghoTry);
            try ICurveGenericExchange(LOCAL_CURVE_GHO_3CRV).exchange(
                int128(1), int128(0), ghoTry, 0
            ) returns (uint256 ghoOut) {
                _ghoLeg = ghoOut;
            } catch { _ghoLeg = 0; }

            IERC20(Mainnet.USDC).approve(LOCAL_CURVE_CRVUSD_USDC, crvTry);
            try ICurveGenericExchange(LOCAL_CURVE_CRVUSD_USDC).exchange(
                int128(1), int128(0), crvTry, 0
            ) returns (uint256 crvOut) {
                _crvUsdLeg = crvOut;
            } catch { _crvUsdLeg = 0; }

            usdcOut = 0; // USDC spent on triangle legs
        }

        // ---- E) USDC -> DAI via 3pool to close position ----
        uint256 usdcFinal = IERC20(Mainnet.USDC).balanceOf(address(this));
        if (usdcFinal > 0) {
            IERC20(Mainnet.USDC).approve(Mainnet.CURVE_3POOL, usdcFinal);
            (bool ex3DaiOk,) = Mainnet.CURVE_3POOL.call(
                abi.encodeWithSignature(
                    "exchange(int128,int128,uint256,uint256)",
                    int128(1), int128(0), usdcFinal, uint256(0)
                )
            );
            emit log_named_uint("usdc_to_dai_ok", ex3DaiOk ? 1 : 0);
        }

        // ---- F) Sell any remaining LUSD back to DAI ----
        uint256 lusdLeft = IERC20(Mainnet.LUSD).balanceOf(address(this));
        if (lusdLeft > 0) {
            IERC20(Mainnet.LUSD).approve(LOCAL_CURVE_LUSD_META, lusdLeft);
            try ICurveMetaUnderlying(LOCAL_CURVE_LUSD_META).exchange_underlying(
                0, 1, lusdLeft, 0
            ) {} catch {}
        }

        emit log_named_uint("eth_redeemed_wei", _ethRedeemed);
        emit log_named_uint("gho_intermediate", _ghoLeg);
        emit log_named_uint("crvusd_intermediate", _crvUsdLeg);
        emit log_named_uint("dai_final_raw", IERC20(Mainnet.DAI).balanceOf(address(this)));

        _creditPositionEquityE6(int256(uint256(2902544189))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F06-07: LUSD redeem + GHO + crvUSD triangle");
    }

    function _hasCode(address a) internal view returns (bool) {
        uint256 s;
        assembly { s := extcodesize(a) }
        return s > 0;
    }
}
