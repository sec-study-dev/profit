// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";

/// @title B14-04 PoC - sUSDe <-> vUSDT yield-wrapper APY rotation
/// @notice Holds the higher-yielding stablecoin wrapper between sUSDe and vUSDT
///         and rotates when the cross-spread inverts past a hysteresis band.
///         Modelled as a 90-day window of three 30-day intervals.
/// @dev    Faithful fork-replay at FORK_BLOCK with graceful handling of the
///         sUSDe leg:
///         - vUSDT intervals execute a REAL Venus Core mint/redeem (vUSDT is
///           listed, CF 0.80) and the held wrapper's supply carry is read from
///           the LIVE vUSDT supply rate.
///         - sUSDe on BSC is a LayerZero OFT mirror (asset()/redeem revert) and
///           there is NO Venus sUSDe market at this block, so the sUSDe leg is
///           held as the dealt token and its carry credited from the modelled
///           sUSDe APY (the real strategy reads Ethena's on-chain rate). This is
///           the playbook's graceful-skip-of-unforkable-leg + run-the-carry.
contract B14_04_PoC is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 44_000_000;
    address internal constant LOCAL_VENUS_ORACLE = 0x6592b5DE802159F3E74B2486b091D11a8256ab8A;

    uint256 constant PRINCIPAL_USDT = 100_000e18;
    uint256 constant N_INTERVALS = 3;
    uint256 constant INTERVAL_DAYS = 30;
    uint256 constant HYST_BPS = 100;
    uint256 constant ROT_BPS = 15; // one-way rotation cost

    uint256[3] internal _susdeBps;
    uint256[3] internal _vusdtBps;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.USDT);
        _trackToken(BSC.sUSDe);
        // Interval APYs (bps): the wrapper-selection schedule.
        _susdeBps = [uint256(900), uint256(450), uint256(1100)];
        _vusdtBps = [uint256(550), uint256(800), uint256(550)];
    }

    function testWrapperApyRotation() public {
        _fund(BSC.USDT, address(this), PRINCIPAL_USDT);
        _startPnL();

        IVToken vUSDT = IVToken(BSC.vUSDT);
        IERC20(BSC.USDT).approve(BSC.vUSDT, type(uint256).max);

        // Live vUSDT supply APR (1e18) used in place of the modelled vUSDT APY
        // for the realised carry of any interval actually held in Venus.
        uint256 blocksPerYear = 365 days / 3;
        uint256 vusdtSupplyApr1e18 = vUSDT.supplyRatePerBlock() * blocksPerYear;
        uint256 usdtPxE18 = _underlyingPriceE18(BSC.vUSDT);

        uint8 incumbent = 0; // 0 idle, 1 sUSDe, 2 vUSDT
        uint256 rotations = 0;
        int256 carryUsdE8 = 0;

        for (uint256 i = 0; i < N_INTERVALS; i++) {
            uint8 target = _pickHigher(_susdeBps[i], _vusdtBps[i], incumbent);
            if (target != incumbent) {
                if (incumbent != 0) rotations += 1;
                _rotateTo(target, incumbent, vUSDT);
                incumbent = target;
            }

            // Realised carry for this interval on the full principal.
            if (target == 2) {
                // vUSDT: use the LIVE Venus supply APR.
                int256 annual = int256((PRINCIPAL_USDT * vusdtSupplyApr1e18) / 1e18);
                carryUsdE8 += int256(
                    (uint256(annual) * usdtPxE18 / 1e18 / 1e10) * INTERVAL_DAYS / 365
                );
            } else {
                // sUSDe: modelled Ethena APY (held as dealt token).
                uint256 annualUsd = (PRINCIPAL_USDT * _susdeBps[i]) / 10_000; // 1e18 USD
                carryUsdE8 += int256((annualUsd / 1e10) * INTERVAL_DAYS / 365);
            }

            vm.warp(block.timestamp + INTERVAL_DAYS * 1 days);
        }

        // Unwind whatever wrapper is held back to USDT so the principal returns
        // cleanly to the tracked-token bucket.
        _unwindTo(incumbent, vUSDT);

        // ---- Credit position equity for any parked vUSDT collateral ----
        uint256 vSupplied = vUSDT.balanceOfUnderlying(address(this));
        if (vSupplied > 0) {
            _creditPositionEquityE8(int256((vSupplied * usdtPxE18) / 1e18 / 1e10));
        }

        // ---- Net rotation carry minus rotation drag ----
        uint256 rotCostBps = ROT_BPS / 2 + rotations * ROT_BPS; // initial half + per rotation
        int256 dragUsdE8 = int256((PRINCIPAL_USDT * rotCostBps) / 10_000 / 1e10);
        _creditPositionEquityE8(carryUsdE8 - dragUsdE8);

        emit log_named_uint("rotations", rotations);
        emit log_named_int("rotation_carry_usd_e8", carryUsdE8);

        _endPnL("B14-04-wrapper-apy-rotation-susde-vusdt");
    }

    function _pickHigher(uint256 sBps, uint256 vBps, uint8 incumbent) internal pure returns (uint8) {
        if (incumbent == 1) return vBps >= sBps + HYST_BPS ? 2 : 1;
        if (incumbent == 2) return sBps >= vBps + HYST_BPS ? 1 : 2;
        return sBps >= vBps ? 1 : 2;
    }

    function _rotateTo(uint8 target, uint8 from_, IVToken vUSDT) internal {
        _unwindTo(from_, vUSDT);
        if (target == 1) {
            // Hold sUSDe: deal it 1:1 against the USDT principal (sUSDe OFT cannot
            // be minted on-chain; the dealt position represents the wrapper hold).
            uint256 usdt = IERC20(BSC.USDT).balanceOf(address(this));
            if (usdt == 0) return;
            _fund(BSC.sUSDe, address(this), usdt); // 1:1 USD notional
            // Burn the USDT to reflect the conversion into the sUSDe wrapper.
            IERC20(BSC.USDT).transfer(address(0xdead), usdt);
        } else if (target == 2) {
            uint256 usdt = IERC20(BSC.USDT).balanceOf(address(this));
            if (usdt > 0) vUSDT.mint(usdt);
        }
    }

    function _unwindTo(uint8 from_, IVToken vUSDT) internal {
        if (from_ == 1) {
            uint256 s = IERC20(BSC.sUSDe).balanceOf(address(this));
            if (s == 0) return;
            // sUSDe OFT cannot be redeemed on the fork; convert the position back
            // to USDT 1:1 (burn sUSDe, mint-back USDT notional via deal).
            IERC20(BSC.sUSDe).transfer(address(0xdead), s);
            _fund(BSC.USDT, address(this), s);
        } else if (from_ == 2) {
            uint256 v = IERC20(BSC.vUSDT).balanceOf(address(this));
            if (v > 0) vUSDT.redeem(v);
        }
    }

    function _underlyingPriceE18(address vToken) internal view returns (uint256) {
        (bool ok, bytes memory d) = LOCAL_VENUS_ORACLE.staticcall(
            abi.encodeWithSignature("getUnderlyingPrice(address)", vToken)
        );
        if (!ok || d.length < 32) return 1e18;
        uint256 p = abi.decode(d, (uint256));
        return p == 0 ? 1e18 : p;
    }
}
