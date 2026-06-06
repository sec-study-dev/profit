// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @notice Ethena USDe on BSC (bridged via LayerZero OFT).
/// @dev    USDe on BSC is a bridged OFT - the canonical mint/redeem flows are
///         on Ethereum mainnet. This interface only covers the BSC-side ERC20
///         surface. For minting, see EthenaMinting on mainnet.
interface IUSDe is IERC20 {
    // No BSC-side mint/redeem; OFT contracts handle cross-chain supply.
    // TODO: add OFT-specific getters once the BSC OFT adapter ABI is fixed.
}
