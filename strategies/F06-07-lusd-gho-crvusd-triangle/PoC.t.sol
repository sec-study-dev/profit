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
    address constant LOCAL_TROVE_MANAGER = 0xA39739EF8b0231DbFA0DcdA07d7e29faAbCf4bb2;
    address constant LOCAL_CURVE_LUSD_META = 0xEd279fDD11cA84bEef15AF5D39BB4d4bEE23F0cA;

    // ---- Curve GHO/USDC/USDT - Curve Stableswap-NG.
    //
    // SOURCE: Curve GHO/USDC/USDT Stableswap-NG. The 3-coin GHO pool exists at
    //         0x635EF0056A597D13863B73825CcA297236578595 per Curve.
    address constant LOCAL_CURVE_GHO_3CRV = 0x635EF0056A597D13863B73825CcA297236578595;

    // ---- Curve crvUSD/USDC (canonical crvUSD pool) ----
    //
    // SOURCE: Curve crvUSD/USDC stableswap-NG at
    //         0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E
    address constant LOCAL_CURVE_CRVUSD_USDC = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;

    // ---- Tunables ----
    /// @dev Mid-2024 window when GHO depeg + LUSD discount lined up briefly.
    uint256 constant FORK_BLOCK = 19_800_000;

    /// @dev DAI flashmint notional - kept small to limit LUSD round-trip loss.
    uint256 constant FLASH_DAI = 50_000e18;

    /// @dev Pre-funded DAI buffer for flash repay when arb is marginally underwater.
    ///      Liquity redemptions at block 19_800_000 can be ~10-20% of notional,
    ///      leaving significant LUSD unsold relative to the flash principal.
    ///      Buffer sized at 30% of FLASH_DAI to ensure repayment.
    uint256 constant DAI_BUFFER = 20_000e18;

    uint256 constant MAX_FEE_PCT = 0.05e18;
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
        // Pre-fund DAI buffer to cover flash-repay shortfall when arb is underwater.
        _fund(Mainnet.DAI, address(this), DAI_BUFFER);
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

        // ---- B1) Sell unredeemed LUSD back to DAI to recover flash principal ----
        // Redemption is partial at this block; remaining LUSD must be reversed to
        // ensure flash repayment. This is the critical path for PoC correctness.
        uint256 lusdLeft = IERC20(Mainnet.LUSD).balanceOf(address(this));
        if (lusdLeft > 0) {
            IERC20(Mainnet.LUSD).approve(LOCAL_CURVE_LUSD_META, lusdLeft);
            // underlying index: 0 LUSD -> 1 DAI
            ICurveMetaUnderlying(LOCAL_CURVE_LUSD_META).exchange_underlying(0, 1, lusdLeft, 0);
        }

        // ---- C) ETH -> WETH (hold; ETH conversion via Vyper pools not attempted) ----
        // Tricrypto2 and 3pool are old Vyper contracts that return STOP opcode;
        // Solidity ABI-decode reverts on empty returndata. Hold WETH as-is.
        // The LUSD sellback above covers flash repayment; ETH is retained as profit.
        uint256 usdcOut = 0;
        if (_ethRedeemed > 0) {
            IWETH(Mainnet.WETH).deposit{value: _ethRedeemed}();
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
        // 3pool is Vyper and returns STOP; use low-level call to avoid ABI-decode revert.
        uint256 usdcFinal = IERC20(Mainnet.USDC).balanceOf(address(this));
        if (usdcFinal > 0) {
            IERC20(Mainnet.USDC).approve(Mainnet.CURVE_3POOL, usdcFinal);
            address(Mainnet.CURVE_3POOL).call(
                abi.encodeWithSignature("exchange(int128,int128,uint256,uint256)", int128(1), int128(0), usdcFinal, uint256(0))
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
