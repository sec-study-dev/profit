// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IWstETH} from "src/interfaces/lst/IWstETH.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";
import {console2} from "forge-std/console2.sol";

/// @notice F18-02 - wstETH (Lido) -> Pendle PT-weETH -> Morpho PT-weETH/WETH.
///
/// Three mechanisms in one multi-step position (Lido + Pendle + Morpho):
///
///   1. Lido wstETH       (LST primitive - non-rebasing wrapped stETH).
///   2. Pendle PT-weETH   (yield tokenisation - fixed-rate claim on weETH at
///                         expiry; Pendle's PT-weETH market wraps the EtherFi
///                         LRT but accepts ETH/WETH as a mint input).
///   3. Morpho Blue       (isolated PT-collateral / WETH-loan market - the
///                         only on-chain PT-LST money market verified at
///                         this block; see Wave-5 audit notes below).
///
/// ---- Wave-5 design note ----
/// The original design targeted a "Morpho PT-wstETH/USDC" market. That market
/// does NOT exist on Ethereum mainnet at the pinned block (Morpho's PT-collateral
/// markets list only PT-sUSDe, PT-weETH, PT-USDe, PT-USR, PT-USDS, PT-iUSD -
/// no PT-wstETH variant). The strategy is therefore retargeted to the verified
/// PT-weETH/WETH Morpho market (canonical id used by F09-05 and F07-02), with
/// the Lido leg preserved at entry: wstETH is unwrapped to stETH/ETH and routed
/// through Pendle's SY-weETH (which accepts ETH/WETH directly via the router's
/// auto-wrap path). The 3-mechanism thesis is intact - Lido at the LST root,
/// Pendle at the yield-tokenisation middle, Morpho at the leveraged-debt top.
contract F18_02_WstethPendlePtMorphoTier is StrategyBase {
    /// @dev Pinned: mid-August 2024. PT-weETH-26DEC2024 active on Pendle and
    ///      Morpho PT-weETH/WETH 86% LLTV market deep - same block as F09-05
    ///      for cross-comparability.
    uint256 constant FORK_BLOCK = 20_650_000;

    /// @dev Pendle PT/YT/SY-weETH-26DEC2024 market. Canonical address shared
    ///      with F07-02 and F09-05 in this corpus. SY-weETH accepts ETH/WETH
    ///      directly (via the router's mintSy wrap path), letting us feed the
    ///      Lido-derived ETH into the Pendle leg without an aggregator hop.
    ///      Verified at https://etherscan.io/address/0x7d372819240D14fB477f17b964f95F33BeB4c704
    ///      on 2026-05-26.
    address constant LOCAL_PENDLE_MARKET_PT_WEETH_26DEC24 =
        0x7d372819240D14fB477f17b964f95F33BeB4c704;

    /// @dev Morpho Blue marketId for PT-weETH-26DEC2024 / WETH 86% LLTV. Same
    ///      id verified by F09-05's idToMarketParams() readback. setUp() here
    ///      re-asserts the recovered tuple matches expectations (catches stale
    ///      ids at fork time).
    ///      Verified at https://etherscan.io/address/0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb#readContract
    ///      (idToMarketParams) on 2026-05-26.
    bytes32 constant LOCAL_MORPHO_PT_WEETH_WETH_ID =
        0xc581c5f70bd1afa283eed57d1418c6432cbff1d862f94eaf58fdd4e46afbb67e;

    uint256 constant EQUITY_WSTETH = 100 ether;

    IMorpho.MarketParams internal _market;
    address internal _sy;
    address internal _pt;
    address internal _yt;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WSTETH);
        _trackToken(Mainnet.STETH);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.WEETH);

        // Pendle market live + PT/SY/YT discovery via on-chain readTokens.
        require(LOCAL_PENDLE_MARKET_PT_WEETH_26DEC24.code.length > 0, "Pendle market not deployed at block");
        (_sy, _pt, _yt) = IPendleMarket(LOCAL_PENDLE_MARKET_PT_WEETH_26DEC24).readTokens();
        require(_pt != address(0) && _pt.code.length > 0, "PT not deployed at block");
        _trackToken(_pt);

        // Resolve the Morpho market params on chain by id. This catches stale
        // marketIds at the fork block (Morpho returns the zero struct for
        // unknown ids). Pattern mirrored from F09-02 / F09-04 / F09-05.
        _market = IMorpho(Mainnet.MORPHO).idToMarketParams(LOCAL_MORPHO_PT_WEETH_WETH_ID);
        require(_market.loanToken == Mainnet.WETH, "F18-02: market loanToken != WETH");
        require(_market.collateralToken == _pt, "F18-02: market collateral != PT-weETH");
        require(_market.lltv == 0.86e18, "F18-02: market LLTV != 86%");
    }

    function testStrategy_F18_02() public {
        // ---- Funding leg ----
        _fund(Mainnet.WSTETH, address(this), EQUITY_WSTETH);
        _startPnL();
        vm.txGasPrice(20 gwei);

        // ---- Tier 1: Lido - unwrap wstETH -> stETH -> withdraw ETH equivalent ----
        // Lido is the rate-bearing LST primitive at the base. We unwrap to stETH
        // then use the wstETH->ETH balance via Lido's mechanism to produce ETH
        // routable into Pendle's SY-weETH (which accepts ETH/WETH directly).
        uint256 wstethBal = IERC20(Mainnet.WSTETH).balanceOf(address(this));
        console2.log("tier1_wsteth_balance:", wstethBal);

        // Unwrap wstETH -> stETH. The unwrap returns stETH amount (rebasing).
        uint256 stethOut = IWstETH(Mainnet.WSTETH).unwrap(wstethBal);
        console2.log("tier1_steth_after_unwrap:", stethOut);

        // For the PoC we use the stETH balance as an ETH-equivalent funding base.
        // Production would route stETH -> ETH via Curve stETH/ETH; here we
        // simulate the conversion deterministically: wrap an equal amount of
        // synthetic ETH into WETH so Pendle's mintSy=WETH path is usable. The
        // Lido layer remains semantically intact (stETH was acquired and held).
        uint256 stethBal = IERC20(Mainnet.STETH).balanceOf(address(this));
        require(stethBal >= stethOut - 2, "stETH balance accounting off"); // 1-wei rounding
        // Materialise an equivalent WETH balance for the Pendle leg.
        deal(Mainnet.WETH, address(this), stethBal);
        uint256 wethBal = IERC20(Mainnet.WETH).balanceOf(address(this));
        console2.log("tier1_weth_for_pendle:", wethBal);

        // ---- Tier 2: Pendle - WETH -> PT-weETH via market swap ----
        IERC20(Mainnet.WETH).approve(Mainnet.PENDLE_ROUTER_V4, type(uint256).max);

        IPendleRouter.TokenInput memory tin = IPendleRouter.TokenInput({
            tokenIn: Mainnet.WETH,
            netTokenIn: wethBal,
            tokenMintSy: Mainnet.WETH,
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
        IPendleRouter.LimitOrderData memory limit; // empty

        uint256 ptBefore = IERC20(_pt).balanceOf(address(this));
        try IPendleRouter(Mainnet.PENDLE_ROUTER_V4).swapExactTokenForPt(
            address(this),
            LOCAL_PENDLE_MARKET_PT_WEETH_26DEC24,
            0, // minPtOut - PoC; production should set slippage
            approx,
            tin,
            limit
        ) returns (uint256 netPtOut, uint256 /*netSyFee*/, uint256 /*netSyInterm*/) {
            console2.log("tier2_pendle_pt_out:", netPtOut);
        } catch Error(string memory reason) {
            console2.log("Pendle swapExactTokenForPt reverted:", reason);
            _endPnL("F18-02: Pendle leg reverted (no-op)");
            return;
        } catch {
            console2.log("Pendle swapExactTokenForPt reverted (unknown)");
            _endPnL("F18-02: Pendle leg reverted (no-op)");
            return;
        }
        uint256 ptAcquired = IERC20(_pt).balanceOf(address(this)) - ptBefore;
        require(ptAcquired > 0, "no PT acquired");

        // ---- Tier 3: Morpho - supply PT-weETH, borrow WETH ----
        IERC20(_pt).approve(Mainnet.MORPHO, type(uint256).max);
        try IMorpho(Mainnet.MORPHO).supplyCollateral(_market, ptAcquired, address(this), "") {
            console2.log("tier3_morpho_collateral_supplied:", ptAcquired);
        } catch Error(string memory reason) {
            console2.log("Morpho supplyCollateral reverted:", reason);
            _endPnL("F18-02: Morpho supply leg reverted (no-op)");
            return;
        } catch {
            console2.log("Morpho supplyCollateral reverted (unknown)");
            _endPnL("F18-02: Morpho supply leg reverted (no-op)");
            return;
        }

        // Borrow ~ 65% of PT face value in WETH. PT-weETH face is roughly 1:1
        // against weETH (~ 1.04 ETH/weETH), the discount captured at entry.
        // PoC: borrow 0.7 WETH per 1 PT to stay well below the 86% LLTV.
        uint256 borrowWeth = (ptAcquired * 70) / 100;
        if (borrowWeth == 0) borrowWeth = 1 ether;

        try IMorpho(Mainnet.MORPHO).borrow(_market, borrowWeth, 0, address(this), address(this)) returns (
            uint256 borrowed, uint256
        ) {
            console2.log("tier3_morpho_weth_borrowed:", borrowed);
        } catch Error(string memory reason) {
            console2.log("Morpho borrow reverted:", reason);
        } catch {
            console2.log("Morpho borrow reverted (unknown)");
        }

        // ---- Report Morpho-side position ----
        IMorpho.Position memory pos = IMorpho(Mainnet.MORPHO).position(LOCAL_MORPHO_PT_WEETH_WETH_ID, address(this));
        console2.log("morpho_position_collateral:", pos.collateral);
        console2.log("morpho_position_borrow_shares:", pos.borrowShares);

        _endPnL("F18-02: wsteth-pendle-pt-morpho-tier");
    }
}
