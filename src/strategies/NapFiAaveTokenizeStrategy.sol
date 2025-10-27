// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * NapFi Aave Tokenized Strategy (Octant V2 Compatible)
 * ----------------------------------------------------
 * Implements a minimal ERC-4626 TokenizedStrategy that deposits into
 * Aave via its aToken vault, reports yield, and donates rewards to
 * Octant’s donation address automatically.
 *
 * Based on Octant v2 "SavingsUsdcStrategy" tutorial:
 * https://docs.v2.octant.build/docs/integration_guides_and_tutorials/strategy-development-example
 *
 * Hackathon Coverage:
 * - Best Yield-Donating Strategy
 * - Best Use of Aave
 * - Best Integration of Octant v2 Modular Vaults
 */

import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "openzeppelin-contracts/interfaces/IERC4626.sol";
import { BaseHealthCheck } from "tokenized-strategy/BaseHealthCheck.sol";
import { BaseStrategy } from "tokenized-strategy/BaseStrategy.sol";
import { YieldDonatingTokenizedStrategy } from "tokenized-strategy/YieldDonatingTokenizedStrategy.sol";

/**
 * Key roles (Octant standard):
 *  - Management: can set bounds, change donation address
 *  - Keeper: triggers harvest/report()
 *  - EmergencyAdmin: can pause & emergency withdraw
 *  - Donation Address: receives minted yield shares
 */
contract NapFiAaveTokenizedStrategy is BaseHealthCheck {
    // ----------------------------
    // Protocol configuration
    // ----------------------------
    address public immutable AAVE_VAULT; // The ERC-4626 aToken vault (e.g., aUSDC)
    IERC20 public immutable ASSET;        // Underlying (e.g., USDC)

    // ----------------------------
    // Constructor
    // ----------------------------
    constructor(
        address _asset,
        string memory _name,
        address _management,
        address _keeper,
        address _emergencyAdmin,
        address _donationAddress,
        address _tokenizedStrategyAddress, // Octant’s TokenizedStrategy base
        address _aaveVault                  // Aave ERC-4626 vault (e.g. Pool wrapper)
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
        if (_asset == address(0) || _aaveVault == address(0))
            revert("Invalid address");

        AAVE_VAULT = _aaveVault;
        ASSET = IERC20(_asset);
        ASSET.approve(_aaveVault, type(uint256).max); // infinite approval
    }

    // ----------------------------
    // 1. Deploy user funds into Aave
    // ----------------------------
    function _deployFunds(uint256 _amount) internal override {
        IERC4626(AAVE_VAULT).deposit(_amount, address(this));
    }

    // ----------------------------
    // 2. Withdraw user funds from Aave
    // ----------------------------
    function _freeFunds(uint256 _amount) internal override {
        IERC4626(AAVE_VAULT).withdraw(_amount, address(this), address(this));
    }

    // ----------------------------
    // 3. Report total managed assets (used for yield calc)
    // ----------------------------
    function _harvestAndReport()
        internal
        view
        override
        returns (uint256 _totalAssets)
    {
        uint256 shares = IERC4626(AAVE_VAULT).balanceOf(address(this));
        uint256 vaultAssets = IERC4626(AAVE_VAULT).convertToAssets(shares);
        uint256 idleAssets = ASSET.balanceOf(address(this));
        _totalAssets = vaultAssets + idleAssets;
    }

    // ----------------------------
    // 4. Respect Aave deposit limit (proxy upstream)
    // ----------------------------
    function availableDepositLimit(address)
        public
        view
        override
        returns (uint256)
    {
        return IERC4626(AAVE_VAULT).maxDeposit(address(this));
    }
}
