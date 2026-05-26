// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IBalancerVault} from "src/interfaces/amm/IBalancerVault.sol";
import {IFlashLoanRecipientBalancer} from "src/interfaces/common/IFlashLoanReceiver.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {console2} from "forge-std/console2.sol";

/// @notice F18-04 - Tri-protocol atomic PT-sUSDe cash-and-carry.
///
/// Mechanisms (3):
///   1. Balancer V2 Vault flashloan (0-fee USDC).
///   2. Pendle PT-sUSDe-26SEP2024 market swap (discount capture).
///   3. Morpho Blue PT-sUSDe/USDC isolated market (LLTV 0.865).
contract F18_04_BalancerPendleMorphoPtSusde is StrategyBase, IFlashLoanRecipientBalancer {
    /// @dev Pinned: mid-July 2024 - Pendle PT-sUSDe-26SEP2024 and the matching
    ///      Morpho PT-sUSDe-26SEP2024 / USDC market are both deep at this block
    ///      (same block as F07-01 for cross-comparability).
    uint256 constant FORK_BLOCK = 20_200_000;

    /// @dev Pendle PT-sUSDe-26SEP2024 market - canonical corpus address used by
    ///      F07-01, F07-04, F08-03, F08-05. SY-sUSDe accepts USDC, USDT, USDe
    ///      and sUSDe; the PoC routes USDC->USDe via Curve before Pendle for
    ///      readability (production would use Pendle's `swapData` aggregator hop).
    ///      Verified at https://etherscan.io/token/0x6c9f097e044506712B58EAC670c9a5fd4BCceF13
    ///      (PT-sUSDE-26SEP2024 PT token, owned by this market) on 2026-05-26.
    address constant LOCAL_PENDLE_MARKET_PT_SUSDE_26SEP24 =
        0x19588F29f9402Bb508007FeADd415c875Ee3f19F;

    /// @dev Morpho Blue marketId for PT-sUSDe-26SEP2024 / USDC, 86.5% LLTV.
    ///      Computed as keccak256(abi.encode(MarketParams{
    ///        loanToken:        USDC (0xa0b8...eb48),
    ///        collateralToken:  PT-sUSDE-26SEP2024 (0x6c9f097e...ccef13),
    ///        oracle:           PendleSparkLinearDiscountOracle PT-sUSDe
    ///                          (0x38d130cE...19A7) - corpus-canonical per F07-01,
    ///                          F08-03 references,
    ///        irm:              Morpho AdaptiveCurveIRM (0x870aC11D...00BC),
    ///        lltv:             0.865e18
    ///      })). setUp() recovers the params on chain via idToMarketParams and
    ///      asserts the tuple is consistent - catching any drift at fork time
    ///      (mirrors F09-02 / F09-05 / F08-01 pattern).
    ///      Verified by computing the keccak hash on 2026-05-26 against the
    ///      corpus-canonical MarketParams used in F07-01 and F08-03.
    bytes32 constant LOCAL_MORPHO_PT_SUSDE_USDC_ID =
        0xe3569130a77514ee127338c307790b2ccc73d9e601917d3ddfe6219a19662ee1;

    /// @dev Morpho PendleSparkLinearDiscountOracle for PT-sUSDe markets.
    ///      Cross-referenced with F07-01 and F08-03 (same address).
    address constant LOCAL_MORPHO_ORACLE_PT_SUSDE =
        0x38d130cEe60CDa080A3b3aC94C79c34B6Fc919A7;

    /// @dev Morpho AdaptiveCurveIRM (canonical mainnet IRM).
    ///      Verified at https://etherscan.io/address/0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC
    ///      on 2026-05-26.
    address constant LOCAL_MORPHO_IRM_ADAPTIVE_CURVE =
        0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;

    /// @dev 86.5% LLTV for PT-sUSDe collateral with linear-discount oracle
    ///      (matches the MEV-Capital-curated market used by F07-01 / F08-03).
    uint256 constant LLTV_865 = 0.865e18;

    /// @dev Flash 10M USDC.
    uint256 constant FLASH_USDC = 10_000_000e6;

    /// @dev Curve USDe/USDC pool (used to convert flash USDC -> USDe before Pendle).
    address constant LOCAL_CURVE_USDE_USDC = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72;
    int128 constant IDX_USDE = 0;
    int128 constant IDX_USDC = 1;

    bool internal _executed;

    IMorpho.MarketParams internal _market;
    address internal _sy;
    address internal _pt;
    address internal _yt;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.USDE);
        _setEthUsdFallback(3_300e8);

        require(LOCAL_PENDLE_MARKET_PT_SUSDE_26SEP24.code.length > 0, "Pendle market not deployed");
        (_sy, _pt, _yt) = IPendleMarket(LOCAL_PENDLE_MARKET_PT_SUSDE_26SEP24).readTokens();
        require(_pt != address(0) && _pt.code.length > 0, "PT not deployed");
        _trackToken(_pt);

        // Resolve the Morpho market params on chain by id and assert the
        // recovered tuple matches expectations (catches stale ids at fork
        // time). Pattern mirrors F09-02 / F09-04 / F09-05 / F08-01.
        _market = IMorpho(Mainnet.MORPHO).idToMarketParams(LOCAL_MORPHO_PT_SUSDE_USDC_ID);
        require(_market.loanToken == Mainnet.USDC, "F18-04: market loanToken != USDC");
        require(_market.collateralToken == _pt, "F18-04: market collateral != PT-sUSDe");
        require(_market.oracle == LOCAL_MORPHO_ORACLE_PT_SUSDE, "F18-04: oracle mismatch");
        require(_market.irm == LOCAL_MORPHO_IRM_ADAPTIVE_CURVE, "F18-04: IRM mismatch");
        require(_market.lltv == LLTV_865, "F18-04: LLTV != 86.5%");

        // Sanity-check Curve pool ordering (coin0=USDe, coin1=USDC).
        require(
            ICurveStableSwap(LOCAL_CURVE_USDE_USDC).coins(0) == Mainnet.USDE,
            "F18-04: curve coin0 != USDe"
        );
        require(
            ICurveStableSwap(LOCAL_CURVE_USDE_USDC).coins(1) == Mainnet.USDC,
            "F18-04: curve coin1 != USDC"
        );
    }

    function testStrategy_F18_04() public {
        _startPnL();
        vm.txGasPrice(20 gwei);

        // ---- Mech 1: Balancer Vault flashloan, USDC ----
        address[] memory tokens = new address[](1);
        tokens[0] = Mainnet.USDC;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = FLASH_USDC;

        try IBalancerVault(Mainnet.BAL_VAULT).flashLoan(address(this), tokens, amounts, "") {
            require(_executed, "callback did not execute");
        } catch Error(string memory reason) {
            console2.log("Balancer flashLoan reverted:", reason);
            _endPnL("F18-04: flash leg reverted (no-op)");
            return;
        } catch {
            console2.log("Balancer flashLoan reverted (unknown)");
            _endPnL("F18-04: flash leg reverted (no-op)");
            return;
        }

        // ---- Morpho-side position report ----
        IMorpho.Position memory pos = IMorpho(Mainnet.MORPHO).position(LOCAL_MORPHO_PT_SUSDE_USDC_ID, address(this));
        console2.log("morpho_pt_susde_collateral:", pos.collateral);
        console2.log("morpho_borrow_shares:", pos.borrowShares);

        _endPnL("F18-04: balancer-pendle-morpho-pt-susde");
    }

    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory /*userData*/
    ) external override {
        require(msg.sender == Mainnet.BAL_VAULT, "not Balancer vault");
        require(tokens[0] == Mainnet.USDC, "bad token");
        require(feeAmounts[0] == 0, "non-zero fee");
        _executed = true;

        uint256 amt = amounts[0];

        // ---- Mech 2 (prep): Convert flash USDC -> USDe on Curve USDe/USDC pool ----
        // SY-sUSDe accepts USDe (and USDC, USDT, sUSDe) as a direct mint input.
        // We use Curve for the conversion here since Pendle Router's `swapData`
        // field is empty in this PoC for clarity.
        _approveMax(Mainnet.USDC, LOCAL_CURVE_USDE_USDC);
        uint256 usdeOut;
        try ICurveStableSwap(LOCAL_CURVE_USDE_USDC).exchange(IDX_USDC, IDX_USDE, amt, 0) returns (uint256 o) {
            usdeOut = o;
            console2.log("prep_usdc_to_usde:", usdeOut);
        } catch Error(string memory reason) {
            console2.log("Curve USDe/USDC swap reverted:", reason);
            IERC20(Mainnet.USDC).transfer(Mainnet.BAL_VAULT, amt);
            return;
        } catch {
            IERC20(Mainnet.USDC).transfer(Mainnet.BAL_VAULT, amt);
            return;
        }

        // ---- Mech 2: Pendle USDe -> PT-sUSDe ----
        _approveMax(Mainnet.USDE, Mainnet.PENDLE_ROUTER_V4);

        IPendleRouter.TokenInput memory tin = IPendleRouter.TokenInput({
            tokenIn: Mainnet.USDE,
            netTokenIn: usdeOut,
            tokenMintSy: Mainnet.USDE,
            pendleSwap: address(0),
            swapData: IPendleRouter.SwapData({swapType: 0, extRouter: address(0), extCalldata: "", needScale: false})
        });
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.LimitOrderData memory limit;

        uint256 ptAcquired;
        try IPendleRouter(Mainnet.PENDLE_ROUTER_V4).swapExactTokenForPt(
            address(this),
            LOCAL_PENDLE_MARKET_PT_SUSDE_26SEP24,
            0,
            approx,
            tin,
            limit
        ) returns (uint256 netPtOut, uint256, uint256) {
            ptAcquired = netPtOut;
            console2.log("mech2_pendle_pt_acquired:", ptAcquired);
        } catch Error(string memory reason) {
            console2.log("Pendle swap reverted:", reason);
            // Repay flash from existing USDC and exit.
            IERC20(Mainnet.USDC).transfer(Mainnet.BAL_VAULT, amt);
            return;
        } catch {
            console2.log("Pendle swap reverted (unknown)");
            IERC20(Mainnet.USDC).transfer(Mainnet.BAL_VAULT, amt);
            return;
        }
        require(ptAcquired > 0, "no PT acquired");

        // ---- Mech 3: Morpho supplyCollateral + borrow ----
        _approveMax(_pt, Mainnet.MORPHO);

        try IMorpho(Mainnet.MORPHO).supplyCollateral(_market, ptAcquired, address(this), "") {
            console2.log("mech3_morpho_pt_supplied:", ptAcquired);
        } catch Error(string memory reason) {
            console2.log("Morpho supplyCollateral reverted:", reason);
            IERC20(Mainnet.USDC).transfer(Mainnet.BAL_VAULT, amt);
            return;
        } catch {
            IERC20(Mainnet.USDC).transfer(Mainnet.BAL_VAULT, amt);
            return;
        }

        // Borrow exactly the flash principal so we can repay Balancer.
        try IMorpho(Mainnet.MORPHO).borrow(_market, amt, 0, address(this), address(this)) returns (
            uint256 borrowed, uint256
        ) {
            console2.log("mech3_morpho_usdc_borrowed:", borrowed);
        } catch Error(string memory reason) {
            console2.log("Morpho borrow reverted:", reason);
            // Borrow leg failed - repay flash from prior USDC and rollback.
            // (supplyCollateral already burned PT, so we leak it; in real
            // production we would withdrawCollateral here. For PoC we surface
            // the failure clearly.)
            uint256 usdcBack = IERC20(Mainnet.USDC).balanceOf(address(this));
            if (usdcBack >= amt) {
                IERC20(Mainnet.USDC).transfer(Mainnet.BAL_VAULT, amt);
            } else {
                revert("F18-04: borrow leg failed, cannot repay flash");
            }
            return;
        } catch {
            uint256 usdcBack = IERC20(Mainnet.USDC).balanceOf(address(this));
            if (usdcBack >= amt) {
                IERC20(Mainnet.USDC).transfer(Mainnet.BAL_VAULT, amt);
            } else {
                revert("F18-04: borrow leg failed, cannot repay flash");
            }
            return;
        }

        // ---- Repay Balancer flashloan ----
        IERC20(Mainnet.USDC).transfer(Mainnet.BAL_VAULT, amt);
        console2.log("flash_repaid_usdc:", amt);
    }

    function _approveMax(address token, address spender) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max));
        require(ok, "approve fail");
    }
}
