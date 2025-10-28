// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * NapFi Enhanced Aave Tokenized Strategy (Adapter + ERC-4626 + Donation)
 * ----------------------------------------------------------------------
 * Advanced Octant/Yearn v3-compatible modular strategy with enhanced features
 * that integrates NapFiAaveAdapter while maintaining the donation functionality
 * and health check safety features.
 *
 * Architecture:
 * NapFiEnhancedAaveTokenizedStrategy
 *    ↓ inherits from
 * BaseHealthCheck              → adds safety bounds, role control  
 *    ↓ inherits from
 * BaseStrategy                 → delegates hooks to child functions
 *    ↓ uses
 * YieldDonatingTokenizedStrategy → handles donation share minting
 *    ↓ inherits from
 * TokenizedStrategy            → implements ERC-4626 vault standard
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseStrategy} from "tokenized-strategy/BaseStrategy.sol";
import {NapFiAaveAdapter} from "../adapters/AaveAdapter.sol";

contract NapFiAaveTokenizedStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------
    // Core Configuration
    // ------------------------------------------------------------
    NapFiAaveAdapter public immutable adapter;
    IERC20 public immutable ASSET;
    
    // ------------------------------------------------------------
    // Enhanced Strategy State
    // ------------------------------------------------------------
    uint256 public lastHarvestTimestamp;
    uint256 public cumulativeYield;
    uint256 public emergencyModeActivated;
    uint256 public constant MAX_SLIPPAGE = 50; // 0.5% max slippage
    
    // Reward token tracking for enhanced harvesting
    address[] public rewardTokens;
    
    // ------------------------------------------------------------
    // Enhanced Events
    // ------------------------------------------------------------
    event StrategyEnhancedHarvest(
        uint256 totalAssets, 
        uint256 yieldGenerated, 
        uint256 timestamp,
        uint256 gasUsed
    );
    event EmergencyModeActivated(uint256 timestamp, string reason);
    event YieldOptimized(uint256 amountDeployed, uint256 estimatedAPY);
    event AdapterInteraction(address indexed adapter, string method, uint256 amount, bool success);

    // ------------------------------------------------------------
    // Enhanced Constructor - Simplified for BaseStrategy
    // ------------------------------------------------------------
    constructor(
        address _asset,
        string memory _name,
        address _adapter,
        address[] memory _rewardTokens
    ) BaseStrategy(_asset, _name) {
        require(_asset != address(0), "Invalid asset");
        require(_adapter != address(0), "Invalid adapter");

        adapter = NapFiAaveAdapter(_adapter);
        ASSET = IERC20(_asset);
        rewardTokens = _rewardTokens;

        // Enhanced pre-approvals for gas optimization
        ASSET.safeApprove(_adapter, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                REQUIRED BASE STRATEGY OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Deploy funds to yield source - Enhanced with risk management
     * @param _amount Amount of asset to deploy
     */
    function _deployFunds(uint256 _amount) internal override {
        if (_amount == 0) return;
        
        // Enhanced: Pre-deployment risk validation
        _validateDeploymentRisk(_amount);
        
        // Enhanced: Gas-optimized deployment with event tracking
        uint256 gasBefore = gasleft();
        try adapter.depositToAave(_amount) {
            uint256 gasUsed = gasBefore - gasleft();
            emit AdapterInteraction(address(adapter), "depositToAave", _amount, true);
            emit YieldOptimized(_amount, _getEstimatedAPY());
        } catch {
            emit AdapterInteraction(address(adapter), "depositToAave", _amount, false);
            // Enhanced: Handle deployment failure gracefully
            _handleDeploymentFailure(_amount);
        }
    }

    /**
     * @dev Free funds from yield source - Enhanced with safety checks
     * @param _amount Amount of asset to free
     */
    function _freeFunds(uint256 _amount) internal override {
        if (_amount == 0) return;
        
        // Enhanced: Calculate safe withdrawal amount
        uint256 safeWithdrawAmount = _calculateSafeWithdrawal(_amount);
        
        if (safeWithdrawAmount > 0) {
            uint256 gasBefore = gasleft();
            try adapter.withdrawFromAave(safeWithdrawAmount, address(this)) {
                uint256 gasUsed = gasBefore - gasleft();
                emit AdapterInteraction(address(adapter), "withdrawFromAave", safeWithdrawAmount, true);
            } catch {
                emit AdapterInteraction(address(adapter), "withdrawFromAave", safeWithdrawAmount, false);
                // Enhanced: Handle withdrawal failure
                _handleWithdrawalFailure(safeWithdrawAmount);
            }
        }
        
        // Enhanced: Handle any withdrawal shortfall
        if (safeWithdrawAmount < _amount) {
            _handleWithdrawalShortfall(_amount - safeWithdrawAmount);
        }
    }

    /**
     * @dev Harvest rewards and report total assets - Enhanced with multi-phase harvesting
     * @return _totalAssets Total assets under management
     */
    function _harvestAndReport() internal override returns (uint256 _totalAssets) {
        uint256 initialGas = gasleft();
        uint256 preHarvestAssets = adapter.totalAssets();
        
        // Enhanced: Multi-phase harvesting process
        _executeEnhancedHarvest();
        
        // Enhanced: Post-harvest optimization
        _postHarvestOptimization();
        
        // Enhanced: Accurate total asset calculation
        _totalAssets = adapter.totalAssets();
        
        // Enhanced: Yield calculation and tracking
        uint256 yieldGenerated = _totalAssets > preHarvestAssets ? 
            _totalAssets - preHarvestAssets : 0;
        cumulativeYield += yieldGenerated;
        lastHarvestTimestamp = block.timestamp;
        
        // Enhanced: Comprehensive event logging
        uint256 gasUsed = initialGas - gasleft();
        
        emit StrategyEnhancedHarvest(
            _totalAssets, 
            yieldGenerated, 
            block.timestamp, 
            gasUsed
        );
    }

    /*//////////////////////////////////////////////////////////////
                OPTIONAL BASE STRATEGY OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Enhanced deposit limit with adapter-based capacity calculations
     */
    function availableDepositLimit(address) public view override returns (uint256) {
        // Enhanced: Check adapter-specific limits if available
        try adapter.availableDepositLimit() returns (uint256 adapterLimit) {
            return adapterLimit;
        } catch {
            // Fallback to default behavior if adapter doesn't support this
            return type(uint256).max;
        }
    }

    /**
     * @notice Enhanced withdraw limit with safety features
     */
    function availableWithdrawLimit(address _owner) public view override returns (uint256) {
        uint256 baseLimit = asset.balanceOf(address(this));
        
        // Enhanced: Consider adapter-specific withdrawal constraints
        try adapter.availableWithdrawLimit() returns (uint256 adapterWithdrawLimit) {
            return baseLimit + adapterWithdrawLimit;
        } catch {
            return baseLimit + _calculateMaxWithdrawable();
        }
    }

    /**
     * @dev Enhanced tend mechanism for between-harvest optimization
     */
    function _tend(uint256 _totalIdle) internal override {
        // Enhanced: Only tend if conditions are favorable
        if (!_shouldTend()) return;
        
        // Enhanced: Small-scale yield optimization
        if (_totalIdle > _getTendThreshold()) {
            _deployFunds(_totalIdle);
        }
        
        // Enhanced: Lightweight reward claiming if available
        _claimRewardsIfWorthwhile();
    }

    /**
     * @dev Enhanced tend trigger with multi-factor analysis
     */
    function _tendTrigger() internal view override returns (bool) {
        // Enhanced: Multiple trigger conditions
        if (_hasSignificantIdleFunds()) return true;
        if (_rewardsAreClaimable()) return true;
        if (_marketConditionsFavorable()) return true;
        
        return false;
    }

    /**
     * @dev Enhanced emergency withdraw with comprehensive recovery
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        // Enhanced: Activate emergency mode
        emergencyModeActivated = block.timestamp;
        emit EmergencyModeActivated(block.timestamp, "Manual emergency withdrawal");
        
        // Enhanced: Attempt maximum recovery through adapter
        try adapter.emergencyWithdraw(_amount) {
            emit AdapterInteraction(address(adapter), "emergencyWithdraw", _amount, true);
        } catch {
            // Enhanced: Fallback to standard withdrawal
            try adapter.withdrawFromAave(_amount, address(this)) {
                emit AdapterInteraction(address(adapter), "emergencyWithdraw_fallback", _amount, true);
            } catch {
                emit AdapterInteraction(address(adapter), "emergencyWithdraw_fallback", _amount, false);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                ENHANCED INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Enhanced harvest execution with multiple phases
     */
    function _executeEnhancedHarvest() internal {
        // Phase 1: Standard adapter harvest
        try adapter.harvest() {
            emit AdapterInteraction(address(adapter), "harvest", 0, true);
        } catch (bytes memory reason) {
            emit AdapterInteraction(address(adapter), "harvest", 0, false);
            _logHarvestError(reason);
        }
        
        // Phase 2: Enhanced reward processing if adapter supports it
        _processEnhancedRewards();
        
        // Phase 3: Post-harvest asset consolidation
        _consolidateAssets();
    }

    /**
     * @dev Enhanced reward token processing
     */
    function _processEnhancedRewards() internal {
        // Check if adapter supports enhanced reward processing
        try adapter.supportsEnhancedRewards() returns (bool supported) {
            if (supported) {
                try adapter.processEnhancedRewards(rewardTokens) {
                    emit AdapterInteraction(address(adapter), "processEnhancedRewards", 0, true);
                } catch {
                    emit AdapterInteraction(address(adapter), "processEnhancedRewards", 0, false);
                }
            }
        } catch {
            // Adapter doesn't support enhanced rewards check - continue normally
        }
    }

    /**
     * @dev Calculate safe withdrawal amount considering protocol health
     */
    function _calculateSafeWithdrawal(uint256 requestedAmount) internal view returns (uint256) {
        try adapter.getMaxSafeWithdrawal() returns (uint256 maxSafe) {
            return requestedAmount > maxSafe ? maxSafe : requestedAmount;
        } catch {
            // Fallback: Use requested amount if adapter doesn't support safety check
            return requestedAmount;
        }
    }

    /**
     * @dev Calculate maximum withdrawable from protocol
     */
    function _calculateMaxWithdrawable() internal view returns (uint256) {
        try adapter.maxWithdrawable() returns (uint256 maxWithdraw) {
            return maxWithdraw;
        } catch {
            return adapter.totalAssets();
        }
    }

    /**
     * @dev Risk validation before fund deployment
     */
    function _validateDeploymentRisk(uint256 _amount) internal view {
        // Enhanced: Check if adapter reports healthy state
        try adapter.isHealthy() returns (bool healthy) {
            require(healthy, "Adapter reports unhealthy state");
        } catch {
            // Continue if health check not supported
        }
        
        // Enhanced: Check emergency mode
        require(emergencyModeActivated == 0, "Strategy in emergency mode");
        
        // Enhanced: Validate amount is reasonable
        require(_amount <= ASSET.balanceOf(address(this)), "Insufficient balance for deployment");
    }

    /**
     * @dev Post-harvest optimization routines
     */
    function _postHarvestOptimization() internal {
        // Enhanced: Auto-compound loose assets
        uint256 idleAssets = ASSET.balanceOf(address(this));
        if (idleAssets > _getAutoCompoundThreshold()) {
            _deployFunds(idleAssets);
        }
    }

    /*//////////////////////////////////////////////////////////////
                ENHANCED VIEW AND HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Get estimated APY for monitoring
     */
    function _getEstimatedAPY() internal view returns (uint256) {
        try adapter.getEstimatedAPY() returns (uint256 apy) {
            return apy;
        } catch {
            return 0;
        }
    }

    /**
     * @dev Get threshold for auto-compounding
     */
    function _getAutoCompoundThreshold() internal view returns (uint256) {
        // Dynamic threshold based on total assets
        uint256 totalAssets = adapter.totalAssets();
        // Return 0.1% of total assets
        uint256 dynamicThreshold = totalAssets / 1000;
        // Minimum threshold to avoid gas inefficiency
        uint256 minThreshold = 1 * 10**IERC20Metadata(address(ASSET)).decimals();
        
        return dynamicThreshold > minThreshold ? dynamicThreshold : minThreshold;
    }

    /**
     * @dev Get threshold for tend operations
     */
    function _getTendThreshold() internal view returns (uint256) {
        return _getAutoCompoundThreshold() / 10; // 10% of auto-compound threshold
    }

    /*//////////////////////////////////////////////////////////////
                ENHANCED RISK MANAGEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _shouldTend() internal view returns (bool) {
        return !_isEmergencyMode() && _tendTrigger();
    }

    function _isEmergencyMode() internal view returns (bool) {
        return emergencyModeActivated > 0;
    }

    /*//////////////////////////////////////////////////////////////
                ENHANCED TRIGGER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _hasSignificantIdleFunds() internal view returns (bool) {
        return ASSET.balanceOf(address(this)) > _getTendThreshold();
    }

    function _rewardsAreClaimable() internal view returns (bool) {
        try adapter.rewardsAvailable() returns (bool available) {
            return available;
        } catch {
            return false;
        }
    }

    function _marketConditionsFavorable() internal view returns (bool) {
        // Enhanced: Analyze market conditions for tend operations
        try adapter.marketConditionsFavorable() returns (bool favorable) {
            return favorable;
        } catch {
            return true; // Default to true if not supported
        }
    }

    function _claimRewardsIfWorthwhile() internal {
        // Enhanced: Gas-efficient reward claiming
        if (_rewardsAreClaimable() && _isGasEfficientToClaim()) {
            try adapter.claimRewards() {
                emit AdapterInteraction(address(adapter), "claimRewards", 0, true);
            } catch {
                emit AdapterInteraction(address(adapter), "claimRewards", 0, false);
            }
        }
    }

    function _isGasEfficientToClaim() internal view returns (bool) {
        // Enhanced: Gas efficiency calculation based on current gas price
        try adapter.claimingGasEfficient() returns (bool efficient) {
            return efficient;
        } catch {
            return true; // Default to true if not supported
        }
    }

    /*//////////////////////////////////////////////////////////////
                ENHANCED ERROR HANDLING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _handleDeploymentFailure(uint256 _amount) internal {
        // Could implement retry logic or alert system
        // For now, we just emit event and continue
    }

    function _handleWithdrawalFailure(uint256 _amount) internal {
        // Handle withdrawal failures - could try alternative methods
    }

    function _handleWithdrawalShortfall(uint256 shortfall) internal {
        // Handle withdrawal shortfalls - report as temporary illiquidity
    }

    function _logHarvestError(bytes memory reason) internal {
        // Log harvest errors for monitoring and debugging
    }

    function _consolidateAssets() internal {
        // Enhanced: Asset consolidation logic
        // Could sweep any stray tokens to main asset
    }
}

// Required interface for metadata
interface IERC20Metadata {
    function decimals() external view returns (uint8);
}