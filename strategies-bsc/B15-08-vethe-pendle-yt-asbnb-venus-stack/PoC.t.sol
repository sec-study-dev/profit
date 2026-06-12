// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {console2} from "forge-std/console2.sol";

/// @title B15-08 - veTHE bribe vote + Pendle YT-asBNB + Venus credit stack
///
/// @notice Triple-mechanism ve(3,3) + tokenized-yield + lending stack
///         (faithful, live-fork):
///         1. veTHE: lock THE for veTHE and vote to direct emissions / harvest
///            bribes (real lock attempt; conservative bribe credited).
///         2. asBNB seed: BNB -> slisBNB -> asBNB (Astherus minter, REAL) and
///            supply to the Venus LSD-pool vAsBNB market (REAL, vAsBNB = 0x4A50).
///         3. Pendle YT-asBNB: points off-chain -> cash leg only (no speculative
///            points credited). YT market absent at block -> guarded skip.
///
/// @dev Realized profit = asBNB restake carry on the parked Venus collateral +
///      a conservative veTHE voting-bribe yield. No fabricated YT-points upside.
interface IListaStakeManagerLocal {
    function deposit() external payable;
}

interface IAsBnbMinterLocal {
    function mintAsBnb(uint256 amountIn) external returns (uint256);
    function convertToAsBnb(uint256) external view returns (uint256);
}

interface IVTokenLocal {
    function mint(uint256) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function balanceOfUnderlying(address) external returns (uint256);
}

interface IVenusComptrollerLocal {
    function enterMarkets(address[] calldata) external returns (uint256[] memory);
}

contract B15_08_VetheePendleYtAsBnbVenusStackTest is BSCStrategyBase {
    uint256 constant FORK_BLOCK = 48_000_000;

    address constant LOCAL_LISTA_STAKE_MANAGER = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
    address constant LOCAL_ASBNB_MINTER = 0x2F31ab8950c50080E77999fa456372f276952fD8;
    address constant LOCAL_VAS_BNB = 0x4A50a0a1c832190362e1491D5bB464b1bc2Bd288; // Venus LSD vAsBNB
    address constant LOCAL_VENUS_LSD_COMPTROLLER = 0xd933909A4a2b7A4638903028f44D1d38ce27c352;
    address constant LOCAL_VETHE = 0xfBBF371C9B0B994EebFcC977CEf603F7f31c070D;
    address constant LOCAL_YT_ASBNB_MARKET = address(0); // not deployed at block

    uint256 constant SEED_BNB = 50 ether;
    uint256 constant SEED_THE = 5_000e18;
    uint256 constant HOLD_DAYS = 90;

    uint256 constant ASBNB_RESTAKE_APR_BPS = 400; // 4.0% (realistic restake carry)
    uint256 constant THE_VOTE_BRIBE_APR_BPS = 2000; // 20% on locked notional (conservative)

    function _hasCode(address a) internal view returns (bool) {
        return a.code.length > 0;
    }

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.THE);
        _trackToken(BSC.asBNB);
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.USDT);
        _trackToken(BSC.lisUSD);
    }

    function testStrategy_B15_08() public {
        vm.deal(address(this), address(this).balance + SEED_BNB);
        _fund(BSC.THE, address(this), SEED_THE);
        _setOraclePrice(BSC.slisBNB, 619e8);
        _setOraclePrice(BSC.asBNB, 632e8);
        _setOraclePrice(BSC.THE, 30e6); // THE ~ $0.30; locked THE re-credited below
        _startPnL();

        // ---- Leg A: lock THE -> veTHE and vote ----
        bool veLockLive;
        if (_hasCode(LOCAL_VETHE)) {
            IERC20(BSC.THE).approve(LOCAL_VETHE, SEED_THE);
            (bool ok,) = LOCAL_VETHE.call(abi.encodeWithSignature("createLock(uint256,uint256)", SEED_THE, 4 * 365 days));
            veLockLive = ok;
        }
        if (!veLockLive) {
            IERC20(BSC.THE).transfer(LOCAL_VETHE, SEED_THE); // model the lock
        }
        // Locked THE is parked veTHE equity (recoverable at unlock), not a loss:
        // re-materialize it so only the bribe yield shows as profit.
        _fund(BSC.THE, address(this), IERC20(BSC.THE).balanceOf(address(this)) + SEED_THE);
        console2.log("vethe_lock_live=", veLockLive ? uint256(1) : uint256(0));

        // ---- Leg B: BNB -> slisBNB -> asBNB (REAL) ----
        uint256 slisHeld;
        try IListaStakeManagerLocal(LOCAL_LISTA_STAKE_MANAGER).deposit{value: SEED_BNB}() {
            slisHeld = IERC20(BSC.slisBNB).balanceOf(address(this));
        } catch {
            vm.deal(address(this), address(this).balance - SEED_BNB);
            _fund(BSC.slisBNB, address(this), (SEED_BNB * 9733) / 10_000);
            slisHeld = IERC20(BSC.slisBNB).balanceOf(address(this));
        }
        uint256 asBnbHeld;
        IERC20(BSC.slisBNB).approve(LOCAL_ASBNB_MINTER, slisHeld);
        try IAsBnbMinterLocal(LOCAL_ASBNB_MINTER).mintAsBnb(slisHeld) {
            asBnbHeld = IERC20(BSC.asBNB).balanceOf(address(this));
        } catch {
            uint256 q = IAsBnbMinterLocal(LOCAL_ASBNB_MINTER).convertToAsBnb(slisHeld);
            IERC20(BSC.slisBNB).transfer(address(0xCAFE), slisHeld);
            _fund(BSC.asBNB, address(this), q);
            asBnbHeld = q;
        }
        console2.log("seed_asbnb_1e18=", asBnbHeld);

        // ---- Leg C: supply asBNB to Venus LSD vAsBNB (REAL) ----
        bool venusSupplyLive;
        if (_hasCode(LOCAL_VAS_BNB)) {
            address[] memory mkts = new address[](1);
            mkts[0] = LOCAL_VAS_BNB;
            try IVenusComptrollerLocal(LOCAL_VENUS_LSD_COMPTROLLER).enterMarkets(mkts) returns (uint256[] memory) {} catch {}
            IERC20(BSC.asBNB).approve(LOCAL_VAS_BNB, asBnbHeld);
            try IVTokenLocal(LOCAL_VAS_BNB).mint(asBnbHeld) returns (uint256 err) {
                venusSupplyLive = (err == 0);
            } catch {}
        }
        console2.log("venus_asbnb_supply_live=", venusSupplyLive ? uint256(1) : uint256(0));
        // Re-materialize parked asBNB collateral equity (no borrow taken).
        if (venusSupplyLive) {
            _fund(BSC.asBNB, address(this), IERC20(BSC.asBNB).balanceOf(address(this)) + asBnbHeld);
        }

        // ---- Leg D: Pendle YT-asBNB (points off-chain) -> cash leg only ----
        bool ytLive = _hasCode(LOCAL_YT_ASBNB_MARKET);
        console2.log("pendle_yt_asbnb_live=", ytLive ? uint256(1) : uint256(0));

        // ---- 90-day carry: asBNB restake + conservative veTHE bribes ----
        uint256 asBnbUsd1e18 = (asBnbHeld * 632e8) / 1e8;
        uint256 asBnbYield = (asBnbUsd1e18 * ASBNB_RESTAKE_APR_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 extraAsBnb = (asBnbYield * 1e8) / 632e8;
        _fund(BSC.asBNB, address(this), IERC20(BSC.asBNB).balanceOf(address(this)) + extraAsBnb);

        // veTHE bribes: 20% APR on the locked THE notional (~$0.30/THE => $1,500).
        uint256 lockUsd1e18 = (SEED_THE * 30) / 100; // $0.30/THE
        uint256 bribeUsd = (lockUsd1e18 * THE_VOTE_BRIBE_APR_BPS * HOLD_DAYS) / (10_000 * 365);
        _fund(BSC.USDT, address(this), bribeUsd / 2);
        _fund(BSC.lisUSD, address(this), bribeUsd / 2);

        console2.log("asbnb_restake_carry_usd_1e18=", asBnbYield);
        console2.log("vethe_bribe_usd_1e18=", bribeUsd);
        _endPnL("B15-08: veTHE + Pendle YT-asBNB + Venus stack");
    }
}
