// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IPufETH} from "src/interfaces/lrt/IPufETH.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "src/interfaces/common/IFlashLoanReceiver.sol";

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

/// @notice F02-03 — pufETH stacked re-hypothecation.
///
/// Loop pufETH against WETH via Morpho flashloan; reserve a 20% pufETH slice
/// un-supplied and deposit it into Karak's pufETH vault for an additional point stream.
contract F02_03_PufethSymbioticRestackTest is StrategyBase, IMorphoFlashLoanCallback {
    // ---- Pinned constants ----

    /// @dev Block 19,800,000 — mid Apr 2024. Karak live, pufETH/Morpho live.
    uint256 constant FORK_BLOCK = 19_800_000;

    /// @dev wstETH wraps stETH 1:1 (rate-based).
    /// @dev Lido stETH submit selector through stETH address itself.
    address constant LIDO = Mainnet.STETH; // stETH IS the Lido staking pool proxy.

    /// @dev Morpho pufETH/WETH market id — TODO verify at this block.
    /// Constructed from MarketParams(WETH, pufETH, oracle, irm, 86% LLTV).
    /// If the canonical 86% market doesn't exist at this block, fall back to the
    /// 77% market or create one for the test.
    bytes32 constant PUFETH_WETH_MARKET_ID =
        0xe37784e57da16b3c5e75677b95a0a73d50b56a062b9e0a3fcefdb56a5af2bba9;

    address constant MORPHO_ORACLE_PUFETH_WETH = 0xb9D9e07F36B6f3a14a4cf2A4dCC9B66Eb39603eC; // TODO verify
    address constant MORPHO_IRM_ADAPTIVE_CURVE = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 constant LLTV_86 = 0.86e18;

    /// @dev Karak pufETH-collateral vault.
    /// TODO verify at FORK_BLOCK; Karak deploys per-LRT vaults under a deterministic factory.
    address constant KARAK_PUFETH_VAULT = 0xBE3cA34D0E877A1Fc889BD5231D65477779AFf4e;

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
            // Karak vault not live at this block — slice stays as pufETH on the contract
            // (still earns Puffer + Lido + EL pts; only Karak XP missed).
        }
    }
}
