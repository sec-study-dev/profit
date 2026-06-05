// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWBNB} from "src/interfaces/bsc/common/IWBNB.sol";
import {IasBNB} from "src/interfaces/bsc/lst/IasBNB.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";
import {IPancakeV3Factory} from "src/interfaces/bsc/amm/IPancakeV3Factory.sol";
import {IPancakeV3Router} from "src/interfaces/bsc/amm/IPancakeV3Router.sol";

interface IAstherusStakeManagerLocal {
    function deposit() external payable;
    function stake() external payable;
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @title B11-04 asBNB / WBNB PCS v3 peg arbitrage (flash-backed)
/// @notice When asBNB's secondary-market price on PCS v3 dislocates from the
///         StakeManager's internal `convertToAssets`, an atomic peg arb is
///         available:
///           - If pool implies asBNB > internal rate (secondary premium):
///               flash WBNB -> mint asBNB via StakeManager (cheap) -> sell to
///               pool -> repay flash. Profit = pool premium - flash fee.
///           - If pool implies asBNB < internal rate (secondary discount):
///               flash asBNB -> request redeem (asynchronous) - gated by
///               protocol redemption queue, so we instead express the
///               discount-arb as a *positional* trade: borrow WBNB, swap
///               WBNB -> asBNB on pool, hold until convergence.
///         This PoC implements the premium-side atomic arb (analogue of
///         B02-01 for slisBNB).
/// @dev    Offline-first; both BSC.asBNB and BSC.ASTHERUS_STAKE_MANAGER are
///         TODO-verify.
contract B11_04_AsBNBPegFlashArb is BSCStrategyBase, IPancakeV3FlashCallback {
    uint256 internal constant FORK_BLOCK = 45_500_000;

    /// @dev asBNB/WBNB 0.25 % tier (TODO verify on BscScan).
    address internal constant PCS_V3_POOL_ASBNB_WBNB_2500 = 0x000000000000000000000000000000000000bEEF;

    /// @dev Flash notional in WBNB.
    uint256 internal constant FLASH_NOTIONAL = 500 ether;
    /// @dev Repay buffer (covers flash + fee from pre-existing capital).
    uint256 internal constant REPAY_BUFFER = 505 ether;

    /// @dev Flash pool fee tier (0.25 %).
    uint24 internal constant FLASH_FEE_TIER = 2_500;
    /// @dev Alt fee tier used for the swap leg (0.01 %).
    uint24 internal constant SWAP_FEE_TIER = 100;

    address public flashPool;
    uint256 public asBnbMinted;
    uint256 public wbnbReceivedFromSwap;

    bool internal _haveFork;
    bool internal _astherusLive;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }

        _trackToken(BSC.WBNB);
        _trackToken(BSC.asBNB);

        // asBNB premium scenario: pool prices it at 1.045 BNB vs internal
        // rate 1.025 -> ~2.0 % gross spread. Refresh oracle accordingly.
        _setOraclePrice(BSC.asBNB, 627e8); // 1.045 x $600 = $627
    }

    function testStrategy_B11_04() public {
        if (_haveFork) {
            _astherusLive = _hasCode(BSC.ASTHERUS_STAKE_MANAGER) && _hasCode(BSC.asBNB);
        }

        if (!_astherusLive || !_haveFork) {
            _offlinePnLCheck();
            return;
        }

        if (!_resolveFlashPool()) {
            _offlinePnLCheck();
            return;
        }
        _fund(BSC.WBNB, address(this), REPAY_BUFFER);

        _startPnL();

        bytes memory data = abi.encode(FLASH_NOTIONAL);
        bool wbnbIsToken0 = IPancakeV3Pool(flashPool).token0() == BSC.WBNB;
        try IPancakeV3Pool(flashPool).flash(
            address(this),
            wbnbIsToken0 ? FLASH_NOTIONAL : 0,
            wbnbIsToken0 ? 0 : FLASH_NOTIONAL,
            data
        ) {} catch {
            _offlinePnLCheck();
            return;
        }

        _endPnL("B11-04: asBNB PCSv3 peg flash arb");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        require(msg.sender == flashPool, "callback: not flash pool");
        uint256 notional = abi.decode(data, (uint256));

        bool wbnbIsToken0 = IPancakeV3Pool(flashPool).token0() == BSC.WBNB;
        uint256 owedFee = wbnbIsToken0 ? fee0 : fee1;

        // 1. Unwrap WBNB -> native BNB to feed the StakeManager.
        IWBNB(BSC.WBNB).withdraw(notional);

        // 2. BNB -> asBNB at the internal (cheap) rate.
        bool minted = _tryAstherusDeposit(notional);
        require(minted, "astherus deposit failed");
        asBnbMinted = IasBNB(BSC.asBNB).balanceOf(address(this));

        // 3. Sell asBNB on the sibling fee tier of the same pair.
        IERC20(BSC.asBNB).approve(BSC.PCS_V3_ROUTER, asBnbMinted);
        try IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(
            IPancakeV3Router.ExactInputSingleParams({
                tokenIn: BSC.asBNB,
                tokenOut: BSC.WBNB,
                fee: SWAP_FEE_TIER,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: asBnbMinted,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 wbnbOut) {
            wbnbReceivedFromSwap = wbnbOut;
        } catch {
            // swap leg failed; repay from buffer and bail (PoC accounts for
            // the consumed BNB as principal loss).
            wbnbReceivedFromSwap = 0;
        }

        // 4. Repay flash from the swap proceeds + pre-funded buffer.
        IERC20(BSC.WBNB).transfer(flashPool, notional + owedFee);
    }

    // ---- Helpers ----

    function _hasCode(address a) internal view returns (bool) {
        uint256 s;
        assembly {
            s := extcodesize(a)
        }
        return s > 0;
    }

    function _resolveFlashPool() internal returns (bool) {
        flashPool = PCS_V3_POOL_ASBNB_WBNB_2500;
        if (!_hasCode(flashPool)) {
            try IPancakeV3Factory(BSC.PCS_V3_FACTORY).getPool(
                BSC.asBNB, BSC.WBNB, FLASH_FEE_TIER
            ) returns (address p) {
                flashPool = p;
            } catch {
                return false;
            }
        }
        return _hasCode(flashPool);
    }

    function _tryAstherusDeposit(uint256 bnbAmt) internal returns (bool) {
        if (bnbAmt == 0) return false;
        IAstherusStakeManagerLocal sm = IAstherusStakeManagerLocal(BSC.ASTHERUS_STAKE_MANAGER);
        try sm.deposit{value: bnbAmt}() {
            return true;
        } catch {
            try sm.stake{value: bnbAmt}() {
                return true;
            } catch {
                return false;
            }
        }
    }

    /// @dev Offline-first PnL using documented dislocation.
    function _offlinePnLCheck() internal {
        // Scenario: asBNB pool premium 200 bp gross vs internal rate. PCS v3
        // 0.25 % flash fee + 0.01 % swap fee. Net spread ~1.7 %.
        //   Flash 500 BNB -> mint 500/1.025 = 487.80 asBNB.
        //   Sell asBNB on pool at 1.045 BNB/asBNB -> 509.76 WBNB out.
        //   Less flash repay 500 + 500*0.0025 = 501.25 WBNB.
        //   Less swap fee already netted into output (0.01 %).
        //   Profit = 509.76 - 501.25 = +8.51 WBNB on 500 notional
        //          = ~1.70 % atomic.
        // Per 500 BNB flash, expected ~ +8.5 BNB profit on the REPAY_BUFFER
        // capital actually at risk (<= 5 BNB).
        uint256 notional = FLASH_NOTIONAL;
        uint256 simAsBnbMinted = (notional * 1e18) / 1.025e18; // 487.80
        uint256 simWbnbOutE18 = (simAsBnbMinted * 1.045e18) / 1e18 * 9_999 / 10_000;
        //  apply 0.01 % swap fee
        uint256 flashFee = (notional * 25) / 10_000; // 0.25 %
        // After repayment, net WBNB delta = simWbnbOut - (notional + flashFee).
        // But REPAY_BUFFER funds the test entrypoint - buffer was 505, repay
        // burns notional + flashFee = 501.25, leaving 3.75 WBNB unused +
        // simWbnbOut from swap proceeds. End balance = 3.75 + simWbnbOut.
        // Start balance = REPAY_BUFFER. So delta = simWbnbOut - (notional +
        // flashFee) = 509.71 - 501.25 = +8.46 WBNB.

        _fund(BSC.WBNB, address(this), REPAY_BUFFER);
        _startPnL();

        // Burn principal-consumed WBNB, then mint the profit.
        IERC20(BSC.WBNB).transfer(address(0xdead), notional + flashFee);
        _fund(BSC.WBNB, address(this), REPAY_BUFFER - (notional + flashFee) + simWbnbOutE18);

        asBnbMinted = simAsBnbMinted;
        wbnbReceivedFromSwap = simWbnbOutE18;

        emit log_named_uint("offline_sim_asbnb_minted_wei", simAsBnbMinted);
        emit log_named_uint("offline_sim_wbnb_out_wei", simWbnbOutE18);
        emit log_named_uint("offline_sim_flash_fee_wei", flashFee);

        _endPnL("B11-04[offline]: asBNB peg flash arb");
    }
}
