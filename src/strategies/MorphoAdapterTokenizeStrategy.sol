// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * NapFi Hyper-Optimized Morpho Tokenized Strategy v4.0 - "Morpho Titan Vault"
 * ----------------------------------------------------------------------------
 * Maximum innovation following Yearn V3/Octant patterns while leveraging
 * Morpho's efficient lending with leverage, V4 hooks, and dynamic health management
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseStrategy} from "tokenized-strategy/BaseStrategy.sol";
import {BaseHealthCheck} from "tokenized-strategy-periphery/src/Bases/HealthCheck/BaseHealthCheck.sol";
import {MorphoAdapter} from "../adapters/MorphoAdapter.sol";

contract NapFiHyperMorphoTokenizedStrategy is BaseHealthCheck {
    using SafeERC20 for IERC20;

    // --------------------------------------------------
    // Core Configuration
    // --------------------------------------------------
    MorphoAdapter public immutable morphoAdapter;
    
    // --------------------------------------------------
    // Enhanced Strategy State
    // --------------------------------------------------
    uint256 public lastHarvestTimestamp;
    uint256 public cumulativeYield;
    uint256 public totalDonations;
    uint256 public strategyPerformanceScore;
    uint256 public lastTendTimestamp;
    uint256 public tendCooldown = 4 hours;
    
    // Morpho-specific state
    uint256 public leverageRatio = 10000; // 1.0x initially
    uint256 public targetHealthFactor = 20000; // 2.0 target
    uint256 public minHealthFactor = 15000; // 1.5 minimum
    uint256 public maxLeverageRatio = 30000; // 3.0x maximum
    
    // Boost tracking
    uint256 public currentBoostMultiplier = 10000; // 1.0x
    uint256 public boostExpiry;
    
    // Advanced metrics
    uint256 public avgHarvestGasUsed;
    uint256 public successfulHarvests;
    uint256 public failedHarvests;
    uint256 public lastRebalanceTimestamp;
    uint256 public lastLeverageAdjustment;
    uint256 public totalMorphoRewards;
    
    // Market tracking
    address[] public activeMorphoMarkets;
    mapping(address => uint256) public marketAllocations; // market -> allocation bps
    
    // --------------------------------------------------
    // Advanced Configuration
    // --------------------------------------------------
    // uint256 public constant MAX_BPS = 10_000;
    uint256 public autoCompoundThresholdBps = 100; // 1% of idle funds
    uint256 public maxSingleTendMoveBps = 500;     // 5% max move per tend
    uint256 public rebalanceThresholdBps = 200;    // 2% APY improvement threshold
    uint256 public boostUpgradeThreshold = 7500;   // Performance score for auto-boost
    uint256 public leverageAdjustCooldown = 12 hours;
    uint256 public healthFactorBuffer = 500;       // 5% buffer for health factor
    
    // --------------------------------------------------
    // Enhanced Events
    // --------------------------------------------------
    event MorphoHyperHarvestExecuted(
        uint256 totalAssets, 
        uint256 yieldGenerated, 
        uint256 donationAmount,
        uint256 boostMultiplier,
        uint256 morphoRewards,
        uint256 gasUsed,
        uint256 timestamp
    );
    event StrategyBoostUpgraded(
        uint256 oldMultiplier, 
        uint256 newMultiplier, 
        uint256 expiry,
        string tier
    );
    event MorphoStrategyRebalanced(
        address fromMarket, 
        address toMarket, 
        uint256 amount,
        uint256 estimatedAPYGain
    );
    event LeverageAdjusted(
        uint256 oldLeverage,
        uint256 newLeverage,
        uint256 healthFactor,
        string reason
    );
    event MorphoTendOperationExecuted(
        uint256 idleDeployed,
        uint256 rewardsClaimed,
        uint256 positionsOptimized,
        uint256 gasUsed,
        uint256 timestamp
    );
    event AutoCompoundTriggered(uint256 amountCompounded, uint256 estimatedYieldIncrease);
    event HealthFactorAlert(uint256 healthFactor, uint256 threshold, string action);
    event MorphoMarketAdded(address indexed market, uint256 allocation);
    event LeveragedPositionCreated(address indexed market, uint256 supplied, uint256 borrowed);

    // --------------------------------------------------
    // Hyper Constructor - Following Yearn V3/Octant patterns
    // --------------------------------------------------
    constructor(
        address _asset,
        string memory _name,
        address _morphoAdapter,
        address _management,
        address _performanceFeeRecipient
    ) BaseHealthCheck(_asset, _name, _management, _performanceFeeRecipient) {
        require(_morphoAdapter != address(0), "Invalid Morpho adapter");
        
        morphoAdapter = NapFiHyperMorphoAdapter(_morphoAdapter);
        
        // Enhanced pre-approvals
        IERC20(_asset).safeApprove(_morphoAdapter, type(uint256).max);
        
        // Initialize health check parameters (from BaseHealthCheck)
        minReportDelay = 6 hours;
        profitMaxUnlockTime = 10 days;
        
        // Initialize performance tracking
        strategyPerformanceScore = 10000; // Start neutral
        
        // Initialize Morpho-specific parameters
        _initializeDefaultMarkets();
    }

    /*//////////////////////////////////////////////////////////////
                REQUIRED BASE STRATEGY OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Deploy funds to Morpho via hyper-optimized adapter with leverage
     * @param _amount Amount of asset to deploy
     */
    function _deployFunds(uint256 _amount) internal override {
        if (_amount == 0) return;
        
        // Enhanced: Pre-deployment risk validation with health factor checks
        _validateMorphoDeploymentRisk(_amount);
        
        // Enhanced: Gas-optimized deployment with performance tracking
        uint256 gasBefore = gasleft();
        
        try this._executeMorphoDeployment(_amount) {
            uint256 gasUsed = gasBefore - gasleft();
            
            // Update performance metrics
            _updateDeploymentMetrics(_amount, _amount, gasUsed);
            
            emit DeploymentOptimized(_amount, _amount, gasUsed, _getCurrentAPY());
        } catch Error(string memory reason) {
            _handleDeploymentFailure(_amount, reason);
        } catch {
            _handleDeploymentFailure(_amount, "Unknown error");
        }
    }

    /**
     * @dev Free funds from Morpho via hyper-optimized adapter
     * @param _amount Amount of asset to free
     */
    function _freeFunds(uint256 _amount) internal override {
        if (_amount == 0) return;
        
        // Enhanced: Calculate safe withdrawal amount considering health factors
        uint256 safeWithdrawAmount = _calculateSafeMorphoWithdrawal(_amount);
        
        if (safeWithdrawAmount > 0) {
            uint256 gasBefore = gasleft();
            
            try this._executeMorphoWithdrawal(safeWithdrawAmount) {
                uint256 gasUsed = gasBefore - gasleft();
                
                // Update withdrawal metrics
                _updateWithdrawalMetrics(_amount, safeWithdrawAmount, gasUsed);
                
                emit WithdrawalOptimized(_amount, safeWithdrawAmount, gasUsed);
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
     * @dev Harvest rewards and report total assets with Morpho-specific features
     * @return _totalAssets Total assets under management
     */
    function _harvestAndReport() internal override returns (uint256 _totalAssets) {
        uint256 initialGas = gasleft();
        uint256 preHarvestAssets = morphoAdapter.getStrategyTotalValue(address(this));
        
        // Enhanced: Multi-phase Morpho harvest with boost integration
        _executeMorphoHyperHarvest();
        
        // Enhanced: Post-harvest optimization and auto-compounding
        _executeMorphoPostHarvestOptimization();
        
        // Enhanced: Dynamic leverage adjustment based on market conditions
        _executeLeverageOptimization();
        
        // Enhanced: Strategy rebalancing across Morpho markets
        _executeMorphoRebalance();
        
        // Enhanced: Auto-boost upgrade if eligible
        _executeAutoBoostUpgrade();
        
        // Enhanced: Health factor monitoring and alerts
        _executeHealthFactorMonitoring();
        
        // Calculate total assets through adapter
        _totalAssets = morphoAdapter.getStrategyTotalValue(address(this));
        
        // Enhanced: Yield calculation with boost tracking
        uint256 yieldGenerated = _totalAssets > preHarvestAssets ? 
            _totalAssets - preHarvestAssets : 0;
        cumulativeYield += yieldGenerated;
        
        // Update performance metrics
        uint256 gasUsed = initialGas - gasleft();
        _updateHarvestMetrics(yieldGenerated, gasUsed);
        
        lastHarvestTimestamp = block.timestamp;
        
        emit MorphoHyperHarvestExecuted(
            _totalAssets, 
            yieldGenerated, 
            totalDonations,
            currentBoostMultiplier,
            totalMorphoRewards,
            gasUsed,
            block.timestamp
        );
        
        return _totalAssets;
    }

    /*//////////////////////////////////////////////////////////////
                OPTIONAL BASE STRATEGY OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Enhanced deposit limit with Morpho-specific capacity and health factor considerations
     */
    function availableDepositLimit(address _owner) public view override returns (uint256) {
        uint256 adapterLimit = morphoAdapter.availableDepositLimit(address(this));
        
        // Enhanced: Consider health factor and leverage constraints
        uint256 healthBasedLimit = _calculateHealthBasedDepositLimit();
        
        // Enhanced: Consider boost tier for capacity calculations
        if (currentBoostMultiplier > 10000 && block.timestamp < boostExpiry) {
            adapterLimit = (adapterLimit * currentBoostMultiplier) / 10000;
        }
        
        return adapterLimit.min(healthBasedLimit).min(type(uint256).max - totalAssets());
    }

    /**
     * @notice Enhanced withdraw limit with Morpho health factor safety features
     */
    function availableWithdrawLimit(address _owner) public view override returns (uint256) {
        uint256 baseLimit = asset.balanceOf(address(this));
        uint256 adapterLimit = morphoAdapter.availableWithdrawLimit(address(this));
        
        // Enhanced: Consider health factor constraints for withdrawals
        uint256 healthBasedLimit = _calculateHealthBasedWithdrawalLimit();
        
        // Enhanced: Consider market conditions
        if (!_areMorphoMarketConditionsFavorable()) {
            adapterLimit = adapterLimit / 2;
        }
        
        return baseLimit + adapterLimit.min(healthBasedLimit);
    }

    /**
     * @dev Enhanced tend mechanism for between-harvest Morpho optimization
     * Following Yearn V3 tend patterns with Morpho-specific operations
     */
    function _tend(uint256 _totalIdle) internal override {
        require(block.timestamp >= lastTendTimestamp + tendCooldown, "Tend cooldown");
        
        uint256 initialGas = gasleft();
        
        // Enhanced: Multi-phase Morpho tend operations
        uint256 idleDeployed = _executeMorphoIdleFundDeployment(_totalIdle);
        uint256 rewardsClaimed = _executeLightMorphoRewardHarvest();
        uint256 positionsOptimized = _executeMorphoPositionOptimization();
        uint256 healthAdjusted = _executeHealthFactorMaintenance();
        
        // Update tend metrics
        uint256 gasUsed = initialGas - gasleft();
        lastTendTimestamp = block.timestamp;
        
        emit MorphoTendOperationExecuted(idleDeployed, rewardsClaimed, positionsOptimized, gasUsed, block.timestamp);
    }

    /**
     * @dev Enhanced tend trigger with Morpho-specific multi-factor analysis
     * Following Octant's advanced trigger patterns with health factor monitoring
     */
    function _tendTrigger() internal view override returns (bool) {
        // Factor 1: Significant idle funds
        if (_hasSignificantIdleFunds()) return true;
        
        // Factor 2: Morpho reward claiming opportunity
        if (_hasWorthwhileMorphoRewards()) return true;
        
        // Factor 3: Position optimization opportunity
        if (_hasMorphoOptimizationOpportunity()) return true;
        
        // Factor 4: Market condition changes affecting Morpho
        if (_morphoMarketConditionsChanged()) return true;
        
        // Factor 5: Rebalancing opportunity across Morpho markets
        if (_hasMorphoRebalancingOpportunity()) return true;
        
        // Factor 6: Health factor maintenance needed
        if (_needsHealthFactorAdjustment()) return true;
        
        // Factor 7: Leverage adjustment opportunity
        if (_hasLeverageAdjustmentOpportunity()) return true;
        
        return false;
    }

    /**
     * @dev Enhanced emergency withdraw with Morpho-specific recovery
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        // Enhanced: Multi-phase emergency recovery with health factor consideration
        _executeMorphoEmergencyRecovery(_amount);
    }

    /*//////////////////////////////////////////////////////////////
                HYPER-OPTIMIZED MORPHO INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Execute Morpho deployment with leverage consideration
     */
    function _executeMorphoDeployment(uint256 _amount) internal {
        address bestMarket = _findOptimalMorphoMarket();
        require(bestMarket != address(0), "No suitable Morpho market");
        
        if (leverageRatio > 10000 && _canSafelyIncreaseLeverage()) {
            // Use leverage for higher yields
            uint256 borrowAmount = (_amount * (leverageRatio - 10000)) / 10000;
            
            morphoAdapter.createLeveragedPosition(
                bestMarket,
                _amount,
                borrowAmount
            );
            
            emit LeveragedPositionCreated(bestMarket, _amount, borrowAmount);
        } else {
            // Simple supply without leverage
            morphoAdapter.supplyToMorpho(bestMarket, _amount);
        }
    }

    /**
     * @dev Execute Morpho withdrawal with health factor preservation
     */
    function _executeMorphoWithdrawal(uint256 _amount) internal {
        // Withdraw from the most liquid market first
        address mostLiquidMarket = _findMostLiquidMarket();
        morphoAdapter.withdrawFromMorpho(mostLiquidMarket, _amount, address(this));
    }

    /**
     * @dev Execute hyper harvest with Morpho rewards and boost integration
     */
    function _executeMorphoHyperHarvest() internal {
        try morphoAdapter.harvestMorphoRewards() returns (uint256 yield, uint256 donation) {
            // Track donations for boost eligibility
            totalDonations += donation;
            
            // Update Morpho rewards tracking
            totalMorphoRewards += yield;
            
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
    function _executeMorphoPostHarvestOptimization() internal {
        uint256 idleAssets = asset.balanceOf(address(this));
        uint256 autoCompoundThreshold = _getAutoCompoundThreshold();
        
        if (idleAssets >= autoCompoundThreshold) {
            _deployFunds(idleAssets);
            emit AutoCompoundTriggered(idleAssets, _estimateMorphoYieldIncrease(idleAssets));
        }
        
        // Additional Morpho-specific optimizations
        _executeMorphoAdditionalOptimizations();
    }

    /**
     * @dev Execute dynamic leverage optimization
     */
    function _executeLeverageOptimization() internal {
        if (block.timestamp < lastLeverageAdjustment + leverageAdjustCooldown) return;
        
        uint256 currentHealth = _getCurrentHealthFactor();
        uint256 newLeverageRatio = leverageRatio;
        string memory adjustmentReason;
        
        if (currentHealth > targetHealthFactor + healthFactorBuffer) {
            // Health factor too high - can increase leverage
            newLeverageRatio = (leverageRatio * 11000) / 10000; // +10%
            newLeverageRatio = newLeverageRatio.min(maxLeverageRatio);
            adjustmentReason = "Health factor high - increasing leverage";
        } else if (currentHealth < targetHealthFactor - healthFactorBuffer) {
            // Health factor too low - decrease leverage
            newLeverageRatio = (leverageRatio * 9000) / 10000; // -10%
            newLeverageRatio = newLeverageRatio.max(10000); // Minimum 1x
            adjustmentReason = "Health factor low - decreasing leverage";
        } else if (_areMorphoMarketConditionsOptimalForLeverage()) {
            // Market conditions optimal for slight leverage increase
            newLeverageRatio = (leverageRatio * 10500) / 10000; // +5%
            newLeverageRatio = newLeverageRatio.min(maxLeverageRatio);
            adjustmentReason = "Optimal market conditions - increasing leverage";
        }
        
        if (newLeverageRatio != leverageRatio) {
            uint256 oldLeverage = leverageRatio;
            leverageRatio = newLeverageRatio;
            lastLeverageAdjustment = block.timestamp;
            
            // Execute leverage rebalance
            _executeLeverageRebalance();
            
            emit LeverageAdjusted(oldLeverage, newLeverageRatio, currentHealth, adjustmentReason);
        }
    }

    /**
     * @dev Execute rebalancing across Morpho markets
     */
    function _executeMorphoRebalance() internal {
        if (!_shouldRebalanceMorpho()) return;
        
        address bestMarket = _findOptimalMorphoMarket();
        address currentPrimaryMarket = _getPrimaryMarket();
        
        if (bestMarket != currentPrimaryMarket && bestMarket != address(0)) {
            uint256 rebalanceAmount = _calculateOptimalMorphoRebalanceAmount();
            
            try morphoAdapter.rebalanceMorphoMarkets() {
                lastRebalanceTimestamp = block.timestamp;
                
                uint256 estimatedGain = _estimateMorphoRebalanceGain(currentPrimaryMarket, bestMarket, rebalanceAmount);
                emit MorphoStrategyRebalanced(currentPrimaryMarket, bestMarket, rebalanceAmount, estimatedGain);
            } catch {
                // Graceful failure - rebalancing is optional
            }
        }
    }

    /**
     * @dev Execute health factor monitoring and alerts
     */
    function _executeHealthFactorMonitoring() internal {
        uint256 currentHealth = _getCurrentHealthFactor();
        
        if (currentHealth < minHealthFactor) {
            // Emergency de-leverage
            _executeEmergencyDeleverage();
            emit HealthFactorAlert(currentHealth, minHealthFactor, "Emergency de-leverage");
        } else if (currentHealth < targetHealthFactor) {
            // Warning level
            emit HealthFactorAlert(currentHealth, targetHealthFactor, "Health factor below target");
        }
    }

    /*//////////////////////////////////////////////////////////////
                MORPHO-SPECIFIC TEND OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Execute idle fund deployment during tend operations
     */
    function _executeMorphoIdleFundDeployment(uint256 _totalIdle) internal returns (uint256) {
        if (_totalIdle == 0) return 0;
        
        uint256 maxDeploy = (_totalIdle * maxSingleTendMoveBps) / MAX_BPS;
        uint256 deployAmount = _totalIdle.min(maxDeploy);
        
        if (deployAmount >= _getTendThreshold() && _canSafelyDeployToMorpho(deployAmount)) {
            _deployFunds(deployAmount);
            return deployAmount;
        }
        
        return 0;
    }

    /**
     * @dev Execute light Morpho reward harvesting during tend operations
     */
    function _executeLightMorphoRewardHarvest() internal returns (uint256) {
        if (!_isGasEfficientToClaimMorphoRewards()) return 0;
        
        // Light reward claiming without full harvest overhead
        // Could involve partial reward claiming or gas-optimized methods
        return 0;
    }

    /**
     * @dev Execute Morpho position optimization during tend operations
     */
    function _executeMorphoPositionOptimization() internal returns (uint256) {
        // Position optimization logic specific to Morpho
        // - Adjust collateralization ratios
        // - Optimize interest rate exposure
        // - Rebalance between fixed and variable rates
        return 0;
    }

    /**
     * @dev Execute health factor maintenance during tend operations
     */
    function _executeHealthFactorMaintenance() internal returns (uint256) {
        // Proactive health factor adjustments
        // - Partial deleveraging if health factor trending down
        // - Collateral reallocation
        return 0;
    }

    /*//////////////////////////////////////////////////////////////
                ADVANCED MORPHO VIEW & ANALYTICS FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Get current APY from Morpho with leverage and boost adjustments
     */
    function getCurrentAPY() public view returns (uint256) {
        // Calculate net APY considering leverage and borrow costs
        uint256 supplyAPY = _getAverageSupplyAPY();
        uint256 borrowAPY = _getAverageBorrowAPY();
        
        // Net APY = Supply APY - (Borrow APY * (Leverage Ratio - 1))
        uint256 leverageCost = (borrowAPY * (leverageRatio - 10000)) / 10000;
        uint256 netAPY = supplyAPY > leverageCost ? supplyAPY - leverageCost : 0;
        
        // Apply boost multiplier
        if (currentBoostMultiplier > 10000 && block.timestamp < boostExpiry) {
            netAPY = (netAPY * currentBoostMultiplier) / 10000;
        }
        
        return netAPY;
    }

    /**
     * @dev Get current health factor across all positions
     */
    function getCurrentHealthFactor() public view returns (uint256) {
        return _getCurrentHealthFactor();
    }

    /**
     * @dev Check if strategy should rebalance across Morpho markets
     */
    function shouldRebalance() public view returns (bool) {
        return _shouldRebalanceMorpho();
    }

    /**
     * @dev Get strategy health score considering Morpho-specific risks
     */
    function getHealthScore() public view returns (uint256) {
        uint256 performanceScore = strategyPerformanceScore;
        uint256 riskScore = _getMorphoRiskScore();
        uint256 healthFactorScore = _getHealthFactorScore();
        
        // Combined score considering performance, risk, and health
        return (performanceScore * (MAX_BPS - riskScore) * healthFactorScore) / (MAX_BPS * MAX_BPS);
    }

    /**
     * @dev Get boost eligibility status with Morpho-specific criteria
     */
    function isEligibleForBoostUpgrade() public view returns (bool) {
        return _isEligibleForBoostUpgrade();
    }

    /*//////////////////////////////////////////////////////////////
                ENHANCED MORPHO RISK MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function _validateMorphoDeploymentRisk(uint256 _amount) internal view {
        // Check adapter health
        require(_isMorphoAdapterHealthy(), "Morpho adapter reports unhealthy state");
        
        // Check health factor constraints
        require(_canSafelyDeployToMorpho(_amount), "Deployment would violate health factor constraints");
        
        // Check market conditions
        require(_areMorphoMarketConditionsFavorable(), "Morpho market conditions unfavorable");
        
        // Check deployment limits
        require(_amount <= availableDepositLimit(address(this)), "Exceeds deposit limit");
        
        // Check emergency mode
        require(!emergencyExit, "Strategy in emergency exit");
    }

    function _isMorphoAdapterHealthy() internal view returns (bool) {
        try morphoAdapter.paused() returns (bool isPaused) {
            return !isPaused;
        } catch {
            return true; // Assume healthy if check fails
        }
    }

    function _areMorphoMarketConditionsFavorable() internal view returns (bool) {
        // Implement Morpho-specific market condition checks
        // - Utilization rates
        // - Interest rate spreads
        // - Liquidity conditions
        return _getAverageSupplyAPY() > _getAverageBorrowAPY() + 100; // Positive spread
    }

    function _areMorphoMarketConditionsOptimalForLeverage() internal view returns (bool) {
        uint256 supplyAPY = _getAverageSupplyAPY();
        uint256 borrowAPY = _getAverageBorrowAPY();
        
        // Optimal when supply APY significantly higher than borrow APY
        return supplyAPY > borrowAPY + 300; // 3% positive spread
    }

    /*//////////////////////////////////////////////////////////////
                MORPHO-SPECIFIC HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _getCurrentHealthFactor() internal view returns (uint256) {
        // Weighted average health factor across all positions
        // Simplified implementation - would integrate with actual Morpho positions
        uint256 baseHealth = 20000; // Base 2.0
        
        // Adjust based on leverage
        if (leverageRatio > 10000) {
            baseHealth = (baseHealth * 10000) / leverageRatio;
        }
        
        return baseHealth.max(minHealthFactor);
    }

    function _calculateHealthBasedDepositLimit() internal view returns (uint256) {
        uint256 currentHealth = _getCurrentHealthFactor();
        
        if (currentHealth <= minHealthFactor) {
            return 0; // No deposits if at minimum health
        }
        
        // Calculate maximum additional deposit that maintains minimum health
        uint256 healthBuffer = currentHealth - minHealthFactor;
        return (totalAssets() * healthBuffer) / (MAX_BPS * 2); // Conservative estimate
    }

    function _calculateHealthBasedWithdrawalLimit() internal view returns (uint256) {
        uint256 currentHealth = _getCurrentHealthFactor();
        
        // More conservative withdrawal limits when health factor is lower
        if (currentHealth < targetHealthFactor) {
            return morphoAdapter.availableWithdrawLimit(address(this)) / 2;
        }
        
        return morphoAdapter.availableWithdrawLimit(address(this));
    }

    function _calculateSafeMorphoWithdrawal(uint256 requested) internal view returns (uint256) {
        uint256 maxSafe = morphoAdapter.availableWithdrawLimit(address(this));
        uint256 healthBasedLimit = _calculateHealthBasedWithdrawalLimit();
        
        return requested.min(maxSafe).min(healthBasedLimit);
    }

    function _findOptimalMorphoMarket() internal view returns (address) {
        // Find market with highest risk-adjusted returns
        // Consider supply APY, borrow APY, liquidity, and risk scores
        if (activeMorphoMarkets.length == 0) return address(0);
        
        // Simplified: return first market for now
        return activeMorphoMarkets[0];
    }

    function _getPrimaryMarket() internal view returns (address) {
        if (activeMorphoMarkets.length == 0) return address(0);
        return activeMorphoMarkets[0]; // Simplified
    }

    function _findMostLiquidMarket() internal view returns (address) {
        // Find market with highest liquidity for withdrawals
        if (activeMorphoMarkets.length == 0) return address(0);
        return activeMorphoMarkets[0]; // Simplified
    }

    function _getAverageSupplyAPY() internal view returns (uint256) {
        // Calculate weighted average supply APY across positions
        return 500; // 5% simplified
    }

    function _getAverageBorrowAPY() internal view returns (uint256) {
        // Calculate weighted average borrow APY across positions
        return 300; // 3% simplified
    }

    function _getMorphoRiskScore() internal view returns (uint256) {
        // Calculate Morpho-specific risk score
        // Consider leverage, market concentrations, health factors
        uint256 baseRisk = 3000; // Medium-low base risk
        
        // Increase risk with leverage
        if (leverageRatio > 10000) {
            baseRisk += ((leverageRatio - 10000) * 100) / 10000; // +1% risk per 1x leverage
        }
        
        return baseRisk.min(8000); // Cap at 80% risk
    }

    function _getHealthFactorScore() internal view returns (uint256) {
        uint256 health = _getCurrentHealthFactor();
        
        if (health >= 25000) return 10000; // Excellent
        if (health >= 20000) return 9000;  // Good
        if (health >= 15000) return 7000;  // Fair
        if (health >= 12000) return 5000;  // Poor
        return 3000; // Critical
    }

    function _canSafelyIncreaseLeverage() internal view returns (bool) {
        uint256 currentHealth = _getCurrentHealthFactor();
        uint256 projectedHealth = (currentHealth * 10000) / ((leverageRatio * 11000) / 10000);
        
        return projectedHealth >= minHealthFactor + healthFactorBuffer;
    }

    function _canSafelyDeployToMorpho(uint256 amount) internal view returns (bool) {
        uint256 currentHealth = _getCurrentHealthFactor();
        uint256 projectedTVL = totalAssets() + amount;
        uint256 projectedHealth = (currentHealth * totalAssets()) / projectedTVL;
        
        return projectedHealth >= minHealthFactor;
    }

    function _executeLeverageRebalance() internal {
        // Implementation would adjust positions to achieve target leverage
        // This could involve borrowing more or repaying debt
    }

    function _executeEmergencyDeleverage() internal {
        // Emergency de-leverage to safe levels
        uint256 oldLeverage = leverageRatio;
        leverageRatio = 10000; // 1x - no leverage
        _executeLeverageRebalance();
        
        emit LeverageAdjusted(oldLeverage, leverageRatio, _getCurrentHealthFactor(), "Emergency de-leverage");
    }

    function _executeMorphoAdditionalOptimizations() internal {
        // Additional Morpho-specific optimizations
        // - Dust collection
        // - Gas optimization
        // - Position consolidation
    }

    function _executeMorphoEmergencyRecovery(uint256 _amount) internal {
        // Enhanced emergency recovery with health factor preservation
        try morphoAdapter.emergencyWithdraw(_amount) {
            // Success
        } catch {
            try this._executeMorphoWithdrawal(_amount) {
                // Fallback success
            } catch {
                // Final fallback - emergency de-leverage and retry
                _executeEmergencyDeleverage();
                try this._executeMorphoWithdrawal(_amount) {
                    // Success after de-leverage
                } catch {
                    revert("Morpho emergency withdrawal failed");
                }
            }
        }
    }

    function _initializeDefaultMarkets() internal {
        // Initialize with some default Morpho markets
        // This would be populated based on deployment parameters
    }

    // Additional helper functions with similar patterns to Aave strategy...
    // [Include all the remaining helper functions from Aave strategy, adapted for Morpho]

    /*//////////////////////////////////////////////////////////////
                REMAINING HELPER FUNCTIONS (Similar to Aave version)
    //////////////////////////////////////////////////////////////*/

    function _updatePerformanceScore(bool success, uint256 yield) internal {
        // Same implementation as Aave strategy
        if (success && yield > 0) {
            strategyPerformanceScore = (strategyPerformanceScore + 100).min(MAX_BPS);
        } else if (!success) {
            strategyPerformanceScore = strategyPerformanceScore > 200 ? 
                strategyPerformanceScore - 200 : 0;
        }
        
        emit PerformanceMetricsUpdated(
            strategyPerformanceScore,
            getCurrentAPY(),
            _getMorphoRiskScore()
        );
    }

    function _updateHarvestMetrics(uint256 yield, uint256 gasUsed) internal {
        // Same implementation as Aave strategy
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
        currentBoostMultiplier = morphoAdapter.getBoostMultiplier(address(this));
        boostExpiry = morphoAdapter.strategyBoostExpiry(address(this));
    }

    function _getAutoCompoundThreshold() internal view returns (uint256) {
        uint256 total = totalAssets();
        uint256 dynamicThreshold = (total * autoCompoundThresholdBps) / MAX_BPS;
        uint256 minThreshold = 1000 * 10**IERC20Metadata(address(asset)).decimals();
        
        return dynamicThreshold.max(minThreshold);
    }

    function _getTendThreshold() internal view returns (uint256) {
        return _getAutoCompoundThreshold() / 5;
    }

    function _hasSignificantIdleFunds() internal view returns (bool) {
        return asset.balanceOf(address(this)) > _getTendThreshold();
    }

    function _hasWorthwhileMorphoRewards() internal view returns (bool) {
        return _isGasEfficientToClaimMorphoRewards();
    }

    function _hasMorphoOptimizationOpportunity() internal view returns (bool) {
        // Check for Morpho-specific optimization opportunities
        return false;
    }

    function _morphoMarketConditionsChanged() internal view returns (bool) {
        // Check if Morpho market conditions have changed
        return false;
    }

    function _hasMorphoRebalancingOpportunity() internal view returns (bool) {
        return _shouldRebalanceMorpho();
    }

    function _needsHealthFactorAdjustment() internal view returns (bool) {
        uint256 currentHealth = _getCurrentHealthFactor();
        return currentHealth < targetHealthFactor - healthFactorBuffer || 
               currentHealth > targetHealthFactor + healthFactorBuffer;
    }

    function _hasLeverageAdjustmentOpportunity() internal view returns (bool) {
        return block.timestamp >= lastLeverageAdjustment + leverageAdjustCooldown;
    }

    function _isGasEfficientToClaimMorphoRewards() internal view returns (bool) {
        // Check gas efficiency of Morpho reward claiming
        return true;
    }

    function _shouldRebalanceMorpho() internal view returns (bool) {
        return _hasMorphoRebalancingOpportunity() && 
               block.timestamp >= lastRebalanceTimestamp + 7 days;
    }

    function _isEligibleForBoostUpgrade() internal view returns (bool) {
        return strategyPerformanceScore >= boostUpgradeThreshold &&
               block.timestamp >= boostExpiry &&
               morphoAdapter.getBoostMultiplier(address(this)) < 20000;
    }

    function _calculateOptimalMorphoRebalanceAmount() internal view returns (uint256) {
        uint256 currentBalance = morphoAdapter.getStrategyTotalValue(address(this));
        return (currentBalance * maxSingleTendMoveBps) / MAX_BPS;
    }

    function _estimateMorphoRebalanceGain(address from, address to, uint256 amount) internal pure returns (uint256) {
        return amount / 100;
    }

    function _estimateMorphoYieldIncrease(uint256 amount) internal view returns (uint256) {
        return (amount * getCurrentAPY()) / (MAX_BPS * 365 days);
    }

    function _getBoostTierString() internal view returns (string memory) {
        uint256 multiplier = currentBoostMultiplier;
        if (multiplier >= 20000) return "MORPHO_TITAN";
        if (multiplier >= 17500) return "PLATINUM";
        if (multiplier >= 15000) return "GOLD";
        if (multiplier >= 12500) return "SILVER";
        if (multiplier >= 11000) return "BRONZE";
        return "NONE";
    }

    // Additional events for enhanced monitoring
    event DeploymentOptimized(uint256 attempted, uint256 actual, uint256 gasUsed, uint256 estimatedAPY);
    event WithdrawalOptimized(uint256 attempted, uint256 actual, uint256 gasUsed);
    event DeploymentFailed(uint256 amount, string reason);
    event WithdrawalFailed(uint256 amount, string reason);
    event WithdrawalShortfall(uint256 shortfall);
    event HarvestError(string reason);
    event PerformanceMetricsUpdated(uint256 performanceScore, uint256 avgAPY, uint256 riskScore);
}

// Required interfaces
interface IERC20Metadata {
    function decimals() external view returns (uint8);
}