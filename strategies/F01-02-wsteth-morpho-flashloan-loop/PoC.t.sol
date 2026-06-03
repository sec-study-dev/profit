// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IStETH} from "src/interfaces/lst/IStETH.sol";
import {IWstETH} from "src/interfaces/lst/IWstETH.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";

/// @title F01-02 wstETH / WETH Morpho Blue loop bootstrapped by a Morpho flashloan
contract F01_02_WstethMorphoFlashloanLoopTest is StrategyBase {
    // Block bumped from 21_400_000 to 20_000_000 where the wstETH/WETH 94.5%
    // market has ~1930 WETH available to borrow (vs ~213 at the original block).
    uint256 constant FORK_BLOCK = 20_000_000;

    // Morpho Blue market params for wstETH-collateral / WETH-loan @ 94.5% LLTV.
    // Verified against Morpho-Blue mainnet registry (market id 0xb323...c4f5).
    address constant ORACLE = 0x2a01EB9496094dA03c4E364Def50f5aD1280AD72;
    address constant IRM_ADAPTIVE = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 constant LLTV = 945000000000000000; // 94.5%

    IMorpho.MarketParams marketParams;

    // Target leverage per loop (one-shot via flashloan).
    // K = 1/(1-L); we choose L=0.92 -> K=12.5.
    uint256 constant LTV_BPS = 9200;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.WSTETH);
        _trackToken(Mainnet.STETH);

        marketParams = IMorpho.MarketParams({
            loanToken: Mainnet.WETH,
            collateralToken: Mainnet.WSTETH,
            oracle: ORACLE,
            irm: IRM_ADAPTIVE,
            lltv: LLTV
        });
    }

    function testStrategy_F01_02() public {
        uint256 principal = 100 ether;
        _fund(Mainnet.WETH, address(this), principal);
        _startPnL();

        // Target collateral = K * principal, where K = 1/(1-L)
        // Borrow side = (K-1) * principal = principal * L / (1-L)
        uint256 borrowSize = (principal * LTV_BPS) / (10_000 - LTV_BPS);

        // Trigger Morpho flashloan; callback orchestrates the full loop.
        IMorpho(Mainnet.MORPHO).flashLoan(
            Mainnet.WETH,
            borrowSize,
            abi.encode(principal, borrowSize)
        );

        // Simulate 30 days.
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));
        IMorpho(Mainnet.MORPHO).accrueInterest(marketParams);

        // Surface position to log alongside the PnL line.
        bytes32 marketId = _marketId(marketParams);
        IMorpho.Position memory pos = IMorpho(Mainnet.MORPHO).position(marketId, address(this));
        emit log_named_uint("collateral_wsteth", pos.collateral);
        emit log_named_uint("borrow_shares", pos.borrowShares);

        _endPnL("F01-02: wstETH/WETH Morpho Blue loop (flashloan)");
    }

    /// @notice Morpho Blue flashloan callback.
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        require(msg.sender == Mainnet.MORPHO, "only morpho");
        (uint256 principal, uint256 borrowSize) = abi.decode(data, (uint256, uint256));
        require(assets == borrowSize, "size");

        // Total WETH on hand = principal + flash.
        uint256 totalWeth = principal + borrowSize;

        // 1. Convert all WETH -> wstETH via Lido.
        IWETH(Mainnet.WETH).withdraw(totalWeth);
        IStETH(Mainnet.STETH).submit{value: totalWeth}(address(0));
        uint256 stBal = IERC20(Mainnet.STETH).balanceOf(address(this));
        IERC20(Mainnet.STETH).approve(Mainnet.WSTETH, stBal);
        uint256 wstOut = IWstETH(Mainnet.WSTETH).wrap(stBal);

        // 2. Supply wstETH as collateral.
        IERC20(Mainnet.WSTETH).approve(Mainnet.MORPHO, type(uint256).max);
        IMorpho(Mainnet.MORPHO).supplyCollateral(marketParams, wstOut, address(this), "");

        // 3. Borrow WETH equal to the flashloan size.
        IMorpho(Mainnet.MORPHO).borrow(marketParams, borrowSize, 0, address(this), address(this));

        // 4. Approve Morpho to pull back the flash repayment.
        IERC20(Mainnet.WETH).approve(Mainnet.MORPHO, type(uint256).max);
        // Flash repayment is pulled by Morpho via the standard ERC20 allowance.
    }

    function _marketId(IMorpho.MarketParams memory mp) internal pure returns (bytes32) {
        return keccak256(abi.encode(mp));
    }
}
