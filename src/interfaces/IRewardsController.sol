// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IRewardsController
 * @notice Interface for claiming reward tokens from a rewards controller.
 */
// Rewards controller interface for claiming incentive tokens.
interface IRewardsController {
    function getRewardsList() external view returns (address[] memory);
    function claimAllRewardsToSelf(address[] calldata assets)
        external
        returns (address[] memory rewardsList, uint256[] memory claimedAmounts);
}
