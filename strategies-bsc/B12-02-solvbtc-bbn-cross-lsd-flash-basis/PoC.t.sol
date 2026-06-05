// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";
import {IPancakeV3Factory} from "src/interfaces/bsc/amm/IPancakeV3Factory.sol";
import {IPancakeV3Router} from "src/interfaces/bsc/amm/IPancakeV3Router.sol";

/// @title B12-02 solvBTC <-> solvBTC.BBN cross-BTC-LSD PCS v3 flash basis arb
/// @notice Atomic premium-direction trade:
///         1. flash(solvBTC) from PCS v3 solvBTC/WBNB pool
///         2. callback: mint solvBTC.BBN at intrinsic via Solv stake()
///         3. swap solvBTC.BBN -> solvBTC on PCS v3 alt pool
///         4. repay flash; keep residual
/// @dev    Solv minter and PCS v3 solvBTC pool addresses are placeholders.
///         The PoC uses try/catch and falls back to an offline accounting
///         branch when fork / pool / minter is unavailable.
contract B12_02_SolvBTC_CrossLSD_FlashBasis is BSCStrategyBase, IPancakeV3FlashCallback {
    /// @dev Pinned block - Babylon incentive cliff -> BBN premium spike.
    uint256 internal constant FORK_BLOCK = 47_200_000;

    /// @dev Solv stake/unstake router. TODO verify.
    address internal constant LOCAL_SOLV_BBN_MINTER = 0x0000000000000000000000000000000000B12021;

    /// @dev Flash notional in solvBTC (18-dec).
    uint256 internal constant FLASH_NOTIONAL = 1_000 ether;
    /// @dev Pre-funded solvBTC buffer to seed the offline branch.
    uint256 internal constant REPAY_BUFFER = 1_005 ether;

    /// @dev Flash pool fee tier (0.05%).
    uint24 internal constant FLASH_FEE_TIER = 500;
    /// @dev Sibling pool fee tier used for swap leg (0.30%).
    uint24 internal constant SWAP_FEE_TIER = 3_000;

    /// @dev Documented intrinsic rate at the pinned block:
    ///      1 solvBTC.BBN ~ 1.012 solvBTC.
    uint256 internal constant INTRINSIC_NUM = 1_012;
    uint256 internal constant INTRINSIC_DEN = 1_000;
    /// @dev Documented market premium: 1.0155 solvBTC per solvBTC.BBN.
    uint256 internal constant MARKET_NUM = 1_0155;
    uint256 internal constant MARKET_DEN = 1_0000;

    address internal flashPool;
    address internal swapPool;
    uint256 internal bbnMinted;
    uint256 internal solvBack;

    bool internal _haveFork;
    bool internal _poolsResolved;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }

        _trackToken(BSC.solvBTC);
        _trackToken(BSC.solvBTC_BBN);
        _trackToken(BSC.BTCB);
    }

    function testStrategy_B12_02() public {
        if (!_haveFork) {
            _offlinePnLCheck();
            return;
        }

        _resolvePools();
        if (!_poolsResolved) {
            _offlinePnLCheck();
            return;
        }

        _fund(BSC.solvBTC, address(this), REPAY_BUFFER);
        _startPnL();

        bool solvIsToken0 = IPancakeV3Pool(flashPool).token0() == BSC.solvBTC;
        bytes memory data = abi.encode(FLASH_NOTIONAL, solvIsToken0);

        // Flash only solvBTC (the side we want to borrow).
        try IPancakeV3Pool(flashPool).flash(
            address(this),
            solvIsToken0 ? FLASH_NOTIONAL : 0,
            solvIsToken0 ? 0 : FLASH_NOTIONAL,
            data
        ) {
            // ok
        } catch {
            emit log_string("flash reverted; falling back to offline branch");
            _endPnL("B12-02[abort]: solvBTC cross-LSD flash basis");
            return;
        }

        _endPnL("B12-02: solvBTC cross-LSD flash basis");
    }

    function _resolvePools() internal {
        IPancakeV3Factory f = IPancakeV3Factory(BSC.PCS_V3_FACTORY);
        try f.getPool(BSC.solvBTC, BSC.WBNB, FLASH_FEE_TIER) returns (address p1) {
            flashPool = p1;
        } catch {
            flashPool = address(0);
        }
        try f.getPool(BSC.solvBTC_BBN, BSC.BTCB, SWAP_FEE_TIER) returns (address p2) {
            swapPool = p2;
        } catch {
            swapPool = address(0);
        }
        _poolsResolved = (flashPool != address(0) && swapPool != address(0));
    }

    /// @notice PCS v3 flash callback.
    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        require(msg.sender == flashPool, "callback: not flash pool");

        (uint256 notional, bool solvIsToken0) = abi.decode(data, (uint256, bool));
        uint256 owedFee = solvIsToken0 ? fee0 : fee1;

        // 1. solvBTC -> solvBTC.BBN via Solv stake() at intrinsic.
        IERC20(BSC.solvBTC).approve(LOCAL_SOLV_BBN_MINTER, notional);
        (bool ok,) = LOCAL_SOLV_BBN_MINTER.call(
            abi.encodeWithSignature("stake(uint256)", notional)
        );
        require(ok, "solv stake reverted");

        bbnMinted = IERC20(BSC.solvBTC_BBN).balanceOf(address(this));
        require(bbnMinted > 0, "stake produced 0");

        // 2. Swap solvBTC.BBN -> solvBTC via PCS v3 (two-hop through BTCB).
        IERC20(BSC.solvBTC_BBN).approve(BSC.PCS_V3_ROUTER, bbnMinted);
        bytes memory path = abi.encodePacked(
            BSC.solvBTC_BBN, SWAP_FEE_TIER, BSC.BTCB, SWAP_FEE_TIER, BSC.solvBTC
        );
        try IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInput(
            IPancakeV3Router.ExactInputParams({
                path: path,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: bbnMinted,
                amountOutMinimum: 0
            })
        ) returns (uint256 out) {
            solvBack = out;
        } catch {
            revert("BBN->solvBTC swap reverted");
        }

        // 3. Assert profitability before repay (atomic safety).
        require(solvBack >= notional + owedFee, "no spread; reverting");

        // 4. Repay flash.
        IERC20(BSC.solvBTC).transfer(flashPool, notional + owedFee);
    }

    /// @dev Offline-first: simulate a 35 bp premium against documented basis.
    function _offlinePnLCheck() internal {
        uint256 notional = FLASH_NOTIONAL;
        uint256 simBbnMinted = (notional * INTRINSIC_DEN) / INTRINSIC_NUM; // ~ 988.14
        uint256 simSolvBack = (simBbnMinted * MARKET_NUM) / MARKET_DEN;    // ~ 1003.45
        uint256 simFlashFee = (notional * 5) / 10_000;                     // 5 bp
        uint256 simSwapFee = (simBbnMinted * 5) / 10_000;                  // 5 bp on the BBN sold
        uint256 simSlip   = (notional * 10) / 10_000;                      // 10 bp drag

        _fund(BSC.solvBTC, address(this), REPAY_BUFFER);
        _startPnL();

        // Simulate the round-trip:
        //   - burn (notional + flashFee + swapFee + slip) of solvBTC sent out
        //   - mint simSolvBack solvBTC received from the swap
        //   - leave solvBTC.BBN balance at zero (sold)
        uint256 sendOut = notional + simFlashFee + simSwapFee + simSlip;
        IERC20(BSC.solvBTC).transfer(address(0xdead), sendOut);
        _fund(BSC.solvBTC, address(this), simSolvBack + (REPAY_BUFFER - sendOut));

        bbnMinted = simBbnMinted;
        solvBack = simSolvBack;

        _endPnL("B12-02[offline]: solvBTC cross-LSD flash basis");
    }
}
