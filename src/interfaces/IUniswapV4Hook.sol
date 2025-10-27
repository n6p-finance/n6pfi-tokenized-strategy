// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IUniswapV4Hook
 * @notice Interface for converting reward tokens into a stable asset (via Uniswap V4 hook).
 */
interface IUniswapV4Hook {
    /// @notice Swap `amount` of `rewardToken` into `stableToken`, send to `to`, returns amount received
    function swapRewardsToStable(address rewardToken, uint256 amount, address to, address stableToken
    ) external returns (uint256);
}
