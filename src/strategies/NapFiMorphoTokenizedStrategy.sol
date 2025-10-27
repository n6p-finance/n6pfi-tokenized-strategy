// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * NapFi Morpho Tokenized Strategy (ERC-4626 Wrapper)
 * --------------------------------------------------
 * Wraps the NapFiSparkAdapter inside an ERC-4626-compatible
 * TokenizedStrategy for Octant V2 and Yearn Kalani Vaults.
 * 
 * Limitations:
 * - No external debt handling yet.
 * - ERC-4626 functions (deposit, mint, withdraw, redeem) are inherited
 *   from OpenZeppelin's ERC4626 implementation.
 * 
 * Important Note:
 * This strategy assumes that the underlying adapter (NapFiSparkAdapter)
 * correctly handles interactions with the Morpho protocol.
 */

import { ERC20 } from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import { BaseTokenizedStrategy } from "tokenized-strategy/BaseTokenizedStrategy.sol";
import { NapFiSparkAdapter } from "../adapters/SparkAdapter.sol";
import {ERC4626} from "openzeppelin-contracts/token/ERC20/extensions/ERC4626.sol";

contract NapFiSparkTokenizedStrategy is BaseTokenizedStrategy, ERC4626 {
    NapFiSparkAdapter public adapter;

    constructor(address _asset, address _adapter)
        BaseTokenizedStrategy(_asset, msg.sender)
    {
        adapter = NapFiMorphoAdapter(_adapter);
    }

    //--------------------------------------------------
    // Internal Overrides
    //--------------------------------------------------

    /// @notice Deploy funds to Morpho via the adapter
    function _deployFunds(uint256 amount) internal override {
        adapter.depositToMorpho(amount);
    }

    /// @notice Withdraw funds when vault needs liquidity
    function _freeFunds(uint256 amount) internal override {
        adapter.withdrawFromMorpho(amount, address(this));
    }

    /// @notice Harvest yield, donate, and report profit/loss
    function _harvestAndReport()
        internal
        override
        returns (uint256 profit, uint256 loss, uint256 debtPayment)
    {
        uint256 beforeAssets = totalAssets();
        adapter.harvest();
        uint256 afterAssets = totalAssets();

        if (afterAssets > beforeAssets) {
            profit = afterAssets - beforeAssets;
        } else {
            loss = beforeAssets - afterAssets;
        }

        // No external debt handling yet
        return (profit, loss, 0);
    }

    /// @notice Total managed assets
    function totalAssets() public view override returns (uint256) {
        return adapter.totalAssets();
    }
}
