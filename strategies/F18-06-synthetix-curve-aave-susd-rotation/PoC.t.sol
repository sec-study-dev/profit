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

/// @notice F18-06 — Tri-protocol sUSD-discount harvest → aDAI carry.
///
/// Mechanisms (3):
///   1. Curve sUSD/3pool (4-coin pool, coins[0]=sUSD)  — discount entry surface.
///   2. Synthetix V2x atomic exchange                  — oracle-priced sUSD exit leg.
///   3. Aave v3 DAI supply (aDAI)                      — perpetual carry on closed-arb residual.
contract F18_06_SynthetixCurveAaveSusdRotation is StrategyBase {
    /// @dev Pinned: mid-July 2024 — sUSD trades sub-peg; Synthetix atomic still live.
    uint256 constant FORK_BLOCK = 20_300_000;

    /// @dev Curve sUSD 4pool: sUSD(0) / DAI(1) / USDC(2) / USDT(3).
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

        // Sanity: Curve 4pool coin ordering.
        require(ICurveStableSwap(LOCAL_CURVE_SUSD_4POOL).coins(0) == Mainnet.SUSD, "F18-06: sUSD coin0");
        require(ICurveStableSwap(LOCAL_CURVE_SUSD_4POOL).coins(1) == Mainnet.DAI,  "F18-06: DAI coin1");
    }

    function testStrategy_F18_06() public {
        _fund(Mainnet.DAI, address(this), EQUITY_DAI);
        _startPnL();
        vm.txGasPrice(20 gwei);

        // ---- Mech 1: Curve DAI -> sUSD on the 4pool ----
        _approveMax(Mainnet.DAI, LOCAL_CURVE_SUSD_4POOL);
        uint256 susdOut;
        try ICurveStableSwap(LOCAL_CURVE_SUSD_4POOL).exchange(
            int128(1), int128(0), EQUITY_DAI, 0
        ) returns (uint256 o) {
            susdOut = o;
            console2.log("mech1_curve_susd_out:", susdOut);
        } catch Error(string memory reason) {
            console2.log("Curve DAI->sUSD reverted:", reason);
            _endPnL("F18-06: Curve leg reverted (no-op)");
            return;
        } catch {
            console2.log("Curve DAI->sUSD reverted (unknown)");
            _endPnL("F18-06: Curve leg reverted (no-op)");
            return;
        }

        // If we didn't get a favourable rate (no discount), skip Synthetix leg.
        // Heuristic: if we received less than 1.001x of input, the discount is
        // too tight and Synthetix fees will overwhelm.
        bool discountExists = susdOut > (EQUITY_DAI * 1001) / 1000;
        console2.log("discount_exists:", discountExists);

        // ---- Mech 2: Synthetix atomic exchange sUSD -> sETH ----
        address synthetix;
        try ISynthetixAddressResolver(LOCAL_SYNTHETIX_ADDRESS_RESOLVER).getAddress(bytes32("Synthetix")) returns (address a) {
            synthetix = a;
        } catch {}
        console2.log("synthetix_proxy:", synthetix);

        uint256 sethOut = 0;
        if (synthetix != address(0) && discountExists) {
            _approveMax(Mainnet.SUSD, synthetix);
            try ISynthetixV2x(synthetix).exchangeAtomically(
                CK_sUSD, susdOut, CK_sETH, TRACKING_CODE, 0
            ) returns (uint256 r) {
                sethOut = r;
                console2.log("mech2_synthetix_seth_out:", sethOut);
            } catch Error(string memory reason) {
                console2.log("Synthetix atomic reverted:", reason);
            } catch {
                console2.log("Synthetix atomic reverted (unknown)");
            }
        } else {
            console2.log("skipping Synthetix leg (no discount or resolver missing)");
        }

        // ---- Close the sETH leg back to ETH -> WETH -> DAI ----
        if (sethOut > 0) {
            _approveMax(Mainnet.SETH, LOCAL_CURVE_SETH_ETH);
            try ICurveStableSwap(LOCAL_CURVE_SETH_ETH).exchange(int128(1), int128(0), sethOut, 0) returns (uint256 ethOut) {
                console2.log("close_eth_from_seth:", ethOut);

                // ETH -> WETH (we received native ETH via Curve exchange).
                // (Note: this Curve pool returns ETH; the contract's payable
                // fallback collects it. Wrap and continue.)
                if (address(this).balance >= ethOut) {
                    IWETH(Mainnet.WETH).deposit{value: ethOut}();
                }
            } catch {
                console2.log("Curve sETH->ETH close failed");
            }
        }

        // Any residual sUSD that did NOT go through Synthetix swap back via
        // the Curve 4pool to DAI so we can supply it.
        uint256 susdResidual = IERC20(Mainnet.SUSD).balanceOf(address(this));
        if (susdResidual > 0) {
            _approveMax(Mainnet.SUSD, LOCAL_CURVE_SUSD_4POOL);
            try ICurveStableSwap(LOCAL_CURVE_SUSD_4POOL).exchange(int128(0), int128(1), susdResidual, 0) returns (uint256 daiBack) {
                console2.log("residual_susd_to_dai:", daiBack);
            } catch {
                console2.log("close residual sUSD->DAI failed");
            }
        }

        // ---- Mech 3: Aave v3 — supply DAI as aDAI for ongoing carry ----
        uint256 daiBal = IERC20(Mainnet.DAI).balanceOf(address(this));
        if (daiBal > 0) {
            IAavePool aave = IAavePool(Mainnet.AAVE_V3_POOL);
            _approveMax(Mainnet.DAI, Mainnet.AAVE_V3_POOL);
            try aave.supply(Mainnet.DAI, daiBal, address(this), 0) {
                console2.log("mech3_aave_dai_supplied:", daiBal);
            } catch Error(string memory reason) {
                console2.log("Aave DAI supply reverted:", reason);
            } catch {
                console2.log("Aave DAI supply reverted (unknown)");
            }
        }

        // Account snapshot.
        IAavePool aaveR = IAavePool(Mainnet.AAVE_V3_POOL);
        (uint256 tCol, uint256 tDebt, , , , uint256 hf) = aaveR.getUserAccountData(address(this));
        console2.log("aave_collateral_base:", tCol);
        console2.log("aave_debt_base:", tDebt);
        console2.log("aave_health_factor:", hf);

        _endPnL("F18-06: synthetix-curve-aave-susd-rotation");
    }

    function _approveMax(address token, address spender) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max));
        require(ok, "approve fail");
    }
}
