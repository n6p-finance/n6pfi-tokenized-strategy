// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IDonationAccountant
 * @notice Interface for recording donations and interacting with the donation routing layer (e.g., Octant Allocation).
 */
interface IDonationAccountant {
    /// @notice Record a donation made by `strategy` of `amount`
    function recordDonation(address strategy, uint256 amount) external;
}
