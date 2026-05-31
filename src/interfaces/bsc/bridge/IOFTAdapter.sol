// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice LayerZero V2 OFT (Omnichain Fungible Token) send interface.
/// @dev    Used by USDT / USDC / USDe OFT adapters on BSC for cross-chain
///         transfers. // TODO: confirm exact struct shapes against
///         LayerZero V2 IOFT canonical interface.
interface IOFTAdapter {
    struct SendParam {
        uint32 dstEid;          // destination endpoint id (LZ chain id)
        bytes32 to;             // recipient as bytes32
        uint256 amountLD;       // amount in local decimals
        uint256 minAmountLD;    // min received in local decimals
        bytes extraOptions;     // executor options (gas, native drop, ...)
        bytes composeMsg;       // optional compose payload
        bytes oftCmd;           // optional adapter-specific command
    }

    struct MessagingFee {
        uint256 nativeFee;
        uint256 lzTokenFee;
    }

    struct MessagingReceipt {
        bytes32 guid;
        uint64 nonce;
        MessagingFee fee;
    }

    struct OFTReceipt {
        uint256 amountSentLD;
        uint256 amountReceivedLD;
    }

    function send(SendParam calldata sendParam, MessagingFee calldata fee, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt);

    function quoteSend(SendParam calldata sendParam, bool payInLzToken)
        external
        view
        returns (MessagingFee memory fee);

    function token() external view returns (address);
}
