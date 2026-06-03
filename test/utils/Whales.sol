// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Mainnet} from "src/constants/Mainnet.sol";

/// @notice Known whale addresses for rebasing or non-`deal`-friendly tokens.
///         Use `vm.prank(whale)` + `IERC20.transfer` to fund a strategy contract
///         with these tokens. For ordinary ERC20s, prefer `deal()`.
library Whales {
    /// @notice Returns a holder of `token` known to have a non-trivial balance.
    /// @dev    Returns address(0) for tokens with no preset whale; the caller
    ///         must then either pick a per-test address or fall back to `deal`.
    function whaleOf(address token) internal pure returns (address) {
        // stETH: Curve stETH/ETH pool - holds 34K+ stETH across all relevant
        //        fork blocks (20_300_000–20_500_000). The previous Lido treasury
        //        address (0x176F3DAb...) only held ~7 stETH at those blocks,
        //        causing BALANCE_EXCEEDED for 50 stETH transfers.
        if (token == Mainnet.STETH) return 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;

        // OETH (Origin Ether) - large holder
        // TODO: verify (snapshot value, may drift)
        if (token == Mainnet.OETH) return 0x70fCE97d671E81080CA3ab4cc7A59aAc2E117137;

        // USDM (Mountain Protocol) - allow-listed token; cannot use deal cleanly.
        // TODO: verify USDM whale (allow-listed holder)
        if (token == Mainnet.USDM) return address(0);

        // eETH (rebasing): EtherFi liquidity pool itself holds rebasing balances
        // for users. Easier path: deposit ETH into EtherFiLiquidityPool to mint.
        if (token == Mainnet.EETH) return address(0);

        return address(0);
    }
}
