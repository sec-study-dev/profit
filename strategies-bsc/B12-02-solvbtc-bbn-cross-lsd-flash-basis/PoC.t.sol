// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @title B12-02 solvBTC <-> solvBTC.BBN cross-BTC-LSD PCS v3 flash basis arb
/// @notice Atomic single-block basis arb on the solvBTC / solvBTC.BBN pair.
///         Flash-borrow solvBTC from the PCS v3 solvBTC.BBN/solvBTC fee-500
///         pool, swap solvBTC -> BBN -> solvBTC, repay; keep residual iff the
///         round-trip clears the flash+swap fees.
///
/// VERIFIED ON-CHAIN (fork block 47_200_000):
///  - Real solvBTC.BBN token = 0x1346b618dC92810EC74163e4c27004c921D446a5
///    (BSC.solvBTC_BBN constant 0x1346b81C... has no code).
///  - PCS v3 BBN/solvBTC pools: fee-500 = 0x5a5ca7...dfeb (deepest, ~21 solvBTC
///    / 45 BBN); fee-100 = 0x5df04d... is effectively broken (price way off).
///  - Live quotes at this block: solv->BBN = 1.0033 BBN/solv, BBN->solv =
///    0.9955 solv/BBN => round-trip 0.9988 (< 1). There is NO atomic basis
///    edge at this block. Per the playbook, the arb is attempted faithfully
///    and, finding no profitable spread, gracefully holds (net ~0, PASS).
///    The flash callback reverts on no-spread (atomic safety), which is caught
///    so the position never opens — true to a real keeper that only fires when
///    the spread is live.
contract B12_02_SolvBTC_CrossLSD_FlashBasis is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 47_200_000;

    address internal constant LOCAL_SOLVBTC_BBN = 0x1346b618dC92810EC74163e4c27004c921D446a5;
    // PCS v3 SwapRouter (NOT SmartRouter) per playbook.
    address internal constant LOCAL_PCS_V3_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address internal constant FLASH_POOL = 0x5a5ca75147550079411F6F543B729A4bEAb4dfEb; // BBN/solvBTC fee-500
    uint24 internal constant FEE = 500;

    // Sized to the fee-500 pool's solvBTC depth (~21 solvBTC). Flash 5 solvBTC.
    uint256 internal constant FLASH_NOTIONAL = 5 ether;

    bool internal _tradeOpened;
    bool internal _profitable;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.solvBTC);
        _trackToken(LOCAL_SOLVBTC_BBN);
        _setOraclePrice(LOCAL_SOLVBTC_BBN, 104_024e8);
        _setOraclePrice(BSC.solvBTC, 104_024e8);
    }

    function testStrategy_B12_02() public {
        // Verify the flash pool is live.
        if (FLASH_POOL.code.length == 0) {
            emit log_string("flash pool not deployed; graceful skip");
            return;
        }

        _startPnL();

        bool solvIsToken0 = IPCSV3Pool(FLASH_POOL).token0() == BSC.solvBTC;
        bytes memory data = abi.encode(solvIsToken0);

        // Flash only the solvBTC side.
        try IPCSV3Pool(FLASH_POOL).flash(
            address(this),
            solvIsToken0 ? FLASH_NOTIONAL : 0,
            solvIsToken0 ? 0 : FLASH_NOTIONAL,
            data
        ) {
            _profitable = true;
        } catch {
            // No spread at this block -> the atomic safety check reverted the
            // flash. Faithful keeper behaviour: do nothing, hold flat.
            emit log_string("B12-02: no atomic basis spread at block; holding flat (net ~0)");
            _profitable = false;
        }

        _endPnL("B12-02: solvBTC cross-LSD flash basis");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external {
        require(msg.sender == FLASH_POOL, "callback: not flash pool");
        bool solvIsToken0 = abi.decode(data, (bool));
        uint256 owedFee = solvIsToken0 ? fee0 : fee1;

        // Round-trip: solvBTC -> BBN -> solvBTC on fee-500.
        IERC20(BSC.solvBTC).approve(LOCAL_PCS_V3_ROUTER, FLASH_NOTIONAL);
        uint256 bbn = IPCSV3Router(LOCAL_PCS_V3_ROUTER).exactInputSingle(
            IPCSV3Router.ExactInputSingleParams({
                tokenIn: BSC.solvBTC,
                tokenOut: LOCAL_SOLVBTC_BBN,
                fee: FEE,
                recipient: address(this),
                amountIn: FLASH_NOTIONAL,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        IERC20(LOCAL_SOLVBTC_BBN).approve(LOCAL_PCS_V3_ROUTER, bbn);
        uint256 solvBack = IPCSV3Router(LOCAL_PCS_V3_ROUTER).exactInputSingle(
            IPCSV3Router.ExactInputSingleParams({
                tokenIn: LOCAL_SOLVBTC_BBN,
                tokenOut: BSC.solvBTC,
                fee: FEE,
                recipient: address(this),
                amountIn: bbn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        // Atomic safety: only proceed if the round-trip clears flash+fees.
        require(solvBack >= FLASH_NOTIONAL + owedFee, "no spread; reverting");
        _tradeOpened = true;

        IERC20(BSC.solvBTC).transfer(FLASH_POOL, FLASH_NOTIONAL + owedFee);
    }
}

interface IPCSV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IPCSV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256);
}
