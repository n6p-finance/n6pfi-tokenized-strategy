// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IImpactNFT
 * @notice Interface for the “proof of impact” NFT system—tracks user donation tiers/levels
 * That only can be called when yield is donated.
 */
interface IImpactNFT {
    /// @notice Update the tier of `user` based on their cumulative `totalDonated`
    function updateTier(address user, uint256 totalDonated) external;
}
