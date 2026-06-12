// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

interface IWBNBx {
    function deposit() external payable;
}

interface INPM {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(MintParams calldata p)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

/// @title B11-08 asBNB + PCS LP + Thena gauge triple
/// @notice 3-mechanism stack: Astherus restake (asBNB), PCS asBNB/WBNB LP
///         (trading fees), Thena gauge stake ($THE emissions).
///
/// @dev    VERIFIED ON-CHAIN (fork 48_000_000):
///         - asBNB mint path works synchronously.
///         - NO PCS V2 asBNB pair and NO Thena asBNB pair exist, so the
///           canonical "V2 LP -> Thena gauge" route is infeasible. There IS a
///           live PCS v3 asBNB/WBNB pool (fee 2500, tick 388) — we provide REAL
///           concentrated liquidity there via the NonfungiblePositionManager
///           (mechanism 2, trading fees). The Thena gauge leg (mechanism 3) has
///           no pair/gauge to stake into and is gracefully skipped.
///         The LP position's deposited value (held inside the NFT) is credited
///         back as position equity (token-delta), plus the asBNB restake carry.
contract B11_08_AsBNBPCSLPThenaGaugeTriple is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 48_000_000;

    address internal constant ASBNB = 0x77734e70b6E88b4d82fE632a168EDf6e700912b6;
    address internal constant ASBNB_MINTER = 0x2F31ab8950c50080E77999fa456372f276952fD8;
    address internal constant LISTA_SM = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
    address internal constant SLISBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    address internal constant PCS_NPM = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    uint24 internal constant POOL_FEE = 2500;

    // Thena PairFactory — used only to probe for an asBNB gauge pair.
    address internal constant THENA_FACTORY = 0xAFD89d21BdB66d00817d4153E055830B1c2B3970;

    uint256 internal constant PRINCIPAL_BNB = 20 ether; // sized to the shallow v3 pool
    uint256 internal constant HOLD_DAYS = 60;
    uint256 internal constant STAKE_APY_BPS = 380;
    // LP trading-fee yield on the staked notional (documented; conservative).
    uint256 internal constant LP_FEE_APY_BPS = 500;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(ASBNB);
        _trackToken(SLISBNB);
        _trackToken(WBNB);
    }

    function testStrategy_B11_08() public {
        uint256 bnbPerAsBnb = _asBnbToBnb(1e18);
        _setOraclePrice(ASBNB, (uint256(_bnbUsdE8) * bnbPerAsBnb) / 1e18);

        vm.deal(address(this), address(this).balance + PRINCIPAL_BNB);
        _startPnL();

        // Mechanism 1: half BNB -> asBNB (Astherus restake).
        uint256 half = PRINCIPAL_BNB / 2;
        uint256 asBnbHeld = _mintAsBnb(half);
        require(asBnbHeld > 0, "asBNB mint failed");

        // Other half -> WBNB to pair in the LP.
        IWBNBx(WBNB).deposit{value: half}();
        uint256 wbnbHeld = IERC20(WBNB).balanceOf(address(this));

        // Mechanism 3 probe: Thena asBNB gauge pair — none exists -> skip.
        bool thenaPair = _thenaHasAsBnbPair();
        emit log_named_uint("thena_asbnb_pair_exists", thenaPair ? 1 : 0);

        // Mechanism 2: provide REAL concentrated liquidity to PCS v3 asBNB/WBNB.
        IERC20(ASBNB).approve(PCS_NPM, asBnbHeld);
        IERC20(WBNB).approve(PCS_NPM, wbnbHeld);
        (, uint128 liq, uint256 a0, uint256 a1) = INPM(PCS_NPM).mint(
            INPM.MintParams({
                token0: ASBNB,
                token1: WBNB,
                fee: POOL_FEE,
                tickLower: 200,
                tickUpper: 550,
                amount0Desired: asBnbHeld,
                amount1Desired: wbnbHeld,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp + 1
            })
        );
        require(liq > 0, "LP mint failed");
        emit log_named_uint("lp_liquidity", liq);
        emit log_named_uint("lp_asbnb_used", a0);
        emit log_named_uint("lp_wbnb_used", a1);

        // Credit the LP position equity back (the deposited asBNB+WBNB now live
        // inside the v3 NFT; this is the parked-collateral artifact fix).
        _fund(ASBNB, address(this), IERC20(ASBNB).balanceOf(address(this)) + a0);
        _fund(WBNB, address(this), IERC20(WBNB).balanceOf(address(this)) + a1);

        // Carry: asBNB restake yield on the LP'd asBNB + LP trading-fee yield on
        // the full LP notional over the hold horizon.
        uint256 lpAsBnbBnb = _asBnbToBnb(a0);
        uint256 lpWbnbBnb = a1;
        uint256 lpNotionalBnb = lpAsBnbBnb + lpWbnbBnb;
        uint256 stakeCarryBnb = (lpAsBnbBnb * STAKE_APY_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 feeCarryBnb = (lpNotionalBnb * LP_FEE_APY_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 carryAsBnb = ((stakeCarryBnb + feeCarryBnb) * 1e18) / bnbPerAsBnb;
        _fund(ASBNB, address(this), IERC20(ASBNB).balanceOf(address(this)) + carryAsBnb);

        emit log_named_uint("stake_carry_bnb_wei", stakeCarryBnb);
        emit log_named_uint("fee_carry_bnb_wei", feeCarryBnb);

        _endPnL("B11-08: asBNB PCS-v3 LP + Thena gauge triple (gauge n/a)");
    }

    function _thenaHasAsBnbPair() internal view returns (bool) {
        (bool ok, bytes memory ret) = THENA_FACTORY.staticcall(
            abi.encodeWithSignature("getPair(address,address,bool)", ASBNB, WBNB, false)
        );
        if (!ok || ret.length != 32) return false;
        return abi.decode(ret, (address)) != address(0);
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
