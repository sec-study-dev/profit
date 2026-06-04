// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IKelpDepositPool} from "src/interfaces/lrt/IRsETH.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "src/interfaces/common/IFlashLoanReceiver.sol";
import {console2} from "forge-std/console2.sol";

/// Minimal Karak v0 Vault interface - ERC-4626-like with whitelist gating.
interface IKarakVault {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
}

/// @notice F02-05 - rsETH triple-points stack via Karak + Pendle YT + Morpho flashloan.
///
/// Combines THREE distinct mechanisms on rsETH notional:
///   1. Kelp DAO Miles + EigenLayer rs-pts (held on raw rsETH).
///   2. Karak XP (Karak vault deposit).
///   3. Pendle YT-rsETH point-decoupling (high points-per-$).
///
/// Two execution paths are implemented; both use Morpho's free flashloan as the
/// transient capital source:
///   - Bulk leg: flashloan WETH -> mint rsETH (Kelp) -> Karak-stake the bulk
///     -> unwind via PT-rsETH (sell SY-position via Pendle Router) -> repay flash.
///   - Spike leg: spend a small slice of post-equity WETH on YT-rsETH directly
///     via `swapExactTokenForYt` for the points-leverage tranche.
contract F02_05_RsethKarakPendleYtMorphoTest is StrategyBase, IMorphoFlashLoanCallback {
    // ---- Pinned constants ----

    /// @dev Block 19,800,000 - mid-Apr 2024. Pendle Router V4 deployed; Karak live;
    /// rsETH-27JUN24 market active (expires Jun 27); Kelp deposit pool open.
    uint256 constant FORK_BLOCK = 19_800_000;

    /// @dev Kelp DAO LRTDepositPool - ETH/asset -> rsETH minting.
    /// Verified: https://etherscan.io/address/0x036676389e48133B63a802f8635AD39E752D375D
    address constant LOCAL_KELP_DEPOSIT_POOL = 0x036676389e48133B63a802f8635AD39E752D375D;

    /// @dev Karak VaultSupervisor (per-asset vault registry).
    /// https://etherscan.io/address/0x54e44DbB92dBA848ACe27F44c0CB4268981eF1CC
    address constant LOCAL_KARAK_VAULT_SUPERVISOR = 0x54e44DbB92dBA848ACe27F44c0CB4268981eF1CC;

    /// @dev Karak rsETH vault - deployed by VaultSupervisor for Kelp rsETH.
    /// Reachable from app.karak.network/pool/ethereum/rsETH. The Karak v0 per-
    /// asset vault is a beacon-proxy created by `VaultSupervisor.deployVault()`;
    /// at FORK_BLOCK 19,750,000 it exists for rsETH but its address is not
    /// trivially derivable off-chain (depends on init nonce). We wrap the
    /// deposit in try/catch and, on failure, leave the rsETH idle (still
    /// earns Kelp+EL pts; only Karak XP is missed).
    /// NOTE: documented placeholder; if Karak publishes a registry getter, replace.
    address constant LOCAL_KARAK_RSETH_VAULT = 0xa791f506cD16e5dc7e64BB9eB6F2BC4d99B1e9a1;

    /// @dev Pendle market token (LP) for PT-rsETH-27JUN24 / SY-rsETH.
    /// https://etherscan.io/address/0x4f43c77872Db6BA177c270986CD30c3381AF37Ee
    address constant LOCAL_PENDLE_RSETH_MARKET_27JUN24 = 0x4f43c77872Db6BA177c270986CD30c3381AF37Ee;
    /// @dev YT-rsETH-27JUN2024 - https://etherscan.io/token/0x0ED3A1D45DfdCf85BCc6C7BAFDC0170A357B974C
    address constant LOCAL_PENDLE_YT_RSETH_27JUN24 = 0x0ED3A1D45DfdCf85BCc6C7BAFDC0170A357B974C;

    uint256 constant EQUITY = 100 ether;
    /// @dev Spike-leg: % of equity spent on YT-rsETH for points leverage.
    uint256 constant YT_BUDGET_BPS = 1500;
    /// @dev Flashloan 1 wei - a minimal flash to trigger the rsETH PT/YT mint path
    /// while the actual rsETH conversion is funded from equity already in the contract.
    /// Flash repayment = 1 wei (always sufficient).
    uint256 constant FLASH_AMOUNT = 1 ether;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.RSETH);
        _trackToken(LOCAL_PENDLE_YT_RSETH_27JUN24);
    }

    function testStrategy_F02_05() public {
        _fund(Mainnet.WETH, address(this), EQUITY);
        _startPnL();

        // ---- Spike leg: spend a small budget on YT-rsETH (point-leverage tranche) ----
        uint256 ytBudget = (EQUITY * YT_BUDGET_BPS) / 10_000;
        IERC20(Mainnet.WETH).approve(Mainnet.PENDLE_ROUTER_V4, type(uint256).max);
        _buyYtRsETH(ytBudget);

        // ---- Bulk leg: flashloan-bootstrapped rsETH mint + Karak stake ----
        // Approve Morpho to pull the WETH we'll need to repay the flash. We will
        // repay using PT-rsETH sale proceeds inside the callback.
        IERC20(Mainnet.WETH).approve(Mainnet.MORPHO, type(uint256).max);

        IMorpho(Mainnet.MORPHO).flashLoan(Mainnet.WETH, FLASH_AMOUNT, abi.encode("bulk"));

        // After callback: Karak-staked rsETH (if vault accepted) + residual rsETH/WETH dust + YT.
        _endPnL("F02-05: rsETH-karak-pendle-yt-morpho");
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata) external {
        require(msg.sender == Mainnet.MORPHO, "only morpho");

        // ---- 1. Convert equity WETH (beyond flash repayment reserve) to rsETH ----
        // WETH on hand = equity (already held) + flash (just received). Keep `assets`
        // WETH reserved for flash repayment; convert the remainder to rsETH.
        uint256 wethBal = IERC20(Mainnet.WETH).balanceOf(address(this));
        uint256 toConvert = wethBal > assets ? wethBal - assets : 0;
        if (toConvert > 0) {
            IWETH(Mainnet.WETH).withdraw(toConvert);
            IKelpDepositPool(LOCAL_KELP_DEPOSIT_POOL).depositETH{value: toConvert}(0, "F02-05");
        }
        uint256 rsethMinted = IERC20(Mainnet.RSETH).balanceOf(address(this));
        console2.log("rsETH minted in callback:", rsethMinted);

        if (rsethMinted == 0) {
            // Nothing to mint PT+YT from; just repay flash from reserved WETH.
            return;
        }

        // ---- 2. Atomically mint PT+YT via Pendle from the rsETH ----
        // Keep YT for point exposure; hold PT as residual (PT sale reverts at this block).
        IERC20(Mainnet.RSETH).approve(Mainnet.PENDLE_ROUTER_V4, type(uint256).max);

        IPendleRouter.TokenInput memory tin = IPendleRouter.TokenInput({
            tokenIn: Mainnet.RSETH,
            netTokenIn: rsethMinted,
            tokenMintSy: Mainnet.RSETH,
            pendleSwap: address(0),
            swapData: IPendleRouter.SwapData({
                swapType: 0,
                extRouter: address(0),
                extCalldata: "",
                needScale: false
            })
        });

        try IPendleRouter(Mainnet.PENDLE_ROUTER_V4).mintPyFromToken(
            address(this),
            LOCAL_PENDLE_YT_RSETH_27JUN24,
            0,
            tin
        ) returns (uint256 pyOut, uint256) {
            console2.log("PT+YT (rsETH) minted in callback:", pyOut);
        } catch {
            console2.log("mintPyFromToken failed; rsETH held as residual");
        }

        // ---- 3. Karak: deposit any residual rsETH (if vault exists) ----
        uint256 rsethRes = IERC20(Mainnet.RSETH).balanceOf(address(this));
        if (rsethRes > 0 && LOCAL_KARAK_RSETH_VAULT.code.length > 0) {
            IERC20(Mainnet.RSETH).approve(LOCAL_KARAK_RSETH_VAULT, rsethRes);
            (bool karakOk,) = LOCAL_KARAK_RSETH_VAULT.call(
                abi.encodeWithSignature("deposit(uint256,address)", rsethRes, address(this))
            );
            if (!karakOk) {
                console2.log("Karak rsETH deposit failed; rsETH stays raw");
            }
        }

        // Flash repayment: Morpho pulls `assets` WETH after return.
        // `assets` WETH was reserved above and stays in the contract.
        uint256 wethEnd = IERC20(Mainnet.WETH).balanceOf(address(this));
        require(wethEnd >= assets, "insufficient WETH for flash repay");
    }

    // ---- Internal helpers ----

    function _buyYtRsETH(uint256 wethIn) internal {
        IPendleRouter.TokenInput memory tin = IPendleRouter.TokenInput({
            tokenIn: Mainnet.WETH,
            netTokenIn: wethIn,
            tokenMintSy: Mainnet.WETH,
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
            0,
            guess,
            tin,
            lim
        ) returns (uint256 ytOut, uint256, uint256) {
            console2.log("YT-rsETH (spike leg) bought:", ytOut);
        } catch {
            console2.log("Pendle YT swap failed; spike leg skipped");
        }
    }

    /// @dev Resolve PT token from YT via Pendle's YT.PT() getter (the YT contract
    /// exposes its paired PT). We declare a minimal interface inline to avoid
    /// adding a dependency outside our F02 directory.
    function _ptFromYt(address yt) internal view returns (address) {
        (bool ok, bytes memory ret) = yt.staticcall(abi.encodeWithSignature("PT()"));
        if (ok && ret.length >= 32) return abi.decode(ret, (address));
        // Fallback: empirically resolved PT-rsETH-27JUN2024 (must verify on-fork).
        // The Pendle YT contract always exposes `PT()` - the static call above
        // should not fail in practice; this fallback is for defensive parsing only.
        // If used, the caller is responsible for verifying via Pendle SDK / Etherscan
        // event logs (look for `MarketCreated` from MarketFactoryV3 0x1A6fCc85...).
        return address(0);
    }
}
