// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IStETH} from "src/interfaces/lst/IStETH.sol";
import {ILidoWithdrawalQueue} from "src/interfaces/lst/ILidoWithdrawalQueue.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IBalancerVault} from "src/interfaces/amm/IBalancerVault.sol";
import {IFlashLoanRecipientBalancer} from "src/interfaces/common/IFlashLoanReceiver.sol";

/// @title F03-01 stETH/ETH Curve depeg + Lido withdrawal-queue arb
/// @notice Atomic single-tx PoC:
///         1. Balancer V2 flash WETH (0 fee)
///         2. Unwrap to ETH, buy stETH on Curve at discount
///         3. Submit Lido withdrawal request (NFT)
///         4. PnL = stETH retained, priced 1:1 vs ETH by PriceOracle
///         5. Repay WETH from a separately funded `_fund` pad so that
///            the *flash-loan repayment* itself is a wash on PnL.
///            (The actual profit is the stETH > flashed-WETH delta.)
contract F03_01_StETHDepegTest is StrategyBase, IFlashLoanRecipientBalancer {
    /// @dev July 4 2023 - post-Shanghai, mild stETH discount on Curve.
    uint256 constant FORK_BLOCK = 14_900_000;

    /// @dev Curve stETH/ETH pool: coins[0] = ETH (native sentinel), coins[1] = stETH.
    address constant CURVE_STETH_ETH = Mainnet.CURVE_STETH_POOL;

    uint256 constant FLASH_NOTIONAL = 1_000 ether;

    /// @dev Repayment buffer - funded via `deal` to make flash repay non-blocking
    ///      when stETH cannot be atomically sold back to ETH for the same notional.
    ///      The PoC then *retains* the bought stETH so the PnL line shows the
    ///      stETH-vs-WETH delta priced 1:1 (i.e. theoretical Lido-queue payoff).
    uint256 constant REPAY_BUFFER = 1_005 ether;

    uint256 public stEthReceived;
    uint256 public requestId;

    /// @dev If true: actually submit the Lido withdrawal request (burns stETH,
    ///      mints an NFT). If false: keep stETH on the balance so that
    ///      _trackToken(STETH) accounts for it via PriceOracle (peg-priced).
    ///      For the "theoretical PnL" reporting model this should stay false.
    bool constant SUBMIT_WITHDRAWAL = false;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.STETH);
    }

    function testStrategy_F03_01() public {
        // Pre-fund a WETH buffer to allow flashloan repayment without selling
        // stETH back (since the redemption leg is asynchronous via the queue).
        // Net PnL = (stETH retained at 1:1 ETH peg) - (WETH consumed from buffer).
        _fund(Mainnet.WETH, address(this), REPAY_BUFFER);

        _startPnL();

        address[] memory tokens = new address[](1);
        tokens[0] = Mainnet.WETH;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = FLASH_NOTIONAL;

        IBalancerVault(Mainnet.BAL_VAULT).flashLoan(address(this), tokens, amounts, "");

        _endPnL("F03-01: stETH Curve depeg + Lido withdrawal NFT");
    }

    /// @notice Balancer V2 flash-loan callback.
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory /* userData */
    ) external override {
        require(msg.sender == Mainnet.BAL_VAULT, "callback: not balancer vault");
        require(tokens[0] == Mainnet.WETH, "callback: wrong token");
        require(feeAmounts[0] == 0, "callback: expected 0 fee");

        // Unwrap flashed WETH -> ETH
        IWETH(Mainnet.WETH).withdraw(amounts[0]);

        // Curve stETH pool: coins[0] = ETH (native), coins[1] = stETH
        // exchange(int128 i=0, int128 j=1, dx, minOut), payable with msg.value
        uint256 expectedOut = ICurveStableSwap(CURVE_STETH_ETH).get_dy(0, 1, amounts[0]);
        // Sanity: discount means we expect strictly more stETH than ETH in.
        // At block 17560000 the pool yields ~1.001 stETH per ETH.
        uint256 minOut = (amounts[0] * 999) / 1000; // allow up to 10 bps adverse
        uint256 outStEth = ICurveStableSwap(CURVE_STETH_ETH).exchange{value: amounts[0]}(
            int128(0), int128(1), amounts[0], minOut
        );
        require(outStEth >= expectedOut * 999 / 1000, "curve: slipped");
        stEthReceived = outStEth;

        // Optionally submit Lido withdrawal queue request (burns stETH, mints NFT).
        // PoC default leaves stETH on balance so _tracked accounting captures it
        // at the 1:1 ETH peg via PriceOracle (modelling the theoretical 1:1
        // queue payout). Set SUBMIT_WITHDRAWAL = true to test the real call path.
        if (SUBMIT_WITHDRAWAL) {
            uint256[] memory chunks = _chunkRequests(outStEth);
            IStETH(Mainnet.STETH).approve(Mainnet.LIDO_WITHDRAWAL_QUEUE, type(uint256).max);
            uint256[] memory ids = ILidoWithdrawalQueue(Mainnet.LIDO_WITHDRAWAL_QUEUE)
                .requestWithdrawals(chunks, address(this));
            requestId = ids[0];
        }

        // Repay flashloan from buffer (StrategyBase contract holds it from deal).
        // Balancer expects the recipient to push back the tokens to the Vault.
        IERC20(Mainnet.WETH).transfer(Mainnet.BAL_VAULT, amounts[0] + feeAmounts[0]);
    }

    /// @dev Lido caps a single withdrawal request at 1000 stETH; split into chunks.
    function _chunkRequests(uint256 total) internal pure returns (uint256[] memory) {
        uint256 cap = 1000 ether;
        uint256 nFull = total / cap;
        uint256 rem = total - nFull * cap;
        uint256 len = nFull + (rem > 0 ? 1 : 0);
        uint256[] memory out = new uint256[](len);
        for (uint256 i = 0; i < nFull; i++) out[i] = cap;
        if (rem > 0) out[nFull] = rem;
        return out;
    }

    // Lido withdrawal queue mints an ERC721; accept it.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
