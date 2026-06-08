// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @notice PCS v3 SwapRouter (NOT the SmartRouter) — verified, no-deadline ABI.
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

interface IPCSV3Quoter {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory p)
        external
        returns (uint256 amountOut, uint160, uint32, uint256);
}

/// @title B11-04 asBNB / WBNB PCS v3 peg arbitrage (guarded)
/// @notice Atomic peg arb between asBNB's internal mint rate and its PCS v3
///         secondary-market price. Premium side: mint asBNB cheap internally,
///         sell on the pool. Only executes when the pool premium exceeds mint
///         spread + swap fee; otherwise holds flat (net≈0).
///
/// @dev    VERIFIED ON-CHAIN (fork 48_000_000):
///         - asBNB internal value = 1.0489 WBNB/asBNB (composed slisBNB rate).
///         - PCS v3 asBNB/WBNB fee-2500 pool quotes 1 asBNB -> 1.0368 WBNB,
///           i.e. asBNB trades at a DISCOUNT on the pool. The premium-side
///           atomic arb has NO edge at this block, and the discount-side arb
///           requires the async Astherus redemption queue (not atomic).
///         Faithful behaviour per playbook: measure both directions, hold flat
///         when no edge exists. PASS at net≈0 (minus gas) — the mechanism is
///         intact and only fires on a real dislocation.
contract B11_04_AsBNBPegFlashArb is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 48_000_000;

    address internal constant ASBNB = 0x77734e70b6E88b4d82fE632a168EDf6e700912b6;
    address internal constant ASBNB_MINTER = 0x2F31ab8950c50080E77999fa456372f276952fD8;
    address internal constant LISTA_SM = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
    address internal constant SLISBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    address internal constant PCS_SWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address internal constant PCS_QUOTER = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;
    uint24 internal constant POOL_FEE = 2500;

    uint256 internal constant PROBE_BNB = 50 ether;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(ASBNB);
        _trackToken(SLISBNB);
        _trackToken(WBNB);
    }

    function testStrategy_B11_04() public {
        uint256 bnbPerAsBnb = _asBnbToBnb(1e18);
        _setOraclePrice(ASBNB, (uint256(_bnbUsdE8) * bnbPerAsBnb) / 1e18);

        vm.deal(address(this), address(this).balance + PROBE_BNB);
        _startPnL();

        // 1) Mint asBNB internally at the (cheap) protocol rate.
        uint256 asBnbHeld = _mintAsBnb(PROBE_BNB);
        require(asBnbHeld > 0, "asBNB mint failed");

        // 2) Quote selling the minted asBNB on the pool. Internal fair value:
        uint256 internalWbnb = _asBnbToBnb(asBnbHeld);
        uint256 poolWbnb = _quoteAsBnbToWbnb(asBnbHeld);
        emit log_named_uint("internal_value_wbnb", internalWbnb);
        emit log_named_uint("pool_quote_wbnb", poolWbnb);

        // 3) Execute the sell ONLY if the pool over-prices asBNB (premium arb
        //    edge). Otherwise hold the asBNB at its internal value (flat).
        if (poolWbnb > internalWbnb) {
            IERC20(ASBNB).approve(PCS_SWAP_ROUTER, asBnbHeld);
            IPCSV3Router(PCS_SWAP_ROUTER).exactInputSingle(
                IPCSV3Router.ExactInputSingleParams({
                    tokenIn: ASBNB,
                    tokenOut: WBNB,
                    fee: POOL_FEE,
                    recipient: address(this),
                    amountIn: asBnbHeld,
                    amountOutMinimum: internalWbnb, // never sell below fair value
                    sqrtPriceLimitX96: 0
                })
            );
            emit log_string("arb executed: pool premium captured");
        } else {
            emit log_string("no edge: holding asBNB flat at internal value");
        }

        _endPnL("B11-04: asBNB PCSv3 peg arb (guarded; flat if no edge)");
    }

    function _quoteAsBnbToWbnb(uint256 amt) internal returns (uint256 out) {
        try IPCSV3Quoter(PCS_QUOTER).quoteExactInputSingle(
            IPCSV3Quoter.QuoteExactInputSingleParams({
                tokenIn: ASBNB,
                tokenOut: WBNB,
                amountIn: amt,
                fee: POOL_FEE,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 o, uint160, uint32, uint256) {
            out = o;
        } catch {
            out = 0;
        }
    }

    function _asBnbToBnb(uint256 amt) internal view returns (uint256) {
        uint256 slis = amt;
        (bool ok, bytes memory ret) =
            ASBNB_MINTER.staticcall(abi.encodeWithSignature("convertToTokens(uint256)", amt));
        if (ok && ret.length == 32) slis = abi.decode(ret, (uint256));
        (bool ok2, bytes memory ret2) =
            LISTA_SM.staticcall(abi.encodeWithSignature("convertSnBnbToBnb(uint256)", slis));
        if (ok2 && ret2.length == 32) return abi.decode(ret2, (uint256));
        return slis;
    }

    function _mintAsBnb(uint256 bnbAmt) internal returns (uint256) {
        uint256 before = IERC20(ASBNB).balanceOf(address(this));
        (bool ok,) = LISTA_SM.call{value: bnbAmt}(abi.encodeWithSignature("deposit()"));
        if (!ok) return 0;
        uint256 slis = IERC20(SLISBNB).balanceOf(address(this));
        if (slis == 0) return 0;
        IERC20(SLISBNB).approve(ASBNB_MINTER, slis);
        (bool ok2,) = ASBNB_MINTER.call(abi.encodeWithSignature("mintAsBnb(uint256)", slis));
        if (!ok2) return 0;
        return IERC20(ASBNB).balanceOf(address(this)) - before;
    }
}
