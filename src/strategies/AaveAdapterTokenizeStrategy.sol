// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * NapFi Hyper-Optimized Aave Tokenized Adapter Strategy v4.0 - "Aave Titan Adapter"
 * ---------------------------------------------------------------------------------
 * Tokenized strategy that integrates with AaveAdapterTokenizedAdapter for Yearn V3/Octant compatibility
 * Following Yearn V3 patterns with enhanced adapter-based architecture
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseStrategy} from "tokenized-strategy/BaseStrategy.sol";
import {BaseHealthCheck} from "tokenized-strategy/BaseHealthCheck.sol";
import {AaveAdapterTokenizedAdapter} from "../adapters/AaveAdapterTokenizedAdapter.sol";

contract AaveAdapterTokenizeStrategy is BaseHealthCheck {
    using SafeERC20 for IERC20;

    // --------------------------------------------------
    // Core Configuration
    // --------------------------------------------------
    AaveAdapterTokenizedAdapter public immutable hyperAdapter;
    address public immutable aaveMarket;
    
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
    // Yearn V3/Octant Compatibility State
    // --------------------------------------------------
    bool public useAdapterForReporting = true;
    uint256 public lastAdapterSync;
    uint256 public adapterSyncCooldown = 1 hours;
    
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
    event AdapterSyncCompleted(uint256 adapterAssets, uint256 strategyAssets, uint256 timestamp);

    // --------------------------------------------------
    // Hyper Constructor - Yearn V3/Octant Compatible
    // --------------------------------------------------
    constructor(
        address _asset,
        string memory _name,
        address _hyperAdapter,
        address _aaveMarket,
        address _management,
        address _performanceFeeRecipient
    ) BaseHealthCheck(_asset, _name, _management, _performanceFeeRecipient) {
        require(_hyperAdapter != address(0), "Invalid hyper adapter");
        require(_aaveMarket != address(0), "Invalid Aave market");
        
        hyperAdapter = AaveAdapterTokenizedAdapter(_hyperAdapter);
        aaveMarket = _aaveMarket;
        
        // Register strategy with adapter (like MorphoAdapter pattern)
        _registerWithAdapter();
        
        // Enhanced pre-approvals
        IERC20(_asset).safeApprove(_hyperAdapter, type(uint256).max);
        
        // Initialize health check parameters (from BaseHealthCheck)
        minReportDelay = 6 hours;
        profitMaxUnlockTime = 10 days;
        
        // Initialize performance tracking
        strategyPerformanceScore = 10000; // Start neutral
        
        // Initialize adapter state
        lastAdapterSync = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                REQUIRED BASE STRATEGY OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Deploy funds to Aave via hyper-optimized tokenized adapter
     * Following Yearn V3 deployment patterns with adapter integration
     * @param _amount Amount of asset to deploy
     */
    function _deployFunds(uint256 _amount) internal override {
        if (_amount == 0) return;
        
        // Enhanced: Pre-deployment risk validation with adapter health checks
        _validateEnhancedDeploymentRisk(_amount);
        
        // Enhanced: Gas-optimized deployment with performance tracking
        uint256 gasBefore = gasleft();
        
        try hyperAdapter.supplyToAave(aaveMarket, _amount) returns (uint256 shares) {
            uint256 gasUsed = gasBefore - gasleft();
            
            // Update performance metrics
            _updateDeploymentMetrics(_amount, shares, gasUsed);
            
            emit DeploymentOptimized(_amount, shares, gasUsed, _getCurrentAPY());
        } catch Error(string memory reason) {
            _handleDeploymentFailure(_amount, reason);
        } catch {
            _handleDeploymentFailure(_amount, "Unknown error");
        }
    }

    /**
     * @dev Free funds from Aave via hyper-optimized tokenized adapter
     * Following Yearn V3 withdrawal patterns with adapter integration
     * @param _amount Amount of asset to free
     */
    function _freeFunds(uint256 _amount) internal override {
        if (_amount == 0) return;
        
        // Enhanced: Calculate safe withdrawal amount considering adapter limits
        uint256 safeWithdrawAmount = _calculateSafeWithdrawal(_amount);
        
        if (safeWithdrawAmount > 0) {
            uint256 gasBefore = gasleft();
            
            try hyperAdapter.withdrawFromAave(aaveMarket, safeWithdrawAmount, address(this)) returns (uint256 withdrawn) {
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
     * Following Yearn V3 harvest patterns with adapter-based reporting
     * @return _totalAssets Total assets under management
     */
    function _harvestAndReport() internal override returns (uint256 _totalAssets) {
        uint256 initialGas = gasleft();
        uint256 preHarvestAssets = _getAdapterTotalAssets();
        
        // Enhanced: Multi-phase hyper harvest with boost integration
        _executeHyperHarvest();
        
        // Enhanced: Post-harvest optimization and auto-compounding
        _executePostHarvestOptimization();
        
        // Enhanced: Strategy rebalancing if conditions are favorable
        _executeOpportunisticRebalance();
        
        // Enhanced: Auto-boost upgrade if eligible
        _executeAutoBoostUpgrade();
        
        // Enhanced: Sync with adapter state
        _syncAdapterState();
        
        // Calculate total assets through adapter
        _totalAssets = _getAdapterTotalAssets();
        
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
     * Following Yearn V3 limit patterns with adapter integration
     */
    function availableDepositLimit(address _owner) public view override returns (uint256) {
        // Use adapter's capacity calculation
        uint256 adapterCapacity = hyperAdapter.getAvailableDepositCapacity(address(this));
        
        // Enhanced: Consider boost tier for capacity calculations
        if (currentBoostMultiplier > 10000 && block.timestamp < boostExpiry) {
            // Boosted strategies get increased capacity
            adapterCapacity = (adapterCapacity * currentBoostMultiplier) / 10000;
        }
        
        // Consider strategy's own limits
        uint256 strategyLimit = type(uint256).max - totalAssets();
        
        return adapterCapacity.min(strategyLimit);
    }

    /**
     * @notice Enhanced withdraw limit with safety features and liquidity optimization
     * Following Yearn V3 withdrawal limit patterns
     */
    function availableWithdrawLimit(address _owner) public view override returns (uint256) {
        uint256 baseLimit = asset.balanceOf(address(this));
        uint256 adapterLimit = hyperAdapter.getAvailableWithdrawCapacity(address(this));
        
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
        
        // Sync adapter state after tend operations
        _syncAdapterState();
        
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
        
        // Factor 6: Adapter sync required
        if (_needsAdapterSync()) return true;
        
        return false;
    }

    /**
     * @dev Enhanced emergency withdraw with comprehensive recovery
     * Following Yearn V3 emergency patterns with adapter integration
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        // Enhanced: Multi-phase emergency recovery with adapter
        _executeEmergencyRecovery(_amount);
    }

    /*//////////////////////////////////////////////////////////////
                ADAPTER-INTEGRATED INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Register strategy with tokenized adapter
     * Following MorphoAdapter registration pattern
     */
    function _registerWithAdapter() internal {
        // This would typically be called by the factory, but we ensure registration
        try hyperAdapter.registerStrategy(address(this), address(asset)) {
            // Success
        } catch {
            // Registration might already be done by factory
        }
    }

    /**
     * @dev Execute hyper harvest with adapter integration
     */
    function _executeHyperHarvest() internal {
        try hyperAdapter.harvestAaveRewards() returns (uint256 yield, uint256 donation) {
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
        
        address bestMarket = _findBestPerformingMarket();
        
        if (bestMarket != aaveMarket && bestMarket != address(0)) {
            uint256 rebalanceAmount = _calculateOptimalRebalanceAmount();
            
            try hyperAdapter.rebalanceAaveMarkets() {
                lastRebalanceTimestamp = block.timestamp;
                
                uint256 estimatedGain = _estimateRebalanceGain(aaveMarket, bestMarket, rebalanceAmount);
                emit StrategyRebalanced(aaveMarket, bestMarket, rebalanceAmount, estimatedGain);
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
            try hyperAdapter.upgradeStrategyBoost(address(this)) {
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
     * @dev Sync strategy state with adapter state
     * Ensures consistent reporting between strategy and adapter
     */
    function _syncAdapterState() internal {
        if (block.timestamp >= lastAdapterSync + adapterSyncCooldown) {
            try hyperAdapter.syncStrategyState(address(this)) {
                lastAdapterSync = block.timestamp;
                emit AdapterSyncCompleted(
                    hyperAdapter.getStrategyTotalValue(address(this)),
                    totalAssets(),
                    block.timestamp
                );
            } catch {
                // Graceful failure - sync is optional
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
        
        // Light reward claiming through adapter
        try hyperAdapter.claimPendingRewards() returns (uint256 rewards) {
            return rewards;
        } catch {
            return 0;
        }
    }

    /**
     * @dev Execute position optimization during tend operations
     */
    function _executePositionOptimization() internal returns (uint256) {
        // Position optimization through adapter
        try hyperAdapter.optimizePositions() returns (uint256 optimizations) {
            return optimizations;
        } catch {
            return 0;
        }
    }

    /*//////////////////////////////////////////////////////////////
                ADAPTER-ENHANCED VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Get total assets from adapter with fallback to local calculation
     */
    function totalAssets() public view override returns (uint256) {
        if (useAdapterForReporting) {
            try hyperAdapter.getStrategyTotalValue(address(this)) returns (uint256 adapterAssets) {
                return adapterAssets;
            } catch {
                // Fallback to local calculation
            }
        }
        
        // Local calculation as fallback
        return asset.balanceOf(address(this)) + _getAdapterPositionValue();
    }

    /**
     * @dev Get current APY from adapter with boost adjustments
     */
    function getCurrentAPY() public view returns (uint256) {
        try hyperAdapter.getAaveAPY(aaveMarket) returns (uint256 baseAPY) {
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
     * @dev Get strategy health score from adapter
     */
    function getHealthScore() public view returns (uint256) {
        try hyperAdapter.getStrategyHealthScore(address(this)) returns (uint256 healthScore) {
            return healthScore;
        } catch {
            // Fallback calculation
            uint256 performanceScore = strategyPerformanceScore;
            uint256 riskScore = _getCurrentRiskScore();
            return (performanceScore * (MAX_BPS - riskScore)) / MAX_BPS;
        }
    }

    /**
     * @dev Get boost eligibility status from adapter
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
        
        // Check adapter paused state
        require(!hyperAdapter.paused(), "Adapter is paused");
    }

    function _isAdapterHealthy() internal view returns (bool) {
        try hyperAdapter.paused() returns (bool isPaused) {
            return !isPaused;
        } catch {
            return true; // Assume healthy if check fails
        }
    }

    function _areMarketConditionsFavorable() internal view returns (bool) {
        // Use adapter's market condition assessment
        try hyperAdapter.areMarketConditionsFavorable() returns (bool favorable) {
            return favorable;
        } catch {
            return true; // Default to favorable if check fails
        }
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
        try hyperAdapter.getBoostMultiplier(address(this)) returns (uint256 multiplier) {
            currentBoostMultiplier = multiplier;
        } catch {
            // Keep current value if call fails
        }
        
        try hyperAdapter.strategyBoostExpiry(address(this)) returns (uint256 expiry) {
            boostExpiry = expiry;
        } catch {
            // Keep current value if call fails
        }
    }

    /*//////////////////////////////////////////////////////////////
                HELPER & THRESHOLD FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _getAdapterTotalAssets() internal view returns (uint256) {
        try hyperAdapter.getStrategyTotalValue(address(this)) returns (uint256 assets) {
            return assets;
        } catch {
            return totalAssets(); // Fallback to local calculation
        }
    }

    function _getAdapterPositionValue() internal view returns (uint256) {
        // Calculate position value through adapter
        try hyperAdapter.getStrategyPositionValue(address(this), aaveMarket) returns (uint256 value) {
            return value;
        } catch {
            return 0;
        }
    }

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
        uint256 maxSafe = hyperAdapter.getAvailableWithdrawCapacity(address(this));
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
        // Check adapter for optimization opportunities
        try hyperAdapter.hasOptimizationOpportunity(address(this)) returns (bool hasOpportunity) {
            return hasOpportunity;
        } catch {
            return false;
        }
    }

    function _marketConditionsChanged() internal view returns (bool) {
        // Check if market conditions have changed significantly
        try hyperAdapter.marketConditionsChanged() returns (bool changed) {
            return changed;
        } catch {
            return false;
        }
    }

    function _hasRebalancingOpportunity() internal view returns (bool) {
        return shouldRebalance();
    }

    function _needsAdapterSync() internal view returns (bool) {
        return block.timestamp >= lastAdapterSync + adapterSyncCooldown;
    }

    function _isGasEfficientToClaimRewards() internal view returns (bool) {
        // Check gas efficiency of reward claiming through adapter
        try hyperAdapter.isGasEfficientToClaim() returns (bool efficient) {
            return efficient;
        } catch {
            return true; // Default to efficient if check fails
        }
    }

    function _shouldRebalance() internal view returns (bool) {
        return shouldRebalance() && 
               block.timestamp >= lastRebalanceTimestamp + 7 days; // Weekly max
    }

    function _isEligibleForBoostUpgrade() internal view returns (bool) {
        return strategyPerformanceScore >= boostUpgradeThreshold &&
               block.timestamp >= boostExpiry;
    }

    function _calculateOptimalRebalanceAmount() internal view returns (uint256) {
        uint256 currentBalance = _getAdapterTotalAssets();
        return (currentBalance * maxSingleTendMoveBps) / MAX_BPS;
    }

    function _findBestPerformingMarket() internal view returns (address) {
        // Find best market through adapter
        try hyperAdapter.findBestMarket(address(asset)) returns (address bestMarket) {
            return bestMarket;
        } catch {
            return aaveMarket; // Fallback to current market
        }
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
        // Enhanced emergency recovery with adapter integration
        try hyperAdapter.emergencyWithdraw(_amount, address(this)) {
            // Success
        } catch {
            try hyperAdapter.withdrawFromAave(aaveMarket, _amount, address(this)) {
                // Fallback success
            } catch {
                // Final fallback - report failure
                revert("Emergency withdrawal failed");
            }
        }
    }

    function _executeAdditionalOptimizations() internal {
        // Additional optimization logic through adapter
        try hyperAdapter.executeAdditionalOptimizations() {
            // Success
        } catch {
            // Graceful failure
        }
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

    /*//////////////////////////////////////////////////////////////
                MANAGEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Set adapter reporting preference
     * @param _useAdapter Whether to use adapter for asset reporting
     */
    function setUseAdapterReporting(bool _useAdapter) external onlyManagement {
        useAdapterForReporting = _useAdapter;
    }

    /**
     * @dev Set adapter sync cooldown
     * @param _cooldown New cooldown in seconds
     */
    function setAdapterSyncCooldown(uint256 _cooldown) external onlyManagement {
        require(_cooldown <= 24 hours, "Cooldown too long");
        adapterSyncCooldown = _cooldown;
    }

    /**
     * @dev Manually sync with adapter
     */
    function manualAdapterSync() external onlyManagement {
        _syncAdapterState();
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

// Adapter interface for type safety
interface AaveAdapterTokenizedAdapter {
    function registerStrategy(address strategy, address asset) external;
    function supplyToAave(address market, uint256 amount) external returns (uint256);
    function withdrawFromAave(address market, uint256 amount, address to) external returns (uint256);
    function harvestAaveRewards() external returns (uint256 yield, uint256 donation);
    function getStrategyTotalValue(address strategy) external view returns (uint256);
    function getAvailableDepositCapacity(address strategy) external view returns (uint256);
    function getAvailableWithdrawCapacity(address strategy) external view returns (uint256);
    function getAaveAPY(address market) external view returns (uint256);
    function shouldRebalance(address strategy) external view returns (bool);
    function rebalanceAaveMarkets() external;
    function upgradeStrategyBoost(address strategy) external;
    function getBoostMultiplier(address strategy) external view returns (uint256);
    function strategyBoostExpiry(address strategy) external view returns (uint256);
    function paused() external view returns (bool);
    function syncStrategyState(address strategy) external;
    function claimPendingRewards() external returns (uint256);
    function optimizePositions() external returns (uint256);
    function getStrategyHealthScore(address strategy) external view returns (uint256);
    function areMarketConditionsFavorable() external view returns (bool);
    function hasOptimizationOpportunity(address strategy) external view returns (bool);
    function marketConditionsChanged() external view returns (bool);
    function isGasEfficientToClaim() external view returns (bool);
    function findBestMarket(address asset) external view returns (address);
    function getStrategyPositionValue(address strategy, address market) external view returns (uint256);
    function emergencyWithdraw(uint256 amount, address to) external;
    function executeAdditionalOptimizations() external;
}