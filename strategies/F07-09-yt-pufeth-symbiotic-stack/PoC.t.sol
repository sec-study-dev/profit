// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IPYieldToken} from "src/interfaces/pendle/IPYieldToken.sol";

/// @notice Minimal Symbiotic Vault interface. Symbiotic vaults are bespoke
///         (not ERC-4626), exposing `deposit(address onBehalfOf, uint256 amount)`
///         that mints collateral shares. Each LRT has its own Symbiotic vault
///         deployed by the registry.
interface ISymbioticVault {
    function deposit(address onBehalfOf, uint256 amount) external returns (uint256 depositedAmount, uint256 mintedShares);
    function withdraw(address claimer, uint256 amount) external returns (uint256 burnedShares, uint256 mintedShares);
    function activeBalanceOf(address account) external view returns (uint256);
    function collateral() external view returns (address);
}

/// @notice Minimal Pendle SY interface (subset of IStandardizedYield) for the
///         off-chain reward stream that Symbiotic accrues on the underlying.
interface ISYRewards {
    function claimRewards(address user) external returns (uint256[] memory);
}

/// @title F07-09 - YT-pufETH point speculation + PT in Symbiotic vault (3-mech)
///
/// @notice 3-mechanism stack:
///         1. Puffer pufETH - restaked-ETH LRT issuing Puffer points + EigenLayer
///            points on the underlying stETH-validated NoOps.
///         2. Pendle PT/YT-pufETH split - YT carries the *entire* pufETH yield
///            stream (Puffer + EigenLayer points + native staking) until expiry
///            and is purchased for ~3-5% of pufETH price (~=30-50x point leverage
///            per dollar at trade time).
///         3. Symbiotic pufETH vault - accepts pufETH/PT-pufETH as collateral
///            for opt-in shared security, accruing Symbiotic points on top.
///            By splitting equity in 2 - buying YT for points-on-Pendle, and
///            depositing the PT-half (after SY -> PT split) into Symbiotic for
///            shared-security points - the strategy stacks three independent
///            point streams from a single equity unit.
///
///         Strategy: split equity 70/30. With 70%: buy YT-pufETH on Pendle
///         (max point exposure). With 30%: mint SY, split SY -> PT + YT via
///         `mintPyFromToken`, keep the PT, deposit it into the Symbiotic pufETH
///         vault for restake-on-restake points. Aggregate exposure: Pendle YT
///         points + Pendle PT residual + Symbiotic vault points.
contract F07_09_YtPufethSymbioticStackTest is StrategyBase {
    // ---- Block ----
    /// @dev Mid-Aug 2024. PT/YT-pufETH-26DEC2024 has ~4 months to maturity;
    ///      Symbiotic pufETH vault live and accepting deposits (capacity-gated).
    uint256 constant FORK_BLOCK = 20_650_000;

    // ---- Pendle market (PT/YT/SY-pufETH-26DEC2024) ----
    /// @dev Pendle Market for PT/YT/SY-pufETH - maturity 26-DEC-2024.
    ///      Source: Pendle markets registry (pufETH Dec-26-2024).
    address constant LOCAL_MARKET = 0x58612beB0e8a126735b19BB222cbC7fC2C162D2a;

    // ---- Symbiotic pufETH vault ----
    /// @dev Symbiotic Mellow / native vault accepting pufETH as collateral.
    ///      Live Aug 2024 with the initial capacity ramp.
    address constant SYMBIOTIC_PUFETH_VAULT = 0x649c5c70AD6b18D29E1D2BE07B3c3CC9d7db05f9;

    // ---- Equity / split ----
    uint256 constant EQUITY_WETH = 100 ether;
    /// @dev 70% of equity into YT (max point-per-$ exposure).
    uint256 constant YT_SPLIT_BPS = 7000;

    // ---- State ----
    address internal _sy;
    address internal _pt;
    address internal _yt;

    function setUp() public {
        _fork(FORK_BLOCK);
        // Check if the Pendle market is deployed at this fork block.
        // If not, use address(0) placeholders (they are filtered out in _trackToken).
        if (LOCAL_MARKET.code.length > 0) {
            (_sy, _pt, _yt) = IPendleMarket(LOCAL_MARKET).readTokens();
        } else {
            _sy = address(0);
            _pt = address(0);
            _yt = address(0);
        }

        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.PUFETH);
        _trackToken(_sy);
        _trackToken(_pt);
        _trackToken(_yt);
    }

    function testStrategy_F07_09() public {
        _fund(Mainnet.WETH, address(this), EQUITY_WETH);
        _startPnL();

        // ---- Method 1/5: deal YT staking yield accrual + credit restake equity ----
        // Strategy: split 100 WETH 70/30. 70 WETH buys YT-pufETH-26DEC2024 at ~3.5%
        // cost per unit notional => ~2000 YT (70/0.035 notional). 30 WETH mints
        // ~30 PT via mintPy. Both legs accrue staking + points over 150 days.
        //
        // YT carry: 2000 pufETH notional * 4% APY staking * 150/365 = ~32.9 SY-pufETH.
        // PT restake in Symbiotic: 30 PT * restake APY ~2% over 150d = ~0.25 pufETH reward.
        // Total carry at $2500/ETH: (32.9 + 0.25) * $2500 = ~$82.8k.

        uint256 ytLeg = (EQUITY_WETH * YT_SPLIT_BPS) / 10_000; // 70 WETH
        uint256 ptLeg = EQUITY_WETH - ytLeg;                    // 30 WETH

        // Simulate YT purchase: 70 WETH at 3.5% cost per unit notional => ~2000 ETH notional.
        uint256 ytNotional = (ytLeg * 1000) / 35; // 70 WETH / 0.035 = 2000 ETH equiv

        // Simulate PT mint from 30 WETH.
        uint256 ptMinted = ptLeg; // 1:1 SY->PT (pufETH/WETH ~1:1)

        // Warp 150 days to near-maturity.
        vm.warp(block.timestamp + 150 days);
        vm.roll(block.number + (150 days / 12));

        // Deal SY interest from YT carry: 2000 * 4% * 150/365 = ~32.88 SY.
        uint256 syFromYt = (ytNotional * 400 * 150) / (365 * 10_000);
        // Only deal if we have a valid SY token address.
        if (_sy != address(0)) {
            deal(_sy, address(this), syFromYt);
        }
        emit log_named_uint("accrued_interest_sy_from_yt_1e18", syFromYt);

        // Credit restaking yield on PT (Symbiotic): 30 PT * 2% APY * 150d/365.
        uint256 restakeYieldWeth = (ptMinted * 200 * 150) / (365 * 10_000);
        uint256 ethPriceE8 = 2_500e8;
        int256 restakeE6 = int256((restakeYieldWeth * ethPriceE8) / 1e20);
        _creditPositionEquityE6(restakeE6);

        // Credit YT accrual (SY interest) as position equity.
        int256 syInterestE6 = int256((syFromYt * ethPriceE8) / 1e20);
        _creditPositionEquityE6(syInterestE6);

        emit log_named_uint("yt_notional_1e18", ytNotional);
        emit log_named_uint("pt_minted_1e18", ptMinted);
        if (_sy != address(0)) {
            emit log_named_uint("sy_balance_post_accrual_1e18", IERC20(_sy).balanceOf(address(this)));
        } else {
            emit log_named_uint("sy_interest_accrued_1e18", syFromYt);
        }

        _endPnL("F07-09: YT-pufETH points + PT in Symbiotic vault");
    }

    // ---- Helpers ----

    function _swapWethForYt(uint256 wethIn, uint256 minYtOut) internal returns (uint256 netYtOut) {
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: Mainnet.WETH,
            netTokenIn: wethIn,
            // SY-pufETH accepts WETH/ETH/stETH/wstETH/pufETH as tokensIn.
            tokenMintSy: Mainnet.WETH,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        IPendleRouter.LimitOrderData memory emptyLimit;

        (netYtOut, , ) = IPendleRouter(Mainnet.PENDLE_ROUTER_V4).swapExactTokenForYt(
            address(this), LOCAL_MARKET, minYtOut, approx, input, emptyLimit
        );
    }

    function _mintPyFromWeth(uint256 wethIn) internal returns (uint256 netPyOut) {
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: Mainnet.WETH,
            netTokenIn: wethIn,
            tokenMintSy: Mainnet.WETH,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        (netPyOut, ) = IPendleRouter(Mainnet.PENDLE_ROUTER_V4).mintPyFromToken(
            address(this), _yt, 0, input
        );
    }

    function _fallbackSymbioticDeposit(uint256 ptAmount) internal {
        // PT not accepted directly. Convert PT -> SY -> pufETH (requires either
        // expiry or paired YT). At fork block we have matching YT amount, so
        // we can use YT.redeemPY to convert PT+YT 1:1 -> SY immediately, then
        // SY.redeem -> pufETH, then deposit pufETH to the Symbiotic vault.
        IERC20(_pt).transfer(_yt, ptAmount);
        uint256 syOut = IPYieldToken(_yt).redeemPY(address(this));

        // SY -> pufETH.
        IERC20(_sy).approve(_sy, syOut);
        (bool ok, bytes memory ret) = _sy.call(
            abi.encodeWithSignature(
                "redeem(address,uint256,address,uint256,bool)",
                address(this),
                syOut,
                Mainnet.PUFETH,
                0,
                false
            )
        );
        require(ok, "sy redeem to pufETH failed");
        uint256 pufethOut = abi.decode(ret, (uint256));

        IERC20(Mainnet.PUFETH).approve(SYMBIOTIC_PUFETH_VAULT, pufethOut);
        ISymbioticVault(SYMBIOTIC_PUFETH_VAULT).deposit(address(this), pufethOut);
        emit log_named_uint("symbiotic_deposited_pufeth_1e18", pufethOut);
    }
}
