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
    /// @dev Dec 2024. PT/YT-pufETH-26DEC2024 near maturity;
    ///      Symbiotic pufETH vault live. FORK_BLOCK bumped to 21_200_000 because
    ///      the Pendle pufETH-26DEC2024 market (0x58612beB...) only has code
    ///      from that block onward.
    uint256 constant FORK_BLOCK = 21_200_000;

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
        (_sy, _pt, _yt) = IPendleMarket(LOCAL_MARKET).readTokens();

        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.PUFETH);
        _trackToken(_sy);
        _trackToken(_pt);
        _trackToken(_yt);
    }

    function testStrategy_F07_09() public {
        _fund(Mainnet.WETH, address(this), EQUITY_WETH);
        _startPnL();

        IERC20(Mainnet.WETH).approve(Mainnet.PENDLE_ROUTER_V4, type(uint256).max);

        uint256 ytLeg = (EQUITY_WETH * YT_SPLIT_BPS) / 10_000;
        uint256 ptLeg = EQUITY_WETH - ytLeg;

        // ---- 1. YT leg: max point exposure via Pendle YT swap ----
        uint256 ytOut = _swapWethForYt(ytLeg, 0);
        emit log_named_uint("yt_received_1e18", ytOut);

        // ---- 2. PT leg: mintPyFromToken splits SY -> PT + YT 1:1; keep the PT.
        //          The freshly-minted YT is also held (it's the same YT token,
        //          adding to the YT stack), and the PT goes into Symbiotic.
        uint256 pyOut = _mintPyFromWeth(ptLeg);
        emit log_named_uint("py_minted_per_side_1e18", pyOut);
        // After this, balance increments: +pyOut PT, +pyOut YT.

        // ---- 3. Symbiotic deposit: pufETH-vault accepts PT-pufETH as collateral
        //          (this is the 3rd mechanism - restake-on-restake points).
        IERC20(_pt).approve(SYMBIOTIC_PUFETH_VAULT, type(uint256).max);
        try ISymbioticVault(SYMBIOTIC_PUFETH_VAULT).deposit(address(this), pyOut) returns (
            uint256 depositedAmount, uint256 mintedShares
        ) {
            emit log_named_uint("symbiotic_deposited_pt_1e18", depositedAmount);
            emit log_named_uint("symbiotic_shares_minted_1e18", mintedShares);
        } catch {
            // Vault may not accept PT directly at this block; fall back to
            // redeeming PT for pufETH first then depositing the pufETH.
            _fallbackSymbioticDeposit(pyOut);
        }

        // ---- 4. Carry: warp ~150 days to near-maturity and crystallise on-chain
        //          interest + reward tokens from the YT.
        vm.warp(block.timestamp + 150 days);
        vm.roll(block.number + (150 days / 12));

        try IPYieldToken(_yt).redeemDueInterestAndRewards(address(this), true, true) returns (
            uint256 interestOut, uint256[] memory
        ) {
            emit log_named_uint("accrued_interest_sy_1e18", interestOut);
        } catch {
            // Some YT variants gate post-expiry differently; ignored in PoC.
        }

        // ---- 5. Report on-chain legs ----
        emit log_named_uint("sy_balance_post_accrual_1e18", IERC20(_sy).balanceOf(address(this)));
        emit log_named_uint("yt_balance_post_accrual_1e18", IERC20(_yt).balanceOf(address(this)));

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
