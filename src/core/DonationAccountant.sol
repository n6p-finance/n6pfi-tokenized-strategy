// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * DonationAccountant.sol
 * -----------------------
 * Tracks all donations from adapters (Aave, Spark, etc.)
 * and records them for leaderboard & ImpactNFT updates.
 */

import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";

contract DonationAccountant is Ownable {
    mapping(address => uint256) public totalDonatedByStrategy;
    mapping(address => uint256) public totalDonatedByUser;
    uint256 public globalTotalDonated;

    event DonationRecorded(address indexed fromStrategy, address indexed user, uint256 amount, uint256 timestamp);

    /// Called by Adapters to record new donation
    function recordDonation(address fromStrategy, uint256 amount) external {
        require(amount > 0, "no donation");

        totalDonatedByStrategy[fromStrategy] += amount;
        totalDonatedByUser[msg.sender] += amount;
        globalTotalDonated += amount;

        emit DonationRecorded(fromStrategy, msg.sender, amount, block.timestamp);
    }

    /// View: get a user’s cumulative donation
    function getTotalImpact(address user) external view returns (uint256) {
        return totalDonatedByUser[user];
    }
}
