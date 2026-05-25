// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Liquity v1/v2 BorrowerOperations entrypoint. v2 introduces explicit interest rate.
interface IBorrowerOperations {
    // ---- Liquity v1 style ----
    function openTrove(
        uint256 maxFeePercentage,
        uint256 LUSDAmount,
        address upperHint,
        address lowerHint
    ) external payable;
    function closeTrove() external;
    function addColl(address upperHint, address lowerHint) external payable;
    function withdrawColl(uint256 amount, address upperHint, address lowerHint) external;
    function withdrawLUSD(uint256 maxFeePercentage, uint256 amount, address upperHint, address lowerHint) external;
    function repayLUSD(uint256 amount, address upperHint, address lowerHint) external;

    // ---- Liquity v2 style (BOLD) ----
    function openTrove(
        address owner,
        uint256 ownerIndex,
        uint256 collAmount,
        uint256 boldAmount,
        uint256 upperHint,
        uint256 lowerHint,
        uint256 annualInterestRate,
        uint256 maxUpfrontFee,
        address addManager,
        address removeManager,
        address receiver
    ) external returns (uint256 troveId);

    function adjustTroveInterestRate(
        uint256 troveId,
        uint256 newAnnualInterestRate,
        uint256 upperHint,
        uint256 lowerHint,
        uint256 maxUpfrontFee
    ) external;
}
