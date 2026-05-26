// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {ICurveStableSwap, ICurveCryptoSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IDssFlash} from "src/interfaces/cdp/IDssFlash.sol";
import {IERC3156FlashBorrower} from "src/interfaces/common/IFlashLoanReceiver.sol";

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

/// @title F06-07 - LUSD/GHO/crvUSD triangular stablecoin arb funded by DssFlash
/// @notice 3-mechanism strategy:
///         1. Liquity v1 - LUSD redemption hard floor at $1 (ETH out).
///         2. Maker DssFlash - zero-fee DAI flashmint funds the buy leg.
///         3. Curve - triangular routing across LUSD/3pool +
///            GHO/USDC/USDT (3-coin stableswap-NG) + crvUSD/USDC.
///
///         When LUSD and one of {GHO, crvUSD} are simultaneously off-peg,
///         a multi-hop loop captures both the LUSD redemption floor AND
///         the inter-stable basis. Path:
///
///         DAI -> LUSD (Curve meta) -> ETH (Liquity redeem, takes the 1$ floor)
///           -> USDC (tricrypto2+3pool) -> GHO (GHO pool) -> crvUSD (crvUSD/USDC)
///           -> USDC (crvUSD/USDC) -> DAI (3pool) -> repay flash
///
///         Most of the time the GHO and crvUSD legs net to ~0 (no basis);
///         when one leg has a 20+ bps premium relative to USDC, the
///         triangle adds materially to the LUSD-redemption alpha.
contract F06_07_LusdGhoCrvusdTriangleTest is StrategyBase, IERC3156FlashBorrower {
    // ---- Liquity v1 (immutable since 2021) ----
    address constant LOCAL_TROVE_MANAGER = 0xa39739ef8b0231dbfa0dcda07d7e29faabcf4bb2;
    address constant LOCAL_CURVE_LUSD_META = 0xed279fdd11ca84beef15af5d39bb4d4bee23f0ca;

    // ---- Curve GHO/USDC/USDT - Curve Stableswap-NG.
    //
    // SOURCE: Curve GHO/USDC/USDT Stableswap-NG. The 3-coin GHO pool exists at
    //         0x635ef0056a597d13863b73825cca297236578595 per Curve.
    address constant LOCAL_CURVE_GHO_3CRV = 0x635ef0056a597d13863b73825cca297236578595;

    // ---- Curve crvUSD/USDC (canonical crvUSD pool) ----
    //
    // SOURCE: Curve crvUSD/USDC stableswap-NG at
    //         0x4dece678ceceb27446b35c672dc7d61f30bad69e
    address constant LOCAL_CURVE_CRVUSD_USDC = 0x4dece678ceceb27446b35c672dc7d61f30bad69e;

    // ---- Tunables ----
    /// @dev Mid-2024 window when GHO depeg + LUSD discount lined up briefly.
    uint256 constant FORK_BLOCK = 19_800_000;

    /// @dev DAI flashmint notional.
    uint256 constant FLASH_DAI = 3_000_000e18;

    uint256 constant MAX_FEE_PCT = 0.02e18;
    uint256 constant MAX_ITERS = 0;
    bytes32 constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

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
        _trackToken(Mainnet.GHO);
        _trackToken(Mainnet.CRVUSD);
    }

    function testStrategy_F06_07() public {
        _startPnL();

        uint256 fee = IDssFlash(Mainnet.DSS_FLASH).flashFee(Mainnet.DAI, FLASH_DAI);
        require(fee == 0, "DSS toll bumped");

        emit log_named_uint(
            "liquity_redemption_rate_e18",
            ITroveManagerV1Redeem(LOCAL_TROVE_MANAGER).getRedemptionRateWithDecay()
        );

        IDssFlash(Mainnet.DSS_FLASH).flashLoan(
            address(this),
            Mainnet.DAI,
            FLASH_DAI,
            ""
        );

        emit log_named_uint("eth_redeemed_wei", _ethRedeemed);
        emit log_named_uint("gho_intermediate", _ghoLeg);
        emit log_named_uint("crvusd_intermediate", _crvUsdLeg);
        emit log_named_uint("residual_dai", IERC20(Mainnet.DAI).balanceOf(address(this)));

        _endPnL("F06-07: LUSD redeem + GHO + crvUSD triangle");
    }

    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 feeAmount,
        bytes calldata
    ) external returns (bytes32) {
        require(msg.sender == Mainnet.DSS_FLASH, "only DSS Flash");
        require(initiator == address(this), "bad initiator");
        require(token == Mainnet.DAI, "bad token");
        require(feeAmount == 0, "non-zero toll");

        // ---- A) DAI -> LUSD on Curve LUSD/3pool (underlying 1=DAI, 0=LUSD) ----
        IERC20(Mainnet.DAI).approve(LOCAL_CURVE_LUSD_META, amount);
        uint256 lusdOut = ICurveMetaUnderlying(LOCAL_CURVE_LUSD_META).exchange_underlying(
            1, 0, amount, 0
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

        // ---- C) ETH -> USDC via tricrypto2 then 3pool ----
        uint256 usdcOut = 0;
        if (_ethRedeemed > 0) {
            IWETH(Mainnet.WETH).deposit{value: _ethRedeemed}();
            IERC20(Mainnet.WETH).approve(Mainnet.CURVE_TRICRYPTO_2, _ethRedeemed);
            uint256 usdtMid = ICurveCryptoSwap(Mainnet.CURVE_TRICRYPTO_2).exchange(
                2, 0, _ethRedeemed, 0
            );
            // USDT -> USDC via 3pool (2=USDT, 1=USDC)
            IERC20(Mainnet.USDT).approve(Mainnet.CURVE_3POOL, usdtMid);
            usdcOut = ICurveStableSwap(Mainnet.CURVE_3POOL).exchange(
                int128(2), int128(1), usdtMid, 0
            );
        }

        if (usdcOut > 0 && _hasCode(LOCAL_CURVE_GHO_3CRV) && _hasCode(LOCAL_CURVE_CRVUSD_USDC)) {
            // ---- D) USDC -> GHO via Curve GHO Stableswap-NG ----
            // Pool layout (Stableswap-NG): 0=GHO, 1=USDC, 2=USDT.
            uint256 ghoTry = usdcOut / 2;
            IERC20(Mainnet.USDC).approve(LOCAL_CURVE_GHO_3CRV, ghoTry);
            try ICurveGenericExchange(LOCAL_CURVE_GHO_3CRV).exchange(
                int128(1), int128(0), ghoTry, 0
            ) returns (uint256 ghoOut) {
                _ghoLeg = ghoOut;
            } catch {
                _ghoLeg = 0;
            }

            // ---- E) USDC -> crvUSD via Curve crvUSD/USDC ----
            // Pool layout: 0=crvUSD, 1=USDC.
            uint256 crvTry = usdcOut - ghoTry;
            IERC20(Mainnet.USDC).approve(LOCAL_CURVE_CRVUSD_USDC, crvTry);
            try ICurveGenericExchange(LOCAL_CURVE_CRVUSD_USDC).exchange(
                int128(1), int128(0), crvTry, 0
            ) returns (uint256 crvOut) {
                _crvUsdLeg = crvOut;
            } catch {
                _crvUsdLeg = 0;
            }

            // ---- F) Reverse both intermediates back to USDC ----
            // GHO -> USDC
            if (_ghoLeg > 0) {
                IERC20(Mainnet.GHO).approve(LOCAL_CURVE_GHO_3CRV, _ghoLeg);
                try ICurveGenericExchange(LOCAL_CURVE_GHO_3CRV).exchange(
                    int128(0), int128(1), _ghoLeg, 0
                ) {} catch {}
            }
            // crvUSD -> USDC
            if (_crvUsdLeg > 0) {
                IERC20(Mainnet.CRVUSD).approve(LOCAL_CURVE_CRVUSD_USDC, _crvUsdLeg);
                try ICurveGenericExchange(LOCAL_CURVE_CRVUSD_USDC).exchange(
                    int128(0), int128(1), _crvUsdLeg, 0
                ) {} catch {}
            }
        }

        // ---- G) USDC -> DAI via 3pool (1=USDC, 0=DAI) ----
        uint256 usdcFinal = IERC20(Mainnet.USDC).balanceOf(address(this));
        if (usdcFinal > 0) {
            IERC20(Mainnet.USDC).approve(Mainnet.CURVE_3POOL, usdcFinal);
            ICurveStableSwap(Mainnet.CURVE_3POOL).exchange(
                int128(1), int128(0), usdcFinal, 0
            );
        }

        // ---- H) Repay flashmint ----
        IERC20(Mainnet.DAI).approve(Mainnet.DSS_FLASH, amount + feeAmount);
        return CALLBACK_SUCCESS;
    }

    function _hasCode(address a) internal view returns (bool) {
        uint256 s;
        assembly { s := extcodesize(a) }
        return s > 0;
    }
}
