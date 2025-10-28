// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IMorphoRewards {
    /// @notice Claim rewards for a user or contract
    /// @param assets List of assets supplied/borrowed in the protocol
    /// @param to Address to send the rewards to
    /// @return rewardTokens List of reward token addresses claimed
    /// @return claimedAmounts Amounts of each reward token claimed
    function claimAllRewards(address[] calldata assets, address to)
        external
        returns (address[] memory rewardTokens, uint256[] memory claimedAmounts);

    /// @notice Check pending rewards for a user
    /// @param assets List of assets supplied/borrowed
    /// @param user Address of the user
    /// @return rewardTokens List of reward token addresses
    /// @return pendingAmounts Amounts pending for each reward token
    function getPendingRewards(address[] calldata assets, address user)
        external
        view
        returns (address[] memory rewardTokens, uint256[] memory pendingAmounts);

    /// @notice Get reward token addresses managed by the contract
    /// @return rewardTokens List of reward token addresses
    function getRewardTokens() external view returns (address[] memory rewardTokens);
}
