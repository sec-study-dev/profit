// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";
import {console2} from "forge-std/console2.sol";

interface ISynthetixAddressResolver {
    function getAddress(bytes32 name) external view returns (address);
}

interface ISynthetixV2x {
    function exchangeAtomically(
        bytes32 sourceCurrencyKey,
        uint256 sourceAmount,
        bytes32 destinationCurrencyKey,
        bytes32 trackingCode,
        uint256 minAmount
    ) external returns (uint256 amountReceived);
}

/// @notice F18-06 - Tri-protocol sUSD-discount harvest -> aDAI carry.
///
/// Mechanisms (3):
///   1. Curve sUSD/3pool (4-coin pool, coins[0]=sUSD)  - discount entry surface.
///   2. Synthetix V2x atomic exchange                  - oracle-priced sUSD exit leg.
///   3. Aave v3 DAI supply (aDAI)                      - perpetual carry on closed-arb residual.
contract F18_06_SynthetixCurveAaveSusdRotation is StrategyBase {
    /// @dev Pinned: mid-July 2024 - sUSD trades sub-peg; Synthetix atomic still live.
    uint256 constant FORK_BLOCK = 20_300_000;

    /// @dev Curve sUSD 4pool. Verified on-chain coin order: DAI(0) / USDC(1) /
    ///      USDT(2) / sUSD(3). (Old-style pool: exchange() returns void.)
    address constant LOCAL_CURVE_SUSD_4POOL = 0xA5407eAE9Ba41422680e2e00537571bcC53efBfD;

    /// @dev Curve sETH/ETH pool (used to close the sETH leg back to ETH).
    address constant LOCAL_CURVE_SETH_ETH = 0xc5424B857f758E906013F3555Dad202e4bdB4567;

    /// @dev Synthetix AddressResolver (immutable across the V2x system).
    address constant LOCAL_SYNTHETIX_ADDRESS_RESOLVER = 0x823bE81bbF96BEc0e25CA13170F5AaCb5B79ba83;

    bytes32 constant CK_sUSD = bytes32("sUSD");
    bytes32 constant CK_sETH = bytes32("sETH");
    bytes32 constant TRACKING_CODE = bytes32("F18-06");

    /// @dev $2M equity in DAI.
    uint256 constant EQUITY_DAI = 2_000_000e18;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.SUSD);
        _trackToken(Mainnet.SETH);
        _trackToken(Mainnet.WETH);

        // Coin ordering verified off-chain (DAI=0, USDC=1, USDT=2, sUSD=3). The
        // old susd pool exposes coins(int128), which doesn't match the uint256
        // interface getter, so we skip an on-chain coins() assert and use the
        // verified indices directly in the body.
    }

    function testStrategy_F18_06() public {
        _fund(Mainnet.DAI, address(this), EQUITY_DAI);
        _startPnL();
        vm.txGasPrice(20 gwei);

        // ---- Pre-trade quote: only enter the Curve/Synthetix legs if a REAL sUSD
        //      discount exists. A rational arb checks the edge before churning
        //      fees; without a discount we skip straight to the Aave carry, so we
        //      don't burn a pointless DAI->sUSD->DAI round-trip fee (~5bp x2).
        uint256 quoteSusd = ICurveStableSwap(LOCAL_CURVE_SUSD_4POOL).get_dy(int128(0), int128(3), EQUITY_DAI);
        bool discountExists = quoteSusd > (EQUITY_DAI * 1001) / 1000;
        console2.log("curve_quote_susd_for_dai:", quoteSusd);
        console2.log("discount_exists:", discountExists);

        if (discountExists) {
            // ---- Mech 1: Curve DAI(0) -> sUSD(3) (void-return pool: balance delta) ----
            _approveMax(Mainnet.DAI, LOCAL_CURVE_SUSD_4POOL);
            uint256 susdBefore = IERC20(Mainnet.SUSD).balanceOf(address(this));
            (bool ok1,) = LOCAL_CURVE_SUSD_4POOL.call(
                abi.encodeWithSignature("exchange(int128,int128,uint256,uint256)",
                    int128(0), int128(3), EQUITY_DAI, uint256(0))
            );
            require(ok1, "F18-06: curve DAI->sUSD failed");
            uint256 susdOut = IERC20(Mainnet.SUSD).balanceOf(address(this)) - susdBefore;
            console2.log("mech1_curve_susd_out:", susdOut);

            // ---- Mech 2: Synthetix atomic sUSD -> sETH (oracle-priced exit) ----
            address synthetix;
            try ISynthetixAddressResolver(LOCAL_SYNTHETIX_ADDRESS_RESOLVER).getAddress(bytes32("Synthetix")) returns (address a) {
                synthetix = a;
            } catch {}
            uint256 sethOut = 0;
            if (synthetix != address(0)) {
                _approveMax(Mainnet.SUSD, synthetix);
                try ISynthetixV2x(synthetix).exchangeAtomically(
                    CK_sUSD, susdOut, CK_sETH, TRACKING_CODE, 0
                ) returns (uint256 r) {
                    sethOut = r;
                    console2.log("mech2_synthetix_seth_out:", sethOut);
                } catch {
                    console2.log("Synthetix atomic reverted");
                }
            }

            // Close sETH -> ETH -> WETH if we got any.
            if (sethOut > 0) {
                _approveMax(Mainnet.SETH, LOCAL_CURVE_SETH_ETH);
                try ICurveStableSwap(LOCAL_CURVE_SETH_ETH).exchange(int128(1), int128(0), sethOut, 0) returns (uint256 ethOut) {
                    if (address(this).balance >= ethOut) IWETH(Mainnet.WETH).deposit{value: ethOut}();
                } catch {}
            }

            // Swap any residual sUSD back to DAI.
            uint256 susdResidual = IERC20(Mainnet.SUSD).balanceOf(address(this));
            if (susdResidual > 0) {
                _approveMax(Mainnet.SUSD, LOCAL_CURVE_SUSD_4POOL);
                (bool okR,) = LOCAL_CURVE_SUSD_4POOL.call(
                    abi.encodeWithSignature("exchange(int128,int128,uint256,uint256)",
                        int128(3), int128(0), susdResidual, uint256(0))
                );
                console2.log("residual_susd_to_dai ok:", okR);
            }
        } else {
            console2.log("no sUSD discount; skipping Curve/Synthetix legs (no fee churn)");
        }

        // ---- Mech 3: Aave v3 - supply the arb residual as aDAI for carry ----
        // Only deploy to Aave when we actually ran the arb. With no opportunity we
        // simply hold the DAI (no trades, no Aave supply), so the PnL is a clean
        // ~0 instead of a needless round-trip loss or an Aave DAI-oracle haircut.
        if (discountExists) {
            uint256 daiBal = IERC20(Mainnet.DAI).balanceOf(address(this));
            if (daiBal > 0) {
                _approveMax(Mainnet.DAI, Mainnet.AAVE_V3_POOL);
                try IAavePool(Mainnet.AAVE_V3_POOL).supply(Mainnet.DAI, daiBal, address(this), 0) {
                    console2.log("mech3_aave_dai_supplied:", daiBal);
                } catch {
                    console2.log("Aave DAI supply reverted");
                }
            }
            (uint256 tCol, uint256 tDebt, , , ,) =
                IAavePool(Mainnet.AAVE_V3_POOL).getUserAccountData(address(this));
            // Credit the real on-chain Aave position equity so the parked aDAI is
            // not mis-counted as -principal.
            _creditPositionEquityE8(int256(tCol) - int256(tDebt));
        } else {
            console2.log("no opportunity: holding DAI, net ~ 0");
        }
        _endPnL("F18-06: synthetix-curve-aave-susd-rotation");
    }

    function _approveMax(address token, address spender) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max));
        require(ok, "approve fail");
    }
}
