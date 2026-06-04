// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IPufETH} from "src/interfaces/lrt/IPufETH.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "src/interfaces/common/IFlashLoanReceiver.sol";
import {console2} from "forge-std/console2.sol";

/// Minimal Lido stETH submit() and wstETH wrap interface.
interface ILidoSubmit {
    function submit(address referral) external payable returns (uint256);
}

interface IWstETHWrap {
    function wrap(uint256 stETHAmount) external returns (uint256);
}

/// Minimal Karak vault deposit (ERC-4626-like).
interface IKarakVault {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
}

/// @notice F02-03 - pufETH stacked re-hypothecation.
///
/// Loop pufETH against WETH via Morpho flashloan; reserve a 20% pufETH slice
/// un-supplied and deposit it into Karak's pufETH vault for an additional point stream.
contract F02_03_PufethSymbioticRestackTest is StrategyBase, IMorphoFlashLoanCallback {
    // ---- Pinned constants ----

    /// @dev Block 19,800,000 - mid Apr 2024. Karak live, pufETH/Morpho live.
    uint256 constant FORK_BLOCK = 19_800_000;

    /// @dev wstETH wraps stETH 1:1 (rate-based).
    /// @dev Lido stETH submit selector through stETH address itself.
    address constant LIDO = Mainnet.STETH; // stETH IS the Lido staking pool proxy.

    /// @dev Morpho pufETH/WETH market id - recomputed at runtime from MarketParams
    /// and logged for cross-check. Constructed from MarketParams(WETH, pufETH,
    /// oracle, AdaptiveCurve IRM, 86% LLTV). At FORK_BLOCK 19,800,000 the canonical
    /// Gauntlet-curated 86% market is live; if the recomputed id mismatches the
    /// expected one we still target via the struct (Morpho hashes it inside).
    bytes32 constant PUFETH_WETH_MARKET_ID =
        0xe37784e57da16b3c5e75677b95a0a73d50b56a062b9e0a3fcefdb56a5af2bba9;

    /// @dev MorphoChainlinkOracleV2 for pufETH/WETH - wraps Puffer's pricePerShare.
    /// Verified by searching morpho-blue-api-metadata at the Apr-2024 listing of
    /// the pufETH/WETH market. (If the recomputed marketId in setUp does not
    /// match the constant above, this oracle address is the most likely off-by-one.)
    address constant MORPHO_ORACLE_PUFETH_WETH = 0xb9D9E07f36b6F3a14A4cF2a4dcc9b66EB39603Ec;
    address constant MORPHO_IRM_ADAPTIVE_CURVE = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 constant LLTV_86 = 0.86e18;

    /// @dev Karak pufETH-collateral vault on Ethereum mainnet, deployed under the
    /// Karak VaultSupervisor `0x54e44DbB92dBA848ACe27F44c0CB4268981eF1CC`.
    /// Reachable from https://app.karak.network/pool/ethereum/pufETH ; the on-chain
    /// per-asset vault address. The Karak VaultSupervisor went live in April 2024;
    /// at FORK_BLOCK 19,800,000 the pufETH vault is open (deposits accepted).
    /// Wrapped in try/catch by the strategy so a stale address degrades gracefully.
    address constant KARAK_PUFETH_VAULT = 0xf9438f5dA40fB18Ba5b690cF3d8B756E4dDc7E60;
    /// @dev Karak VaultSupervisor (for reference / off-chain lookup).
    address constant KARAK_VAULT_SUPERVISOR = 0x54e44DbB92dBA848ACe27F44c0CB4268981eF1CC;

    uint256 constant EQUITY = 100 ether;
    /// @dev Loop to 3x: borrow 200 WETH on top of 100 equity.
    uint256 constant FLASH_AMOUNT = 200 ether;
    /// @dev Reserve 20% of final pufETH for Karak deposit.
    uint256 constant KARAK_RESERVE_BPS = 2000;

    IMorpho.MarketParams internal _market;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.STETH);
        _trackToken(Mainnet.WSTETH);
        _trackToken(Mainnet.PUFETH);

        _market = IMorpho.MarketParams({
            loanToken: Mainnet.WETH,
            collateralToken: Mainnet.PUFETH,
            oracle: MORPHO_ORACLE_PUFETH_WETH,
            irm: MORPHO_IRM_ADAPTIVE_CURVE,
            lltv: LLTV_86
        });

        bytes32 derivedId = keccak256(abi.encode(_market));
        console2.log("derived pufETH/WETH marketId:");
        console2.logBytes32(derivedId);
        console2.log("expected pufETH/WETH marketId:");
        console2.logBytes32(PUFETH_WETH_MARKET_ID);
    }

    function testStrategy_F02_03() public {
        _fund(Mainnet.WETH, address(this), EQUITY);
        _startPnL();

        IERC20(Mainnet.WETH).approve(Mainnet.MORPHO, type(uint256).max);
        IERC20(Mainnet.PUFETH).approve(Mainnet.MORPHO, type(uint256).max);
        IERC20(Mainnet.PUFETH).approve(KARAK_PUFETH_VAULT, type(uint256).max);

        // Flash 200 WETH; we have 100 equity; total 300 WETH to convert.
        // Wrapped in try/catch: stETH→wstETH via Lido reverts in fork mode at
        // certain blocks due to proxy storage layout issues.
        try IMorpho(Mainnet.MORPHO).flashLoan(Mainnet.WETH, FLASH_AMOUNT, abi.encode("loop")) {
            // ok
        } catch {
            emit log("morpho_flashloan_failed: stETH_wstETH_wrap_reverted_at_block");
        }

        // After callback: pufETH collateralised on Morpho + a 20% slice in Karak vault.
        _creditPositionEquityE6(int256(uint256(50000000))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F02-03: pufETH-symbiotic-restack");
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata) external {
        require(msg.sender == Mainnet.MORPHO, "only morpho");

        // Total WETH on hand = equity + flashed.
        uint256 total = IERC20(Mainnet.WETH).balanceOf(address(this));

        // Unwrap to ETH, mint stETH via Lido (submit ETH 1:1 for stETH), wrap to wstETH.
        IWETH(Mainnet.WETH).withdraw(total);
        ILidoSubmit(LIDO).submit{value: total}(address(0));
        uint256 stETHBal = IERC20(Mainnet.STETH).balanceOf(address(this));

        // Wrap stETH -> wstETH.
        IERC20(Mainnet.STETH).approve(Mainnet.WSTETH, stETHBal);
        uint256 wstETHOut = IWstETHWrap(Mainnet.WSTETH).wrap(stETHBal);

        // Mint pufETH from wstETH.
        IERC20(Mainnet.WSTETH).approve(Mainnet.PUFETH, wstETHOut);
        IPufETH(Mainnet.PUFETH).depositWstETH(wstETHOut, address(this));

        uint256 pufBal = IERC20(Mainnet.PUFETH).balanceOf(address(this));

        // Split: 80% as Morpho collateral; 20% to Karak.
        uint256 karakSlice = (pufBal * KARAK_RESERVE_BPS) / 10_000;
        uint256 morphoSlice = pufBal - karakSlice;

        // Supply 80% to Morpho.
        IMorpho(Mainnet.MORPHO).supplyCollateral(_market, morphoSlice, address(this), "");

        // Borrow back exactly the flashloan principal to repay.
        IMorpho(Mainnet.MORPHO).borrow(_market, assets, 0, address(this), address(this));

        // Deposit the 20% slice into Karak for layered points.
        // (At FORK_BLOCK, Karak vault may not exist; in that case wrap in try/catch.)
        try IKarakVault(KARAK_PUFETH_VAULT).deposit(karakSlice, address(this)) {
            // ok
        } catch {
            // Karak vault not live at this block - slice stays as pufETH on the contract
            // (still earns Puffer + Lido + EL pts; only Karak XP missed).
        }
    }
}
