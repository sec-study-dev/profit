// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Ethena mint/redeem contract (signed-order based). Order struct shape
///         and exact selector may evolve - verify against the deployed ABI before use.
/// @dev    Most-used functions: mint(Order, Signature), redeem(Order, Signature).
interface IEthenaMinting {
    enum OrderType { MINT, REDEEM }

    struct Order {
        OrderType order_type;
        uint256 expiry;
        uint256 nonce;
        address benefactor;
        address beneficiary;
        address collateral_asset;
        uint256 collateral_amount;
        uint256 usde_amount;
    }

    struct Signature {
        uint8 signature_type;
        bytes signature_bytes;
    }

    function mint(Order calldata order, Signature calldata signature) external;
    function redeem(Order calldata order, Signature calldata signature) external;
    function verifyOrder(Order calldata order, Signature calldata signature) external view returns (bool, bytes32);
}
