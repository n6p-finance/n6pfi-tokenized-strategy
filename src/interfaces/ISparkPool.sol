// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title ISparkPool
 * @notice Minimal interface for Spark lending pool operations relevant for supply/withdraw and rewards.
 */
interface ISparkPool {
    /// @notice Supply `amount` of `asset` into Spark on behalf of `onBehalfOf`
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode
    ) external;

    /// @notice Withdraw `amount` of `asset` from Spark, sending to `to`
    function withdraw(address asset, uint256 amount, address to
    ) external returns (uint256);

    /// @notice Claim all reward tokens for `onBehalfOf`
    function claimAllRewards(address onBehalfOf)
        external returns (address[] memory rewardTokens, uint256[] memory claimedAmounts);

    /// @notice Returns the balance of yield-bearing sToken for `user`
    function balanceOf(address user) external view returns (uint256);
}
