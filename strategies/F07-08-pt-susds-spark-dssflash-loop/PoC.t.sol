// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";
import {IDssFlash} from "src/interfaces/cdp/IDssFlash.sol";
import {IERC3156FlashBorrower} from "src/interfaces/common/IFlashLoanReceiver.sol";
import {IDssPsm} from "src/interfaces/cdp/IDssPsm.sol";
import {ISUSDS} from "src/interfaces/stable/ISUSDS.sol";

/// @notice Minimal DAI <-> USDS swapper (Sky Protocol DAI <-> USDS 1:1 converter).
interface IUSDSDaiConverter {
    function daiToUsds(address usr, uint256 wad) external;
    function usdsToDai(address usr, uint256 wad) external;
}

/// @title F07-08 - PT-sUSDS + Spark + DssFlash bootstrap (3-mech)
///
/// @notice 3-mechanism stack:
///         1. Pendle PT-sUSDS - fixed-discount claim on 1 sUSDS at maturity.
///            sUSDS accretes the Sky Savings Rate (~6.5% APY).
///         2. Morpho Blue PT-sUSDS/USDS isolated market (PendleSparkLinearDiscount
///            oracle) - Spark-affiliated curator markets PT-sUSDS at 91.5% LLTV.
///         3. MakerDAO DSS Flash mint - flash-mint DAI free of premium (toll=0),
///            convert DAI -> USDS 1:1 via the Sky DAI/USDS converter, swap
///            USDS -> USDC via PSM, buy PT in one atomic transaction. Reverse on
///            unwind. The flash leg eliminates the "initial PT buy" capital
///            requirement and lets the strategy bootstrap to the full target
///            leverage in a single tx (no rate ramp-up between loops).
///
///         Strategy: flash-mint DAI -> DAI->USDS->USDC -> buy PT-sUSDS via Pendle ->
///         supply PT to Morpho -> borrow USDS -> USDS->DAI -> repay flash. Net
///         position: PT-sUSDS collateral + USDS debt on Morpho.
contract F07_08_PtSusdsSparkDssflashLoopTest is StrategyBase, IERC3156FlashBorrower {
    // ---- Block ----
    /// @dev Early Nov 2024. PT-sUSDS-25SEP2025 issued, ~10 months to maturity.
    uint256 constant FORK_BLOCK = 21_050_000;

    // ---- Pendle market (PT/YT/SY-sUSDS-25SEP2025) ----
    /// @dev Pendle Market for PT/YT/SY-sUSDS - maturity 25-SEP-2025.
    address constant LOCAL_MARKET = 0xCaE62858DB831272A03768f5844cbe1B40bB381f;

    // ---- Morpho market: PT-sUSDS / USDS ----
    /// @dev PendleSparkLinearDiscount oracle for PT-sUSDS-25SEP2025 vs USDS.
    address constant MORPHO_ORACLE_PT_SUSDS = 0x9abcE44A60C93ce39942e0A4D6E0Ab1d3B3A8e90;
    address constant MORPHO_IRM_ADAPTIVE_CURVE = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 constant LLTV_91_5 = 0.915e18;

    // ---- Sky / Maker plumbing ----
    /// @dev Sky DAI<->USDS 1:1 converter (post-rebrand bridge).
    address constant DAI_USDS_CONVERTER = 0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A;

    // ---- Equity / sizing ----
    uint256 constant EQUITY_USDS = 1_000_000e18;
    /// @dev Flash-mint multiplier: target K = 4 => flash 3* equity in DAI.
    uint256 constant FLASH_DAI = 3_000_000e18;

    // ---- State ----
    address internal _sy;
    address internal _pt;
    address internal _yt;
    IMorpho.MarketParams internal _market;

    function setUp() public {
        _fork(FORK_BLOCK);
        (_sy, _pt, _yt) = IPendleMarket(LOCAL_MARKET).readTokens();

        _trackToken(Mainnet.USDS);
        _trackToken(Mainnet.SUSDS);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.USDC);
        _trackToken(_pt);
        _trackToken(_sy);

        _market = IMorpho.MarketParams({
            loanToken: Mainnet.USDS,
            collateralToken: _pt,
            oracle: MORPHO_ORACLE_PT_SUSDS,
            irm: MORPHO_IRM_ADAPTIVE_CURVE,
            lltv: LLTV_91_5
        });
    }

    function testStrategy_F07_08() public {
        // SKIP: The Morpho oracle for PT-sUSDS/USDS (0x9abcE44A...) was never
        // deployed on mainnet at any block in the fork range. No PT-sUSDS/USDS
        // Morpho market exists (verified against morpho_markets.tsv and on-chain
        // idToMarketParams calls up to block 22M). The Pendle sUSDS market SY
        // (0x9d6Ec7a7...) only accepts stataUSDC as tokenMintSy (not USDS/DAI),
        // making the strategy irrecoverable without a full redesign.
        vm.skip(true);
        _fund(Mainnet.USDS, address(this), EQUITY_USDS);
        _startPnL();

        IERC20(Mainnet.DAI).approve(Mainnet.DSS_FLASH, type(uint256).max);
        IERC20(Mainnet.DAI).approve(DAI_USDS_CONVERTER, type(uint256).max);
        IERC20(Mainnet.USDS).approve(DAI_USDS_CONVERTER, type(uint256).max);
        IERC20(Mainnet.USDS).approve(Mainnet.PENDLE_ROUTER_V4, type(uint256).max);
        IERC20(_pt).approve(Mainnet.MORPHO, type(uint256).max);

        // Convert equity USDS -> DAI to bridge into the flash-mint settlement layer.
        IUSDSDaiConverter(DAI_USDS_CONVERTER).usdsToDai(address(this), EQUITY_USDS);

        // Trigger flash mint. DssFlash.toll = 0 (free flash mint).
        IDssFlash(Mainnet.DSS_FLASH).flashLoan(
            address(this),
            Mainnet.DAI,
            FLASH_DAI,
            abi.encode("bootstrap")
        );

        // Convert any trailing DAI back to USDS.
        uint256 daiBal = IERC20(Mainnet.DAI).balanceOf(address(this));
        if (daiBal > 0) {
            IUSDSDaiConverter(DAI_USDS_CONVERTER).daiToUsds(address(this), daiBal);
        }

        emit log_named_uint("pt_collateral_1e18", _getCollateral());
        emit log_named_uint("usds_debt_1e18", _getBorrowedAssets());
        emit log_named_uint("equity_usds_1e18", EQUITY_USDS);

        _endPnL("F07-08: PT-sUSDS + Spark + DssFlash bootstrap");
    }

    /// @notice ERC-3156 flash callback. DssFlash gives us `FLASH_DAI` DAI; we
    ///         use the equity USDS already converted to DAI plus the flashed
    ///         amount to buy PT-sUSDS in one shot, supply to Morpho, borrow back
    ///         enough USDS to repay the flash, then bridge USDS->DAI.
    function onFlashLoan(
        address /* initiator */,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata /* data */
    ) external returns (bytes32) {
        require(msg.sender == Mainnet.DSS_FLASH, "only DssFlash");
        require(token == Mainnet.DAI, "expected DAI");
        require(fee == 0, "DssFlash toll should be zero");

        // Total DAI on hand = equity-converted + flashed.
        uint256 totalDai = IERC20(Mainnet.DAI).balanceOf(address(this));

        // DAI -> USDS 1:1 via converter.
        IUSDSDaiConverter(DAI_USDS_CONVERTER).daiToUsds(address(this), totalDai);
        uint256 usdsTotal = IERC20(Mainnet.USDS).balanceOf(address(this));

        // Buy PT-sUSDS using the entire USDS bag.
        _swapUsdsForPt(usdsTotal, 0);

        // Supply all PT to Morpho.
        IMorpho(Mainnet.MORPHO).supplyCollateral(
            _market, IERC20(_pt).balanceOf(address(this)), address(this), ""
        );

        // Borrow enough USDS to repay the flash. We borrow exactly `amount`
        // (the flashed DAI) - bridging USDS -> DAI 1:1 to repay.
        IMorpho(Mainnet.MORPHO).borrow(_market, amount, 0, address(this), address(this));

        // Convert USDS -> DAI 1:1 to repay DssFlash.
        IUSDSDaiConverter(DAI_USDS_CONVERTER).usdsToDai(address(this), amount);

        // ERC-3156: approve repayment.
        IERC20(Mainnet.DAI).approve(msg.sender, amount + fee);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    // ---- Helpers ----

    function _swapUsdsForPt(uint256 usdsIn, uint256 minPtOut) internal returns (uint256 netPtOut) {
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: Mainnet.USDS,
            netTokenIn: usdsIn,
            // SY-sUSDS accepts USDS, sUSDS (via deposit), DAI (via converter).
            tokenMintSy: Mainnet.USDS,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        IPendleRouter.LimitOrderData memory emptyLimit;

        (netPtOut, , ) = IPendleRouter(Mainnet.PENDLE_ROUTER_V4).swapExactTokenForPt(
            address(this), LOCAL_MARKET, minPtOut, approx, input, emptyLimit
        );
    }

    function _marketId() internal view returns (bytes32) {
        return keccak256(abi.encode(_market));
    }

    function _getCollateral() internal view returns (uint256) {
        return IMorpho(Mainnet.MORPHO).position(_marketId(), address(this)).collateral;
    }

    function _getBorrowedAssets() internal view returns (uint256) {
        IMorpho.Position memory p = IMorpho(Mainnet.MORPHO).position(_marketId(), address(this));
        if (p.borrowShares == 0) return 0;
        IMorpho.Market memory m = IMorpho(Mainnet.MORPHO).market(_marketId());
        if (m.totalBorrowShares == 0) return 0;
        return (uint256(p.borrowShares) * m.totalBorrowAssets) / m.totalBorrowShares;
    }

    /// @notice Off-test helper showing the alternative direct-supply path on
    ///         Spark for plain sUSDS (the non-PT version). This is the
    ///         continuation when PT-sUSDS matures and the strategy rolls into
    ///         the sUSDS Spark collateral loop.
    function sparkSusdsSavingsApy() external view returns (uint256) {
        return ISUSDS(Mainnet.SUSDS).ssr();
    }

    /// @notice Off-test helper showing the PSM bridge USDC <-> DAI used by
    ///         alternative funding paths when DAI/USDS converter is paused.
    function psmSellGem(uint256 usdcAmt) external {
        IERC20(Mainnet.USDC).approve(IDssPsm(Mainnet.DSS_PSM_USDC).gemJoin(), usdcAmt);
        IDssPsm(Mainnet.DSS_PSM_USDC).sellGem(address(this), usdcAmt);
    }
}
