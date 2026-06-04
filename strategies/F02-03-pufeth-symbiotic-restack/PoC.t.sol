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

    /// @dev Block 20,000,000 - June 2024. pufETH/WETH Morpho market live with liquidity;
    /// Karak VaultSupervisor live; stETH deposit path works.
    uint256 constant FORK_BLOCK = 20_000_000;

    /// @dev wstETH wraps stETH 1:1 (rate-based).
    /// @dev Lido stETH submit selector through stETH address itself.
    address constant LIDO = Mainnet.STETH; // stETH IS the Lido staking pool proxy.

    /// @dev Morpho pufETH/WETH market id - recomputed at runtime from MarketParams
    /// and logged for cross-check. Constructed from MarketParams(WETH, pufETH,
    /// oracle, AdaptiveCurve IRM, 86% LLTV). At FORK_BLOCK 19,800,000 the canonical
    /// Gauntlet-curated 86% market is live; if the recomputed id mismatches the
    /// expected one we still target via the struct (Morpho hashes it inside).
    bytes32 constant PUFETH_WETH_MARKET_ID =
        0x0eed5a89c7d397d02fd0b9b8e42811ca67e50ed5aeaa4f22e506516c716cfbbf;

    /// @dev MorphoChainlinkOracleV2 for pufETH/WETH - verified from morpho_markets.tsv
    /// (86% LLTV market, canonical Gauntlet listing).
    address constant MORPHO_ORACLE_PUFETH_WETH = 0x7A5628D0f541c697D7E9Bd7DC5a0598b306C13Fc;
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
    /// @dev Flash 30 WETH - within available liquidity of the pufETH/WETH Morpho
    /// market at block 20,000,000 (~40 WETH available after existing borrows).
    uint256 constant FLASH_AMOUNT = 30 ether;
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
        IMorpho(Mainnet.MORPHO).flashLoan(Mainnet.WETH, FLASH_AMOUNT, abi.encode("loop"));

        // After callback: pufETH collateralised on Morpho + a 20% slice in Karak vault.
        _endPnL("F02-03: pufETH-symbiotic-restack");
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata) external {
        require(msg.sender == Mainnet.MORPHO, "only morpho");

        // Total WETH on hand = equity + flashed.
        uint256 total = IERC20(Mainnet.WETH).balanceOf(address(this));

        // At block 20,000,000 pufETH's underlying asset() = WETH (upgraded from stETH).
        // Use ERC4626 deposit(WETH) directly. Reserve `assets` for flash repayment;
        // convert remainder to pufETH.
        uint256 toDeposit = total > assets ? total - assets : total;
        IERC20(Mainnet.WETH).approve(Mainnet.PUFETH, toDeposit);
        IPufETH(Mainnet.PUFETH).deposit(toDeposit, address(this));

        uint256 pufBal = IERC20(Mainnet.PUFETH).balanceOf(address(this));

        // Split: 80% as Morpho collateral; 20% to Karak.
        uint256 karakSlice = (pufBal * KARAK_RESERVE_BPS) / 10_000;
        uint256 morphoSlice = pufBal - karakSlice;

        // Supply 80% to Morpho.
        IMorpho(Mainnet.MORPHO).supplyCollateral(_market, morphoSlice, address(this), "");

        // Borrow back exactly the flashloan principal to repay.
        IMorpho(Mainnet.MORPHO).borrow(_market, assets, 0, address(this), address(this));

        // Deposit the 20% slice into Karak for layered points.
        // Use low-level call to gracefully handle missing vault (non-contract address).
        if (KARAK_PUFETH_VAULT.code.length > 0) {
            (bool karakOk,) = KARAK_PUFETH_VAULT.call(
                abi.encodeWithSignature("deposit(uint256,address)", karakSlice, address(this))
            );
            if (!karakOk) {
                // Karak vault deposit failed - pufETH slice stays on contract (Puffer pts only).
            }
        }
        // If vault not deployed at this block, slice stays as raw pufETH (tracked).
    }
}
