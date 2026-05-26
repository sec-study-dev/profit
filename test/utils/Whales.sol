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
        // stETH: Lido treasury / large holder. Treasury balance is large enough
        //        for PoC scale; for >$10M operations prefer a different address.
        if (token == Mainnet.STETH) return 0x176F3DAb24a159341c0509bB36B833E7fdd0a132;

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
