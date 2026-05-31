// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSC} from "src/constants/BSC.sol";

/// @notice Known whale addresses for rebasing or allow-listed BSC tokens.
///         Use `vm.prank(whale)` + `IERC20.transfer` to fund a strategy
///         contract with these tokens. For ordinary BEP20s, prefer `deal()`.
///
/// @dev    Returns address(0) for tokens without a preset whale; the caller
///         must then either pick a per-test address or fall back to `deal`.
///         All entries below are best-guess holders verified at the time
///         of writing — Wave 2 agents should re-verify before relying.
library BSCWhales {
    function whaleOf(address token) internal pure returns (address) {
        // slisBNB: Lista StakeManager itself is the canonical large holder
        // (it routes BNB <-> slisBNB). // TODO verify: prefer a passive LP if
        // the StakeManager invariant breaks on `transfer`.
        if (token == BSC.slisBNB) return 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;

        // USDe on BSC: bridged OFT; Binance hot wallet typically holds large
        // balances. Falls back to deal() if address(0). // TODO verify
        if (token == BSC.USDe) return address(0);

        // sUSDe: Ethena does not expose a canonical BSC whale; deal() works
        // for the ERC-4626 share token. Return zero -> caller falls back.
        if (token == BSC.sUSDe) return address(0);

        return address(0);
    }
}
