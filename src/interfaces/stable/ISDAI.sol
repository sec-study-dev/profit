// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC4626} from "src/interfaces/common/IERC4626.sol";

/// @notice MakerDAO sDAI - ERC-4626 vault accruing DSR.
interface ISDAI is IERC4626 {}
