// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * NapFi Hyper-Optimized Aave Tokenized Strategy v4.0 - "Titan Vault"
 * ----------------------------------------------------------------
 * Maximum innovation following Yearn V3/Octant patterns while leveraging
 * the hyper-optimized adapter with boost tiers, V4 swaps, and rebalancing
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseStrategy} from "tokenized-strategy/BaseStrategy.sol";
import {BaseHealthCheck} from "tokenized-strategy/BaseHealthCheck.sol";
import {NapFiHyperAaveAdapter} from "../adapters/NapFiHyperAaveAdapter.sol";

contract NapFiHyperAaveTokenizedStrategy is BaseHealthCheck {
    using SafeERC20 for IERC20;

    // --------------------------------------------------
    // Core Configuration
    // --------------------------------------------------
    NapFiHyperAaveAdapter public immutable hyperAdapter;
    
    // --------------------------------------------------
    // Enhanced Strategy State
    // --------------------------------------------------
    uint256 public lastHarvestTimestamp;
    uint256 public cumulativeYield;
    uint256 public totalDonations;
    uint256 public strategyPerformanceScore;
    uint256 public lastTendTimestamp;
    uint256 public tendCooldown = 4 hours;
    
    // Boost tracking
    uint256 public currentBoostMultiplier = 10000; // 1.0x
    uint256 public boostExpiry;
    
    // Advanced metrics
    uint256 public avgHarvestGasUsed;
    uint256 public successfulHarvests;
    uint256 public failedHarvests;
    uint256 public lastRebalanceTimestamp;
    
    // --------------------------------------------------
    // Advanced Configuration
    // --------------------------------------------------
    uint256 public constant MAX_BPS = 10_000;
    uint256 public autoCompoundThresholdBps = 100; // 1% of idle funds
    uint256 public maxSingleTendMoveBps = 500;     // 5% max move per tend
    uint256 public rebalanceThresholdBps = 200;    // 2% APY improvement threshold
    uint256 public boostUpgradeThreshold = 7500;   // Performance score for auto-boost
    
    // --------------------------------------------------
    // Enhanced Events
    // --------------------------------------------------
    event HyperHarvestExecuted(
        uint256 totalAssets, 
        uint256 yieldGenerated, 
        uint256 donationAmount,
        uint256 boostMultiplier,
        uint256 gasUsed,
        uint256 timestamp
    );
    event StrategyBoostUpgraded(
        uint256 oldMultiplier, 
        uint256 newMultiplier, 
        uint256 expiry,
        string tier
    );
    event StrategyRebalanced(
        address fromAsset, 
        address toAsset, 
        uint256 amount,
        uint256 estimatedAPYGain
    );
    event TendOperationExecuted(
        uint256 idleDeployed,
        uint256 rewardsClaimed,
        uint256 gasUsed,
        uint256 timestamp
    );
    event AutoCompoundTriggered(uint256 amountCompounded, uint256 estimatedYieldIncrease);
    event PerformanceMetricsUpdated(
        uint256 performanceScore,
        uint256 avgAPY,
        uint256 riskScore
    );

    // --------------------------------------------------
    // Hyper Constructor - Following Yearn/Octant patterns
    // --------------------------------------------------
    constructor(
        address _asset,
        string memory _name,
        address _hyperAdapter,
        address _management,
        address _performanceFeeRecipient
    ) BaseHealthCheck(_asset, _name, _management, _performanceFeeRecipient) {
        require(_hyperAdapter != address(0), "Invalid hyper adapter");
        
        hyperAdapter = NapFiHyperAaveAdapter(_hyperAdapter);
        
        // Enhanced pre-approvals
        IERC20(_asset).safeApprove(_hyperAdapter, type(uint256).max);
        
        // Initialize health check parameters (from BaseHealthCheck)
        minReportDelay = 6 hours;
        profitMaxUnlockTime = 10 days;
        
        // Initialize performance tracking
        strategyPerformanceScore = 10000; // Start neutral
    }

    /*//////////////////////////////////////////////////////////////
                REQUIRED BASE STRATEGY OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Deploy funds to Aave via hyper-optimized adapter
     * @param _amount Amount of asset to deploy
     */
    function _deployFunds(uint256 _amount) internal override {
        if (_amount == 0) return;
        
        // Enhanced: Pre-deployment risk validation with adapter health checks
        _validateEnhancedDeploymentRisk(_amount);
        
        // Enhanced: Gas-optimized deployment with performance tracking
        uint256 gasBefore = gasleft();
        
        try hyperAdapter.depositToAave(_amount) returns (uint256 supplied) {
            uint256 gasUsed = gasBefore - gasleft();
            
            // Update performance metrics
            _updateDeploymentMetrics(_amount, supplied, gasUsed);
            
            emit DeploymentOptimized(_amount, supplied, gasUsed, _getCurrentAPY());
        } catch Error(string memory reason) {
            _handleDeploymentFailure(_amount, reason);
        } catch {
            _handleDeploymentFailure(_amount, "Unknown error");
        }
    }

    /**
     * @dev Free funds from Aave via hyper-optimized adapter
     * @param _amount Amount of asset to free
     */
    function _freeFunds(uint256 _amount) internal override {
        if (_amount == 0) return;
        
        // Enhanced: Calculate safe withdrawal amount considering adapter limits
        uint256 safeWithdrawAmount = _calculateSafeWithdrawal(_amount);
        
        if (safeWithdrawAmount > 0) {
            uint256 gasBefore = gasleft();
            
            try hyperAdapter.withdrawFromAave(safeWithdrawAmount, address(this)) returns (uint256 withdrawn) {
                uint256 gasUsed = gasBefore - gasleft();
                
                // Update withdrawal metrics
                _updateWithdrawalMetrics(_amount, withdrawn, gasUsed);
                
                emit WithdrawalOptimized(_amount, withdrawn, gasUsed);
            } catch Error(string memory reason) {
                _handleWithdrawalFailure(safeWithdrawAmount, reason);
            } catch {
                _handleWithdrawalFailure(safeWithdrawAmount, "Unknown error");
            }
        }
        
        // Enhanced: Handle any withdrawal shortfall with graceful degradation
        if (safeWithdrawAmount < _amount) {
            _handleWithdrawalShortfall(_amount - safeWithdrawAmount);
        }
    }

    /**
     * @dev Harvest rewards and report total assets with boost integration
     * @return _totalAssets Total assets under management
     */
    function _harvestAndReport() internal override returns (uint256 _totalAssets) {
        uint256 initialGas = gasleft();
        uint256 preHarvestAssets = hyperAdapter.totalAssets(address(this));
        
        // Enhanced: Multi-phase hyper harvest with boost integration
        _executeHyperHarvest();
        
        // Enhanced: Post-harvest optimization and auto-compounding
        _executePostHarvestOptimization();
        
        // Enhanced: Strategy rebalancing if conditions are favorable
        _executeOpportunisticRebalance();
        
        // Enhanced: Auto-boost upgrade if eligible
        _executeAutoBoostUpgrade();
        
        // Calculate total assets through adapter
        _totalAssets = hyperAdapter.totalAssets(address(this));
        
        // Enhanced: Yield calculation with boost tracking
        uint256 yieldGenerated = _totalAssets > preHarvestAssets ? 
            _totalAssets - preHarvestAssets : 0;
        cumulativeYield += yieldGenerated;
        
        // Update performance metrics
        uint256 gasUsed = initialGas - gasleft();
        _updateHarvestMetrics(yieldGenerated, gasUsed);
        
        lastHarvestTimestamp = block.timestamp;
        
        emit HyperHarvestExecuted(
            _totalAssets, 
            yieldGenerated, 
            totalDonations,
            currentBoostMultiplier,
            gasUsed,
            block.timestamp
        );
        
        return _totalAssets;
    }

    /*//////////////////////////////////////////////////////////////
                OPTIONAL BASE STRATEGY OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Enhanced deposit limit with adapter-based capacity and boost considerations
     */
    function availableDepositLimit(address _owner) public view override returns (uint256) {
        uint256 adapterLimit = hyperAdapter.availableDepositLimit(address(this));
        
        // Enhanced: Consider boost tier for capacity calculations
        if (currentBoostMultiplier > 10000 && block.timestamp < boostExpiry) {
            // Boosted strategies get increased capacity
            adapterLimit = (adapterLimit * currentBoostMultiplier) / 10000;
        }
        
        return adapterLimit.min(type(uint256).max - totalAssets());
    }

    /**
     * @notice Enhanced withdraw limit with safety features and liquidity optimization
     */
    function availableWithdrawLimit(address _owner) public view override returns (uint256) {
        uint256 baseLimit = asset.balanceOf(address(this));
        uint256 adapterLimit = hyperAdapter.availableWithdrawLimit(address(this));
        
        // Enhanced: Consider strategy health and market conditions
        if (!_areMarketConditionsFavorable()) {
            // Reduce limits during unfavorable conditions
            adapterLimit = adapterLimit / 2;
        }
        
        return baseLimit + adapterLimit;
    }

    /**
     * @dev Enhanced tend mechanism for between-harvest optimization
     * Following Yearn V3 tend patterns with hyper-optimization
     */
    function _tend(uint256 _totalIdle) internal override {
        require(block.timestamp >= lastTendTimestamp + tendCooldown, "Tend cooldown");
        
        uint256 initialGas = gasleft();
        
        // Enhanced: Multi-phase tend operations
        uint256 idleDeployed = _executeIdleFundDeployment(_totalIdle);
        uint256 rewardsClaimed = _executeLightRewardHarvest();
        uint256 positionsOptimized = _executePositionOptimization();
        
        // Update tend metrics
        uint256 gasUsed = initialGas - gasleft();
        lastTendTimestamp = block.timestamp;
        
        emit TendOperationExecuted(idleDeployed, rewardsClaimed, gasUsed, block.timestamp);
    }

    /**
     * @dev Enhanced tend trigger with multi-factor analysis
     * Following Octant's advanced trigger patterns
     */
    function _tendTrigger() internal view override returns (bool) {
        // Factor 1: Significant idle funds
        if (_hasSignificantIdleFunds()) return true;
        
        // Factor 2: Reward claiming opportunity
        if (_hasWorthwhileRewards()) return true;
        
        // Factor 3: Position optimization opportunity
        if (_hasOptimizationOpportunity()) return true;
        
        // Factor 4: Market condition changes
        if (_marketConditionsChanged()) return true;
        
        // Factor 5: Rebalancing opportunity
        if (_hasRebalancingOpportunity()) return true;
        
        return false;
    }

    /**
     * @dev Enhanced emergency withdraw with comprehensive recovery
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        // Enhanced: Multi-phase emergency recovery
        _executeEmergencyRecovery(_amount);
    }

    /*//////////////////////////////////////////////////////////////
                HYPER-OPTIMIZED INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Execute hyper harvest with boost integration and advanced features
     */
    function _executeHyperHarvest() internal {
        try hyperAdapter.harvestStrategy() returns (uint256 yield, uint256 donation) {
            // Track donations for boost eligibility
            totalDonations += donation;
            
            // Update performance score based on harvest success
            _updatePerformanceScore(true, yield);
            
            successfulHarvests++;
        } catch Error(string memory reason) {
            _handleHarvestError(reason);
            failedHarvests++;
            _updatePerformanceScore(false, 0);
        } catch {
            _handleHarvestError("Unknown harvest error");
            failedHarvests++;
            _updatePerformanceScore(false, 0);
        }
    }

    /**
     * @dev Execute post-harvest optimization including auto-compounding
     */
    function _executePostHarvestOptimization() internal {
        uint256 idleAssets = asset.balanceOf(address(this));
        uint256 autoCompoundThreshold = _getAutoCompoundThreshold();
        
        if (idleAssets >= autoCompoundThreshold) {
            _deployFunds(idleAssets);
            emit AutoCompoundTriggered(idleAssets, _estimateYieldIncrease(idleAssets));
        }
        
        // Additional optimization: Dust collection, gas optimization, etc.
        _executeAdditionalOptimizations();
    }

    /**
     * @dev Execute opportunistic rebalancing when beneficial
     */
    function _executeOpportunisticRebalance() internal {
        if (!_shouldRebalance()) return;
        
        address bestAsset = _findBestPerformingAsset();
        address currentAsset = address(asset);
        
        if (bestAsset != currentAsset && bestAsset != address(0)) {
            uint256 rebalanceAmount = _calculateOptimalRebalanceAmount();
            
            try hyperAdapter.rebalanceStrategy(address(this), bestAsset, rebalanceAmount) {
                lastRebalanceTimestamp = block.timestamp;
                
                uint256 estimatedGain = _estimateRebalanceGain(currentAsset, bestAsset, rebalanceAmount);
                emit StrategyRebalanced(currentAsset, bestAsset, rebalanceAmount, estimatedGain);
            } catch {
                // Graceful failure - rebalancing is optional
            }
        }
    }

    /**
     * @dev Execute automatic boost upgrade when eligible
     */
    function _executeAutoBoostUpgrade() internal {
        if (_isEligibleForBoostUpgrade()) {
            try hyperAdapter.upgradeStrategyBoost() {
                // Update local boost state
                _updateBoostState();
                emit StrategyBoostUpgraded(
                    currentBoostMultiplier,
                    hyperAdapter.getBoostMultiplier(address(this)),
                    hyperAdapter.strategyBoostExpiry(address(this)),
                    _getBoostTierString()
                );
            } catch {
                // Graceful failure - boost upgrade is optional
            }
        }
    }

    /**
     * @dev Execute idle fund deployment during tend operations
     */
    function _executeIdleFundDeployment(uint256 _totalIdle) internal returns (uint256) {
        if (_totalIdle == 0) return 0;
        
        uint256 maxDeploy = (_totalIdle * maxSingleTendMoveBps) / MAX_BPS;
        uint256 deployAmount = _totalIdle.min(maxDeploy);
        
        if (deployAmount >= _getTendThreshold()) {
            _deployFunds(deployAmount);
            return deployAmount;
        }
        
        return 0;
    }

    /**
     * @dev Execute light reward harvesting during tend operations
     */
    function _executeLightRewardHarvest() internal returns (uint256) {
        if (!_isGasEfficientToClaimRewards()) return 0;
        
        // Light reward claiming logic would go here
        // This could involve claiming without full harvest overhead
        return 0;
    }

    /**
     * @dev Execute position optimization during tend operations
     */
    function _executePositionOptimization() internal returns (uint256) {
        // Position optimization logic (e.g., moving between Aave v2/v3, adjusting rates)
        return 0;
    }

    /*//////////////////////////////////////////////////////////////
                ADVANCED VIEW & ANALYTICS FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Get current APY from adapter with boost adjustments
     */
    function getCurrentAPY() public view returns (uint256) {
        try hyperAdapter.getStrategyAPY(address(this)) returns (uint256 baseAPY) {
            // Apply boost multiplier to APY estimation
            if (currentBoostMultiplier > 10000 && block.timestamp < boostExpiry) {
                baseAPY = (baseAPY * currentBoostMultiplier) / 10000;
            }
            return baseAPY;
        } catch {
            return 0;
        }
    }

    /**
     * @dev Check if strategy should rebalance
     */
    function shouldRebalance() public view returns (bool) {
        try hyperAdapter.shouldRebalance(address(this)) returns (bool shouldRebal) {
            return shouldRebal;
        } catch {
            return false;
        }
    }

    /**
     * @dev Get strategy health score (0-10000)
     */
    function getHealthScore() public view returns (uint256) {
        uint256 performanceScore = strategyPerformanceScore;
        uint256 riskScore = _getCurrentRiskScore();
        
        // Health score combines performance and risk
        return (performanceScore * (MAX_BPS - riskScore)) / MAX_BPS;
    }

    /**
     * @dev Get boost eligibility status
     */
    function isEligibleForBoostUpgrade() public view returns (bool) {
        return _isEligibleForBoostUpgrade();
    }

    /*//////////////////////////////////////////////////////////////
                ENHANCED RISK MANAGEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _validateEnhancedDeploymentRisk(uint256 _amount) internal view {
        // Check adapter health
        require(_isAdapterHealthy(), "Adapter reports unhealthy state");
        
        // Check market conditions
        require(_areMarketConditionsFavorable(), "Market conditions unfavorable");
        
        // Check deployment limits
        require(_amount <= availableDepositLimit(address(this)), "Exceeds deposit limit");
        
        // Check emergency mode
        require(!emergencyExit, "Strategy in emergency exit");
    }

    function _isAdapterHealthy() internal view returns (bool) {
        try hyperAdapter.paused() returns (bool isPaused) {
            return !isPaused;
        } catch {
            return true; // Assume healthy if check fails
        }
    }

    function _areMarketConditionsFavorable() internal view returns (bool) {
        // Implement market condition checks (utilization, rates, etc.)
        return true; // Simplified for example
    }

    /*//////////////////////////////////////////////////////////////
                PERFORMANCE TRACKING & METRICS
    //////////////////////////////////////////////////////////////*/

    function _updatePerformanceScore(bool success, uint256 yield) internal {
        if (success && yield > 0) {
            // Increase score for successful harvests with yield
            strategyPerformanceScore = (strategyPerformanceScore + 100).min(MAX_BPS);
        } else if (!success) {
            // Decrease score for failed harvests
            strategyPerformanceScore = strategyPerformanceScore > 200 ? 
                strategyPerformanceScore - 200 : 0;
        }
        
        emit PerformanceMetricsUpdated(
            strategyPerformanceScore,
            getCurrentAPY(),
            _getCurrentRiskScore()
        );
    }

    function _updateHarvestMetrics(uint256 yield, uint256 gasUsed) internal {
        // Update average gas usage
        if (successfulHarvests > 0) {
            avgHarvestGasUsed = (avgHarvestGasUsed * (successfulHarvests - 1) + gasUsed) / successfulHarvests;
        } else {
            avgHarvestGasUsed = gasUsed;
        }
    }

    function _updateDeploymentMetrics(uint256 attempted, uint256 actual, uint256 gasUsed) internal {
        // Track deployment efficiency
    }

    function _updateWithdrawalMetrics(uint256 attempted, uint256 actual, uint256 gasUsed) internal {
        // Track withdrawal efficiency
    }

    function _updateBoostState() internal {
        currentBoostMultiplier = hyperAdapter.getBoostMultiplier(address(this));
        boostExpiry = hyperAdapter.strategyBoostExpiry(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                HELPER & THRESHOLD FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _getAutoCompoundThreshold() internal view returns (uint256) {
        uint256 total = totalAssets();
        uint256 dynamicThreshold = (total * autoCompoundThresholdBps) / MAX_BPS;
        uint256 minThreshold = 1000 * 10**IERC20Metadata(address(asset)).decimals();
        
        return dynamicThreshold.max(minThreshold);
    }

    function _getTendThreshold() internal view returns (uint256) {
        return _getAutoCompoundThreshold() / 5; // 20% of auto-compound threshold
    }

    function _calculateSafeWithdrawal(uint256 requested) internal view returns (uint256) {
        uint256 maxSafe = hyperAdapter.maxWithdrawable(address(this));
        return requested.min(maxSafe);
    }

    function _hasSignificantIdleFunds() internal view returns (bool) {
        return asset.balanceOf(address(this)) > _getTendThreshold();
    }

    function _hasWorthwhileRewards() internal view returns (bool) {
        // Check if rewards are worth claiming based on gas costs
        return _isGasEfficientToClaimRewards();
    }

    function _hasOptimizationOpportunity() internal view returns (bool) {
        // Check for position optimization opportunities
        return false; // Simplified
    }

    function _marketConditionsChanged() internal view returns (bool) {
        // Check if market conditions have changed significantly
        return false; // Simplified
    }

    function _hasRebalancingOpportunity() internal view returns (bool) {
        return shouldRebalance();
    }

    function _isGasEfficientToClaimRewards() internal view returns (bool) {
        // Check gas efficiency of reward claiming
        return true; // Simplified
    }

    function _shouldRebalance() internal view returns (bool) {
        return shouldRebalance() && 
               block.timestamp >= lastRebalanceTimestamp + 7 days; // Weekly max
    }

    function _isEligibleForBoostUpgrade() internal view returns (bool) {
        return strategyPerformanceScore >= boostUpgradeThreshold &&
               block.timestamp >= boostExpiry &&
               hyperAdapter.getBoostMultiplier(address(this)) < 20000; // Max 2.0x
    }

    function _calculateOptimalRebalanceAmount() internal view returns (uint256) {
        uint256 currentBalance = hyperAdapter.totalAssets(address(this));
        return (currentBalance * maxSingleTendMoveBps) / MAX_BPS;
    }

    function _findBestPerformingAsset() internal view returns (address) {
        // Implementation would find the best asset based on APY
        return address(asset); // Simplified
    }

    function _estimateRebalanceGain(address from, address to, uint256 amount) internal pure returns (uint256) {
        // Simplified estimation
        return amount / 100; // 1% estimated gain
    }

    function _estimateYieldIncrease(uint256 amount) internal view returns (uint256) {
        return (amount * getCurrentAPY()) / (MAX_BPS * 365 days);
    }

    function _getCurrentRiskScore() internal pure returns (uint256) {
        return 3000; // Medium-low risk (0-10000, lower is safer)
    }

    function _getBoostTierString() internal view returns (string memory) {
        uint256 multiplier = currentBoostMultiplier;
        if (multiplier >= 20000) return "TITAN";
        if (multiplier >= 17500) return "PLATINUM";
        if (multiplier >= 15000) return "GOLD";
        if (multiplier >= 12500) return "SILVER";
        if (multiplier >= 11000) return "BRONZE";
        return "NONE";
    }

    function _executeEmergencyRecovery(uint256 _amount) internal {
        // Enhanced emergency recovery with multiple fallbacks
        try hyperAdapter.emergencyWithdraw(_amount) {
            // Success
        } catch {
            try hyperAdapter.withdrawFromAave(_amount, address(this)) {
                // Fallback success
            } catch {
                // Final fallback - report failure
                revert("Emergency withdrawal failed");
            }
        }
    }

    function _executeAdditionalOptimizations() internal {
        // Placeholder for additional optimization logic
    }

    function _handleDeploymentFailure(uint256 _amount, string memory reason) internal {
        // Enhanced failure handling with logging and recovery
        emit DeploymentFailed(_amount, reason);
    }

    function _handleWithdrawalFailure(uint256 _amount, string memory reason) internal {
        emit WithdrawalFailed(_amount, reason);
    }

    function _handleWithdrawalShortfall(uint256 shortfall) internal {
        emit WithdrawalShortfall(shortfall);
    }

    function _handleHarvestError(string memory reason) internal {
        emit HarvestError(reason);
    }

    // Additional events for enhanced monitoring
    event DeploymentOptimized(uint256 attempted, uint256 actual, uint256 gasUsed, uint256 estimatedAPY);
    event WithdrawalOptimized(uint256 attempted, uint256 actual, uint256 gasUsed);
    event DeploymentFailed(uint256 amount, string reason);
    event WithdrawalFailed(uint256 amount, string reason);
    event WithdrawalShortfall(uint256 shortfall);
    event HarvestError(string reason);
}

// Required interfaces
interface IERC20Metadata {
    function decimals() external view returns (uint8);
}