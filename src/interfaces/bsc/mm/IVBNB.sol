// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";

/// @notice vBNB-specific overrides: mint is payable and takes no argument;
///         repayBorrow is payable as well.
interface IVBNB is IVToken {
    function mint() external payable;
    function repayBorrow() external payable;
}
