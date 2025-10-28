// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * NapFi Aave Tokenized Strategy (Adapter + ERC-4626 + Donation)
 * --------------------------------------------------------------
 * Full Octant/Yearn v3-compatible modular strategy that integrates
 * NapFiAaveAdapter to manage Aave deposits while using the
 * TokenizedStrategy inheritance chain for ERC-4626 functionality.
 *
 * Architecture:
 * NapFiAaveTokenizedStrategy
 *    ↓ inherits from
 * BaseHealthCheck              → adds safety bounds, role control
 *    ↓ inherits from
 * BaseStrategy                 → delegates hooks to child functions
 *    ↓ uses
 * YieldDonatingTokenizedStrategy → handles donation share minting
 *    ↓ inherits from
 * TokenizedStrategy            → implements ERC-4626 vault standard
 */

import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { BaseHealthCheck } from "tokenized-strategy/BaseHealthCheck.sol";
import { BaseStrategy } from "tokenized-strategy/BaseStrategy.sol";
import { YieldDonatingTokenizedStrategy } from "tokenized-strategy/YieldDonatingTokenizedStrategy.sol";
import { NapFiAaveAdapter } from "../adapters/AaveAdapter.sol";

contract NapFiAaveTokenizedStrategy is BaseHealthCheck {
    // ------------------------------------------------------------
    // Core Configuration
    // ------------------------------------------------------------
    NapFiAaveAdapter public immutable adapter; // Logic layer (Aave interaction)
    IERC20 public immutable ASSET;             // Underlying asset (e.g., USDC)

    // ------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------
    constructor(
        address _asset,
        string memory _name,
        address _management,
        address _keeper,
        address _emergencyAdmin,
        address _donationAddress,
        address _tokenizedStrategyAddress,  // Deployed TokenizedStrategy impl
        address _adapter                    // NapFiAaveAdapter contract
    )
        BaseHealthCheck(
            _asset,
            _name,
            _management,
            _keeper,
            _emergencyAdmin,
            _donationAddress,
            _tokenizedStrategyAddress
        )
    {
        require(_asset != address(0), "Invalid asset");
        require(_adapter != address(0), "Invalid adapter");

        adapter = NapFiAaveAdapter(_adapter);
        ASSET = IERC20(_asset);

        // Pre-approve adapter to optimize deposit gas
        ASSET.approve(_adapter, type(uint256).max);
    }

    // ------------------------------------------------------------
    // 1️. Deploy funds (called when user deposits)
    // ------------------------------------------------------------
    /// @dev TokenizedStrategy → BaseStrategy → calls this hook
    function _deployFunds(uint256 _amount) internal override {
        if (_amount == 0) return;
        adapter.depositToAave(_amount);
    }

    // ------------------------------------------------------------
    // 2️. Withdraw funds (called when user redeems)
    // ------------------------------------------------------------
    /// @dev TokenizedStrategy → BaseStrategy → calls this hook
    function _freeFunds(uint256 _amount) internal override {
        if (_amount == 0) return;
        adapter.withdrawFromAave(_amount, address(this));
    }

    // ------------------------------------------------------------
    // 3️. Harvest yield + report total managed assets
    // ------------------------------------------------------------
    /// @dev Called by keeper on report(); TokenizedStrategy calculates yield
    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        // Step 1: trigger adapter’s internal yield logic
        try adapter.harvest() {
            // adapter handles donation slicing, claiming rewards, etc.
        } catch {
            // continue safely even if adapter has no yield
        }

        // Step 2: report updated total assets
        _totalAssets = adapter.totalAssets();
    }

    // ------------------------------------------------------------
    // 4️. Deposit limit enforcement
    // ------------------------------------------------------------
    /// @notice Optional; may proxy Aave pool cap via adapter
    function availableDepositLimit(address)
        public
        view
        override
        returns (uint256)
    {
        return type(uint256).max;
    }
}
