// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @notice Renzo ezETH token. Mint via RestakeManager (see IRenzoRestakeManager).
interface IEzETH is IERC20 {}
