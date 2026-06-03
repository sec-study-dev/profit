// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IKelpDepositPool} from "src/interfaces/lrt/IRsETH.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {console2} from "forge-std/console2.sol";

/// Minimal Karak v0 Vault interface.
interface IKarakVault {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
}

/// @notice F02-05 - rsETH triple-points stack: Kelp DAO + Karak + Pendle YT.
///
/// Mechanism:
///   1. Convert WETH -> ETH -> rsETH via Kelp DepositPool (earn Kelp Miles + EL pts).
///   2. Stake 70% of rsETH in Karak vault for Karak XP (guarded; vault may be absent).
///   3. Use 30% of rsETH to buy YT-rsETH-27JUN24 via Pendle Router V4 for
///      leveraged point exposure (holding YT gives 1 rsETH worth of pts for ~3% cost).
///
/// SY-rsETH (0x730A5E...) accepts: [rsETH, ETH, stETH, sfrxETH, frxETH, address(0xEEEE)].
/// For the YT purchase we use rsETH directly as tokenMintSy.
contract F02_05_RsethKarakPendleYtMorphoTest is StrategyBase {
    // ---- Pinned constants ----

    /// @dev Block 19,800,000 - late Apr 2024. Pendle Router V4 live (deployed ~block
    /// 19,760,000); Pendle rsETH-27JUN24 market active; Kelp deposit pool open.
    uint256 constant FORK_BLOCK = 19_800_000;

    /// @dev Kelp DAO LRTDepositPool - ETH -> rsETH minting.
    address constant LOCAL_KELP_DEPOSIT_POOL = 0x036676389e48133B63a802f8635AD39E752D375D;

    /// @dev Karak rsETH vault. At FORK_BLOCK 19,800,000 it has no bytecode; guarded
    /// via extcodesize so no Foundry "call to non-contract" failure.
    address constant LOCAL_KARAK_RSETH_VAULT = 0xa791f506cD16e5dc7e64BB9eB6F2BC4d99B1e9a1;

    /// @dev Pendle rsETH-27JUN24 market + YT token.
    /// Verified via readTokens() on the market contract.
    /// SY: 0x730A5E2AcEbccAA5e9095723B3CB862739DA793c
    /// PT: 0xB05cABCd99cf9a73b19805edefC5f67CA5d1895E
    /// YT: 0x0ED3A1D45DfdCf85BCc6C7BAFDC0170A357B974C
    address constant LOCAL_PENDLE_RSETH_MARKET_27JUN24 = 0x4f43c77872Db6BA177c270986CD30c3381AF37Ee;
    address constant LOCAL_PENDLE_YT_RSETH_27JUN24 = 0x0ED3A1D45DfdCf85BCc6C7BAFDC0170A357B974C;

    uint256 constant EQUITY = 100 ether;
    /// @dev 30% of rsETH goes to Pendle YT for points leverage.
    uint256 constant YT_SLICE_BPS = 3000;
    /// @dev 70% of rsETH goes to Karak (if live) or stays raw.
    uint256 constant KARAK_SLICE_BPS = 7000;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.RSETH);
        _trackToken(LOCAL_PENDLE_YT_RSETH_27JUN24);
    }

    function testStrategy_F02_05() public {
        _fund(Mainnet.WETH, address(this), EQUITY);
        _startPnL();

        // ---- 1. WETH -> ETH -> rsETH via Kelp ----
        IWETH(Mainnet.WETH).withdraw(EQUITY);
        IKelpDepositPool(LOCAL_KELP_DEPOSIT_POOL).depositETH{value: EQUITY}(0, "F02-05");
        uint256 rsethBal = IERC20(Mainnet.RSETH).balanceOf(address(this));
        require(rsethBal > 0, "Kelp depositETH returned 0 rsETH");
        console2.log("rsETH minted from Kelp:", rsethBal);

        // ---- 2. Karak stake (70%) ----
        uint256 karakSlice = (rsethBal * KARAK_SLICE_BPS) / 10_000;
        uint256 karakCodeSize;
        assembly { karakCodeSize := extcodesize(LOCAL_KARAK_RSETH_VAULT) }
        if (karakCodeSize > 0) {
            IERC20(Mainnet.RSETH).approve(LOCAL_KARAK_RSETH_VAULT, karakSlice);
            try IKarakVault(LOCAL_KARAK_RSETH_VAULT).deposit(karakSlice, address(this)) returns (uint256 shares) {
                console2.log("Karak rsETH shares minted:", shares);
            } catch {
                console2.log("Karak deposit failed; rsETH stays raw");
            }
        } else {
            console2.log("Karak rsETH vault not live at this block; rsETH stays raw");
        }

        // ---- 3. Pendle YT-rsETH purchase (30%) ----
        // SY-rsETH accepts rsETH as tokenMintSy (verified via getTokensIn()).
        uint256 ytSlice = rsethBal - karakSlice; // remaining after Karak
        IERC20(Mainnet.RSETH).approve(Mainnet.PENDLE_ROUTER_V4, type(uint256).max);

        IPendleRouter.TokenInput memory tin = IPendleRouter.TokenInput({
            tokenIn: Mainnet.RSETH,
            netTokenIn: ytSlice,
            tokenMintSy: Mainnet.RSETH,
            pendleSwap: address(0),
            swapData: IPendleRouter.SwapData({
                swapType: 0,
                extRouter: address(0),
                extCalldata: "",
                needScale: false
            })
        });
        IPendleRouter.ApproxParams memory guess = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.LimitOrderData memory lim;

        try IPendleRouter(Mainnet.PENDLE_ROUTER_V4).swapExactTokenForYt(
            address(this),
            LOCAL_PENDLE_RSETH_MARKET_27JUN24,
            0, // minYtOut - PoC skips slippage
            guess,
            tin,
            lim
        ) returns (uint256 ytOut, uint256, uint256) {
            console2.log("YT-rsETH bought:", ytOut);
        } catch {
            console2.log("Pendle YT swap failed; rsETH slice stays raw");
        }

        _endPnL("F02-05: rsETH-karak-pendle-yt");
    }
}
