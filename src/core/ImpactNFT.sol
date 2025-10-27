// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "openzeppelin-contracts/token/ERC721/ERC721.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";

/**
 * ImpactNFT.sol
 * ----------------------------
 * Proof-of-Impact NFT that upgrades tier
 * based on cumulative donation amount.
 */

contract ImpactNFT is ERC721, Ownable {
    uint256 public nextTokenId;
    mapping(address => uint256) public totalImpact;
    mapping(address => uint8) public tier; // 1–5

    event TierUpgraded(address indexed user, uint8 newTier, uint256 totalImpact);

    constructor() ERC721("NapFi Impact NFT", "IMPACT") {}

    /// Called by DonationAccountant or adapter
    function updateTier(address user, uint256 totalDonated) external onlyOwner {
        totalImpact[user] = totalDonated;

        uint8 newTier;
        if (totalDonated < 100e6) newTier = 1; // <100 USDC
        else if (totalDonated < 500e6) newTier = 2;
        else if (totalDonated < 1000e6) newTier = 3;
        else if (totalDonated < 5000e6) newTier = 4;
        else newTier = 5;

        if (newTier > tier[user]) {
            tier[user] = newTier;
            emit TierUpgraded(user, newTier, totalDonated);
        }
    }

    /// Mint if user doesn’t already have one
    function mint(address to) external onlyOwner {
        require(balanceOf(to) == 0, "already minted");
        _safeMint(to, nextTokenId++);
    }
}
