// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

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

/// @title B11-09 asBNB dynamic-AMM peg arb (Wombat -> PCS v3 fallback)
/// @notice Companion to B11-04: peg arb between asBNB's internal mint rate and
///         a dynamic-weight AMM. Premium side: mint asBNB internally, sell on
///         the AMM at premium. Only fires on a real dislocation.
///
/// @dev    VERIFIED ON-CHAIN (fork 48_000_000):
///         - NO Wombat pool lists asBNB (checked main pool + ankrBNB sidecar
///           `addressOfAsset(asBNB)` -> revert/no-code). The intended Wombat
///           venue is infeasible, so we gracefully route the SAME dynamic-AMM
///           peg-arb discriminator through the live PCS v3 asBNB/WBNB pool.
///         - That pool is SHALLOW (~6.8 asBNB / ~4.6 WBNB in the 2500 tier)
///           and prices asBNB at a DISCOUNT (1 asBNB -> 1.0368 WBNB vs internal
///           1.0489). No premium-side atomic edge; discount side needs the
///           async redeem queue. Faithful behaviour: measure, hold flat.
contract B11_09_AsBNBWombatDynamicPegArb is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 48_000_000;

    address internal constant ASBNB = 0x77734e70b6E88b4d82fE632a168EDf6e700912b6;
    address internal constant ASBNB_MINTER = 0x2F31ab8950c50080E77999fa456372f276952fD8;
    address internal constant LISTA_SM = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
    address internal constant SLISBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    address internal constant WOMBAT_MAIN_POOL = 0x312Bc7eAAF93f1C60Dc5AfC115FcCDE161055fb0;
    address internal constant PCS_SWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address internal constant PCS_QUOTER = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;
    uint24 internal constant POOL_FEE = 2500;

    // Small probe — the asBNB/WBNB pool is shallow, so any larger size eats
    // slippage. The arb is sized to the liquidity it can faithfully trade.
    uint256 internal constant PROBE_BNB = 2 ether;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(ASBNB);
        _trackToken(SLISBNB);
        _trackToken(WBNB);
    }

    function testStrategy_B11_09() public {
        uint256 bnbPerAsBnb = _asBnbToBnb(1e18);
        _setOraclePrice(ASBNB, (uint256(_bnbUsdE8) * bnbPerAsBnb) / 1e18);

        // Wombat venue probe — no asBNB asset exists -> graceful fallback to PCS.
        bool wombatHasAsBnb = _wombatHasAsBnb();
        emit log_named_uint("wombat_lists_asbnb", wombatHasAsBnb ? 1 : 0);

        vm.deal(address(this), address(this).balance + PROBE_BNB);
        _startPnL();

        // 1) Mint asBNB internally (cheap leg).
        uint256 asBnbHeld = _mintAsBnb(PROBE_BNB);
        require(asBnbHeld > 0, "asBNB mint failed");

        // 2) Quote the dynamic-AMM (PCS v3) for the sell leg.
        uint256 internalWbnb = _asBnbToBnb(asBnbHeld);
        uint256 poolWbnb = _quote(ASBNB, WBNB, asBnbHeld);
        emit log_named_uint("internal_value_wbnb", internalWbnb);
        emit log_named_uint("pool_quote_wbnb", poolWbnb);

        // 3) Execute only on a genuine premium; else hold flat at fair value.
        if (poolWbnb > internalWbnb) {
            IERC20(ASBNB).approve(PCS_SWAP_ROUTER, asBnbHeld);
            IPCSV3Router(PCS_SWAP_ROUTER).exactInputSingle(
                IPCSV3Router.ExactInputSingleParams({
                    tokenIn: ASBNB,
                    tokenOut: WBNB,
                    fee: POOL_FEE,
                    recipient: address(this),
                    amountIn: asBnbHeld,
                    amountOutMinimum: internalWbnb,
                    sqrtPriceLimitX96: 0
                })
            );
            emit log_string("arb executed: AMM premium captured");
        } else {
            emit log_string("no edge: holding asBNB flat at internal value");
        }

        _endPnL("B11-09: asBNB dynamic-AMM peg arb (guarded; flat if no edge)");
    }

    function _wombatHasAsBnb() internal view returns (bool) {
        (bool ok, bytes memory ret) =
            WOMBAT_MAIN_POOL.staticcall(abi.encodeWithSignature("addressOfAsset(address)", ASBNB));
        if (!ok || ret.length != 32) return false;
        return abi.decode(ret, (address)) != address(0);
    }

    function _quote(address tin, address tout, uint256 amt) internal returns (uint256 out) {
        try IPCSV3Quoter(PCS_QUOTER).quoteExactInputSingle(
            IPCSV3Quoter.QuoteExactInputSingleParams({
                tokenIn: tin,
                tokenOut: tout,
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
