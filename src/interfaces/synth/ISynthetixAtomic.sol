// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Synthetix atomic exchange entrypoint. Most strategies hit the
///         Synthetix proxy address and call exchangeAtomically with currencyKey
///         (bytes32) identifiers (sUSD = "sUSD", sETH = "sETH", etc.).
/// @dev    Exact selector signature can drift between releases; F14 should verify
///         against the deployed Synthetix proxy ABI before use.
interface ISynthetixAtomic {
    function exchangeAtomically(
        bytes32 sourceCurrencyKey,
        uint256 sourceAmount,
        bytes32 destinationCurrencyKey,
        bytes32 trackingCode,
        uint256 minAmount
    ) external returns (uint256 amountReceived);

    function exchange(
        bytes32 sourceCurrencyKey,
        uint256 sourceAmount,
        bytes32 destinationCurrencyKey
    ) external returns (uint256 amountReceived);

    function settle(address user, bytes32 currencyKey) external returns (uint256, uint256, uint256);
}
