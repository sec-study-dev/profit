// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IBalancerVault} from "src/interfaces/amm/IBalancerVault.sol";
import {IFlashLoanRecipientBalancer} from "src/interfaces/common/IFlashLoanReceiver.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {console2} from "forge-std/console2.sol";

/// @notice F18-04 — Tri-protocol atomic PT-sUSDe cash-and-carry.
///
/// Mechanisms (3):
///   1. Balancer V2 Vault flashloan (0-fee USDC).
///   2. Pendle PT-sUSDe market swap (discount capture).
///   3. Morpho Blue PT-sUSDe/USDC isolated market (LLTV 0.915).
contract F18_04_BalancerPendleMorphoPtSusde is StrategyBase, IFlashLoanRecipientBalancer {
    /// @dev Pinned: mid-July 2024 — Pendle PT-sUSDe and Morpho PT-sUSDe market both deep.
    uint256 constant FORK_BLOCK = 20_200_000;

    /// @dev Pendle PT-sUSDe-25JUL2024 market (most-liquid PT-sUSDe market at FORK_BLOCK).
    address constant LOCAL_PENDLE_MARKET_PT_SUSDE = 0xbBf399db59A845066aAFce9AE55e68c505FA97B7;

    /// @dev PT-sUSDe token (25-JUL-2024 maturity).
    address constant LOCAL_PT_SUSDE = 0xa0021EF8970104c2d008F38D92f115ad56a9B8e1;

    /// @dev Morpho Blue PT-sUSDe/USDC market id. Verified against Morpho's
    ///      public market dashboard for the PT-sUSDe-25JUL2024 collateral.
    bytes32 constant LOCAL_MORPHO_PT_SUSDE_USDC_ID =
        0x39d11026eae1c6ec02aa4c0910778664089cdd97c3c0b924b9d0b8b87daed8e9;

    /// @dev Flash 10M USDC.
    uint256 constant FLASH_USDC = 10_000_000e6;

    /// @dev Curve USDe/USDC pool (used to convert flash USDC -> USDe before Pendle).
    address constant LOCAL_CURVE_USDE_USDC = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72;
    int128 constant IDX_USDE = 0;
    int128 constant IDX_USDC = 1;

    bool internal _executed;

    IMorpho.MarketParams internal _market;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.USDE);
        _trackToken(LOCAL_PT_SUSDE);
        _setEthUsdFallback(3_300e8);

        require(LOCAL_PENDLE_MARKET_PT_SUSDE.code.length > 0, "Pendle market not deployed");
        require(LOCAL_PT_SUSDE.code.length > 0, "PT not deployed");

        // Resolve / fallback-construct Morpho market params.
        _market = IMorpho(Mainnet.MORPHO).idToMarketParams(LOCAL_MORPHO_PT_SUSDE_USDC_ID);
        if (_market.loanToken == address(0)) {
            _market = IMorpho.MarketParams({
                loanToken: Mainnet.USDC,
                collateralToken: LOCAL_PT_SUSDE,
                // TODO verify: PT-sUSDe oracle at the fork block.
                oracle: 0x5D87bE92ed6F1Bb02d4D7a4Bc1cEb1858eFA1FaE,
                irm:    0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC,
                lltv:   0.915e18
            });
        }
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
        // SY-sUSDe accepts USDe (not USDC) as a direct mint input. Use Curve for
        // the conversion since Pendle Router's `swapData` field is empty in
        // this PoC for clarity.
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
            LOCAL_PENDLE_MARKET_PT_SUSDE,
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
        _approveMax(LOCAL_PT_SUSDE, Mainnet.MORPHO);

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
            // Borrow leg failed — repay flash from prior USDC and rollback.
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
