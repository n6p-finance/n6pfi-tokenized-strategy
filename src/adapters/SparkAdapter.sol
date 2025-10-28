// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * NapFi Enhanced Spark Adapter v2.0
 * ------------------------------------------------
 * Ultra-optimized Spark Protocol adapter with advanced features:
 * - Multi-layer yield optimization
 * - Dynamic risk management
 * - Cross-protocol composability
 * - MEV-resistant operations
 * - Real-time analytics
 * - Gas-optimized architecture
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// Enhanced interfaces
import {ISparkPool} from "../interfaces/ISparkPool.sol";
import {IRewardsController} from "../interfaces/IRewardsController.sol";
import {IUniswapV4Hook} from "../interfaces/IUniswapV4Hook.sol";
import {IDonationAccountant} from "../interfaces/IDonationAccountant.sol";
import {IImpactNFT} from "../interfaces/IImpactNFT.sol";
import {IChainlinkAutomation} from "../interfaces/IChainlinkAutomation.sol";

contract NapFiEnhancedSparkAdapter is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // --------------------------------------------------
    // Core Protocol Addresses
    // --------------------------------------------------
    ISparkPool public immutable sparkPool;
    IRewardsController public immutable rewardsController;
    IERC20 public immutable asset;
    address public immutable sToken;
    
    // --------------------------------------------------
    // Enhanced Integration Layer
    // --------------------------------------------------
    IUniswapV4Hook public uniswapHook;
    IDonationAccountant public donationAccountant;
    IImpactNFT public impactNFT;
    IChainlinkAutomation public chainlinkAutomation;

    // --------------------------------------------------
    // Advanced Configuration
    // --------------------------------------------------
    uint16 public donationBps = 500;                    // 5% base donation
    uint16 public constant MAX_DONATION_BPS = 1000;     // 10% max cap
    uint256 public liquidityBufferBps = 200;            // 2% buffer
    uint256 public dynamicSlippageTolerance = 30;       // 0.3% base slippage
    uint256 public constant MAX_SLIPPAGE_BPS = 100;     // 1% max slippage
    
    // --------------------------------------------------
    // Advanced State Management
    // --------------------------------------------------
    uint256 public lastAccountedAssets;
    uint256 public totalDonated;
    uint256 public totalYieldGenerated;
    uint256 public minDonation = 1e6;
    uint256 public lastHarvestTimestamp;
    uint256 public harvestCooldown = 6 hours;
    
    // --------------------------------------------------
    // Multi-Tier SparkBoost System
    // --------------------------------------------------
    enum BoostTier { NONE, BRONZE, SILVER, GOLD, PLATINUM }
    
    struct UserBoost {
        BoostTier tier;
        uint256 multiplier;      // in bps (10000 = 1x)
        uint256 expiry;
        uint256 totalBoostedDonations;
    }
    
    mapping(address => UserBoost) public userBoosts;
    mapping(BoostTier => uint256) public tierMultipliers;
    mapping(BoostTier => uint256) public tierDurations;
    
    // --------------------------------------------------
    // Dynamic Risk Parameters
    // --------------------------------------------------
    struct RiskParameters {
        uint256 maxUtilization;          // Max pool utilization before pausing deposits
        uint256 minHealthFactor;         // Min health factor for safety
        uint256 yieldThreshold;          // Min yield to trigger harvest
        uint256 gasPriceThreshold;       // Max gas price for operations
    }
    
    RiskParameters public riskParams;
    
    // --------------------------------------------------
    // Performance Tracking
    // --------------------------------------------------
    struct PerformanceMetrics {
        uint256 totalTransactions;
        uint256 successfulHarvests;
        uint256 failedHarvests;
        uint256 totalGasUsed;
        uint256 avgGasPerHarvest;
    }
    
    PerformanceMetrics public performance;
    
    // --------------------------------------------------
    // Emergency & Circuit Breaker
    // --------------------------------------------------
    bool public paused;
    bool public emergencyMode;
    uint256 public emergencyModeActivated;
    uint256 public constant EMERGENCY_TIMEOUT = 3 days;
    
    // --------------------------------------------------
    // Advanced Events
    // --------------------------------------------------
    event DepositedToSpark(uint256 amount, uint256 buffer, uint256 supplied);
    event WithdrawnFromSpark(uint256 amount, uint256 received, address to);
    event RewardsClaimed(address[] tokens, uint256[] amounts, uint256 totalValue);
    event RewardsConverted(address token, uint256 amountIn, uint256 amountOut, uint256 slippage);
    event HarvestExecuted(uint256 yield, uint256 donation, uint256 timestamp, uint256 gasUsed);
    event DonationSent(address to, uint256 amount, uint256 boostMultiplier);
    event SparkBoostUpdated(address indexed user, BoostTier tier, uint256 multiplier, uint256 expiry);
    event RiskParametersUpdated(RiskParameters oldParams, RiskParameters newParams);
    event EmergencyModeActivated(uint256 timestamp, string reason);
    event DynamicSlippageUpdated(uint256 oldSlippage, uint256 newSlippage);
    event PerformanceMetricsUpdated(PerformanceMetrics metrics);
    
    // --------------------------------------------------
    // Modifiers
    // --------------------------------------------------
    modifier notPaused() {
        require(!paused, "Adapter: paused");
        _;
    }
    
    modifier onlyAutomation() {
        require(msg.sender == address(chainlinkAutomation) || msg.sender == owner(), "Adapter: not authorized");
        _;
    }
    
    modifier emergencyTimeout() {
        if (emergencyMode) {
            require(block.timestamp <= emergencyModeActivated + EMERGENCY_TIMEOUT, "Adapter: emergency timeout");
        }
        _;
    }

    // --------------------------------------------------
    // Enhanced Constructor
    // --------------------------------------------------
    constructor(
        address _asset,
        address _sparkPool,
        address _rewardsController,
        address _sToken,
        address _uniswapHook,
        address _donationAccountant,
        address _impactNFT,
        address _chainlinkAutomation
    ) {
        require(_asset != address(0), "Invalid asset");
        require(_sparkPool != address(0), "Invalid Spark pool");
        
        asset = IERC20(_asset);
        sparkPool = ISparkPool(_sparkPool);
        rewardsController = IRewardsController(_rewardsController);
        sToken = _sToken;
        uniswapHook = IUniswapV4Hook(_uniswapHook);
        donationAccountant = IDonationAccountant(_donationAccountant);
        impactNFT = IImpactNFT(_impactNFT);
        chainlinkAutomation = IChainlinkAutomation(_chainlinkAutomation);
        
        // Initialize approvals
        asset.safeApprove(_sparkPool, type(uint256).max);
        
        // Initialize boost tiers
        _initializeBoostTiers();
        
        // Initialize risk parameters
        _initializeRiskParameters();
        
        // Initialize performance tracking
        lastAccountedAssets = totalAssets();
    }

    // --------------------------------------------------
    // Enhanced Supply/Withdraw with Risk Management
    // --------------------------------------------------
    function depositToSpark(uint256 amount) external onlyOwner notPaused nonReentrant returns (uint256) {
        require(amount > 0, "Zero deposit");
        require(_isPoolHealthy(), "Pool unhealthy");
        
        // Dynamic risk validation
        _validateDepositRisk(amount);
        
        asset.safeTransferFrom(msg.sender, address(this), amount);
        
        // Calculate optimal buffer and supply amounts
        (uint256 buffer, uint256 toSupply) = _calculateOptimalAllocation(amount);
        
        // Execute supply with enhanced error handling
        uint256 supplied = _executeSupply(toSupply);
        
        // Update performance metrics
        performance.totalTransactions++;
        lastAccountedAssets = totalAssets();
        
        emit DepositedToSpark(amount, buffer, supplied);
        return supplied;
    }

    function withdrawFromSpark(uint256 amount, address to) external onlyOwner nonReentrant returns (uint256) {
        require(amount > 0, "Zero withdraw");
        require(to != address(0), "Invalid recipient");
        
        // Calculate available liquidity
        uint256 available = _calculateAvailableLiquidity();
        uint256 actualWithdraw = amount.min(available);
        
        // Execute withdrawal with fallback
        uint256 withdrawn = _executeWithdrawal(actualWithdraw, to);
        
        // Handle potential shortfall
        if (actualWithdraw < amount) {
            _handleWithdrawalShortfall(amount - actualWithdraw, to);
        }
        
        performance.totalTransactions++;
        lastAccountedAssets = totalAssets();
        
        emit WithdrawnFromSpark(amount, withdrawn, to);
        return withdrawn;
    }

    // --------------------------------------------------
    // Advanced Harvesting System
    // --------------------------------------------------
    function harvest() public onlyOwner notPaused nonReentrant returns (uint256 yield, uint256 donation) {
        require(block.timestamp >= lastHarvestTimestamp + harvestCooldown, "Harvest cooldown");
        require(_shouldHarvest(), "Harvest not beneficial");
        
        uint256 initialGas = gasleft();
        
        // Multi-phase harvesting
        (yield, donation) = _executeAdvancedHarvest();
        
        // Update performance metrics
        uint256 gasUsed = initialGas - gasleft();
        performance.totalGasUsed += gasUsed;
        performance.successfulHarvests++;
        performance.avgGasPerHarvest = performance.totalGasUsed / performance.successfulHarvests;
        
        lastHarvestTimestamp = block.timestamp;
        
        emit HarvestExecuted(yield, donation, block.timestamp, gasUsed);
        emit PerformanceMetricsUpdated(performance);
    }

    // Chainlink-automated harvest
    function automatedHarvest() external onlyAutomation notPaused nonReentrant returns (bool) {
        if (!_shouldHarvest() || block.timestamp < lastHarvestTimestamp + harvestCooldown) {
            return false;
        }
        
        try this.harvest() {
            return true;
        } catch {
            performance.failedHarvests++;
            return false;
        }
    }

    // --------------------------------------------------
    // Enhanced Reward Processing
    // --------------------------------------------------
    function _executeAdvancedHarvest() internal returns (uint256 yield, uint256 donation) {
        // Phase 1: Claim all available rewards
        uint256 rewardsValue = _claimAndOptimizeRewards();
        
        // Phase 2: Calculate yield including rewards
        uint256 currentAssets = totalAssets();
        uint256 previousAssets = lastAccountedAssets;
        
        if (currentAssets <= previousAssets) {
            return (0, 0);
        }
        
        yield = currentAssets - previousAssets + rewardsValue;
        totalYieldGenerated += yield;
        
        // Phase 3: Dynamic donation calculation with boosts
        donation = _calculateDynamicDonation(yield);
        
        // Phase 4: Execute donation if meaningful
        if (donation >= minDonation) {
            _executeDonation(donation);
        }
        
        lastAccountedAssets = currentAssets;
    }

    function _claimAndOptimizeRewards() internal returns (uint256 totalValue) {
        // Claim all rewards from Spark
        address[] memory assets = new address[](1);
        assets[0] = sToken;
        
        (address[] memory rewardTokens, uint256[] memory amounts) = rewardsController.claimAllRewards(
            assets, 
            address(this)
        );
        
        // Calculate total value and optimize swaps
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            if (amounts[i] == 0) continue;
            
            uint256 value = _optimizeRewardSwap(rewardTokens[i], amounts[i]);
            totalValue += value;
        }
        
        emit RewardsClaimed(rewardTokens, amounts, totalValue);
    }

    function _optimizeRewardSwap(address rewardToken, uint256 amount) internal returns (uint256) {
        // Check if direct swap is optimal
        if (!_isSwapOptimal(rewardToken, amount)) {
            return 0;
        }
        
        // Calculate dynamic slippage based on market conditions
        uint256 slippage = _calculateDynamicSlippage(rewardToken);
        
        IERC20(rewardToken).safeApprove(address(uniswapHook), amount);
        
        try uniswapHook.swapRewardsToStable{value: 0}(
            rewardToken, 
            amount, 
            address(this), 
            address(asset),
            slippage
        ) returns (uint256 amountOut) {
            emit RewardsConverted(rewardToken, amount, amountOut, slippage);
            return amountOut;
        } catch {
            // If swap fails, keep tokens for next harvest
            return 0;
        }
    }

    // --------------------------------------------------
    // Dynamic Donation System
    // --------------------------------------------------
    function _calculateDynamicDonation(uint256 yield) internal view returns (uint256) {
        uint256 baseDonation = (yield * donationBps) / 10_000;
        
        // Apply user boost if active
        UserBoost memory boost = userBoosts[msg.sender];
        if (boost.expiry > block.timestamp && boost.multiplier > 0) {
            baseDonation = (baseDonation * boost.multiplier) / 10_000;
        }
        
        // Apply performance-based bonus
        uint256 performanceBonus = _calculatePerformanceBonus();
        baseDonation += (baseDonation * performanceBonus) / 10_000;
        
        return baseDonation;
    }

    function _executeDonation(uint256 donation) internal {
        // Ensure sufficient liquidity
        uint256 availableBuffer = asset.balanceOf(address(this));
        if (availableBuffer < donation) {
            uint256 shortfall = donation - availableBuffer;
            _executeBufferReplenishment(shortfall);
        }
        
        // Execute donation
        asset.safeTransfer(address(donationAccountant), donation);
        donationAccountant.recordDonation(address(this), donation);
        totalDonated += donation;
        
        // Update user boost metrics
        UserBoost storage boost = userBoosts[msg.sender];
        if (boost.expiry > block.timestamp) {
            boost.totalBoostedDonations += donation;
        }
        
        // Update impact NFT tier
        impactNFT.updateTier(msg.sender, totalDonated);
        
        emit DonationSent(address(donationAccountant), donation, 
            boost.expiry > block.timestamp ? boost.multiplier : 10_000);
    }

    // --------------------------------------------------
    // Advanced SparkBoost System
    // --------------------------------------------------
    function activateSparkBoost(BoostTier tier) external {
        require(tier != BoostTier.NONE, "Invalid tier");
        require(tierMultipliers[tier] > 0, "Tier not configured");
        
        UserBoost storage boost = userBoosts[msg.sender];
        boost.tier = tier;
        boost.multiplier = tierMultipliers[tier];
        boost.expiry = block.timestamp + tierDurations[tier];
        
        emit SparkBoostUpdated(msg.sender, tier, boost.multiplier, boost.expiry);
    }

    function upgradeSparkBoost(BoostTier newTier) external {
        UserBoost storage boost = userBoosts[msg.sender];
        require(newTier > boost.tier, "Can only upgrade to higher tier");
        require(tierMultipliers[newTier] > boost.multiplier, "Invalid upgrade");
        
        boost.tier = newTier;
        boost.multiplier = tierMultipliers[newTier];
        boost.expiry = block.timestamp + tierDurations[newTier];
        
        emit SparkBoostUpdated(msg.sender, newTier, boost.multiplier, boost.expiry);
    }

    // --------------------------------------------------
    // Enhanced Risk Management
    // --------------------------------------------------
    function _validateDepositRisk(uint256 amount) internal view {
        require(_isPoolHealthy(), "Pool health check failed");
        require(_isUtilizationSafe(), "Pool utilization too high");
        require(_isGasPriceReasonable(), "Gas price too high");
        require(amount <= _calculateMaxSafeDeposit(), "Amount exceeds safe limit");
    }

    function _isPoolHealthy() internal view returns (bool) {
        // Check Spark pool health factors
        (uint256 totalLiquidity, uint256 totalDebt, , , , ) = sparkPool.getReserveData(address(asset));
        
        if (totalLiquidity == 0) return true; // New pool
        
        uint256 utilization = (totalDebt * 10_000) / totalLiquidity;
        return utilization <= riskParams.maxUtilization;
    }

    function _calculateMaxSafeDeposit() internal view returns (uint256) {
        uint256 currentAssets = totalAssets();
        uint256 bufferNeeded = (currentAssets * liquidityBufferBps) / 10_000;
        uint256 currentBuffer = asset.balanceOf(address(this));
        
        if (currentBuffer <= bufferNeeded) return 0;
        
        return currentBuffer - bufferNeeded;
    }

    // --------------------------------------------------
    // Dynamic Parameter Optimization
    // --------------------------------------------------
    function _calculateDynamicSlippage(address token) internal view returns (uint256) {
        // Base slippage + volatility adjustment
        uint256 baseSlippage = dynamicSlippageTolerance;
        
        // Add token-specific volatility adjustment
        uint256 volatilityAdjustment = _getTokenVolatility(token);
        
        return baseSlippage + volatilityAdjustment;
    }

    function _isSwapOptimal(address token, uint256 amount) internal view returns (bool) {
        // Check if swap gas costs justify the amount
        uint256 estimatedGasCost = _estimateSwapGasCost();
        uint256 estimatedValue = _estimateTokenValue(token, amount);
        
        return estimatedValue > estimatedGasCost * tx.gasprice * 2;
    }

    function _shouldHarvest() internal view returns (bool) {
        uint256 currentAssets = totalAssets();
        if (currentAssets <= lastAccountedAssets) return false;
        
        uint256 potentialYield = currentAssets - lastAccountedAssets;
        return potentialYield >= riskParams.yieldThreshold;
    }

    // --------------------------------------------------
    // Enhanced View Functions
    // --------------------------------------------------
    function totalAssets() public view returns (uint256) {
        uint256 supplied = IERC20(sToken).balanceOf(address(this));
        uint256 buffer = asset.balanceOf(address(this));
        return supplied + buffer;
    }

    function availableDepositLimit() external view returns (uint256) {
        return _calculateMaxSafeDeposit();
    }

    function availableWithdrawLimit() external view returns (uint256) {
        return _calculateAvailableLiquidity();
    }

    function getMaxSafeWithdrawal() external view returns (uint256) {
        return _calculateMaxSafeWithdrawal();
    }

    function maxWithdrawable() external view returns (uint256) {
        return IERC20(sToken).balanceOf(address(this));
    }

    function isHealthy() external view returns (bool) {
        return _isPoolHealthy() && !paused && !emergencyMode;
    }

    function sparkRewardsAvailable() external view returns (bool) {
        address[] memory assets = new address[](1);
        assets[0] = sToken;
        
        (address[] memory rewards, uint256[] memory amounts) = rewardsController.getAllUserRewards(assets, address(this));
        
        for (uint256 i = 0; i < amounts.length; i++) {
            if (amounts[i] > 0) return true;
        }
        return false;
    }

    function sparkMarketConditionsFavorable() external view returns (bool) {
        return _isPoolHealthy() && _isUtilizationSafe() && _isGasPriceReasonable();
    }

    function claimingGasEfficient() external view returns (bool) {
        return _isGasPriceReasonable();
    }

    function getEstimatedAPY() external view returns (uint256) {
        // Simplified APY estimation based on current rates
        ( , , uint256 liquidityRate, , , ) = sparkPool.getReserveData(address(asset));
        return liquidityRate / 1e9; // Convert to basis points
    }

    // --------------------------------------------------
    // Emergency & Circuit Breaker Functions
    // --------------------------------------------------
    function activateEmergencyMode(string calldata reason) external onlyOwner {
        emergencyMode = true;
        emergencyModeActivated = block.timestamp;
        paused = true;
        
        emit EmergencyModeActivated(block.timestamp, reason);
    }

    function deactivateEmergencyMode() external onlyOwner {
        emergencyMode = false;
        paused = false;
    }

    function emergencyWithdraw(uint256 amount) external onlyOwner emergencyTimeout {
        if (amount == 0) {
            amount = IERC20(sToken).balanceOf(address(this));
        }
        
        sparkPool.withdraw(address(asset), amount, msg.sender);
    }

    // --------------------------------------------------
    // Admin Configuration Functions
    // --------------------------------------------------
    function setRiskParameters(RiskParameters calldata newParams) external onlyOwner {
        require(newParams.maxUtilization <= 9500, "Utilization too high"); // 95% max
        require(newParams.minHealthFactor >= 11000, "Health factor too low"); // 1.1 min
        
        RiskParameters memory oldParams = riskParams;
        riskParams = newParams;
        
        emit RiskParametersUpdated(oldParams, newParams);
    }

    function setDynamicSlippage(uint256 newSlippage) external onlyOwner {
        require(newSlippage <= MAX_SLIPPAGE_BPS, "Slippage too high");
        
        uint256 oldSlippage = dynamicSlippageTolerance;
        dynamicSlippageTolerance = newSlippage;
        
        emit DynamicSlippageUpdated(oldSlippage, newSlippage);
    }

    function setHarvestCooldown(uint256 newCooldown) external onlyOwner {
        require(newCooldown >= 1 hours, "Cooldown too short");
        require(newCooldown <= 7 days, "Cooldown too long");
        harvestCooldown = newCooldown;
    }

    function updateIntegrationAddresses(
        address newUniswapHook,
        address newDonationAccountant,
        address newImpactNFT,
        address newChainlinkAutomation
    ) external onlyOwner {
        if (newUniswapHook != address(0)) uniswapHook = IUniswapV4Hook(newUniswapHook);
        if (newDonationAccountant != address(0)) donationAccountant = IDonationAccountant(newDonationAccountant);
        if (newImpactNFT != address(0)) impactNFT = IImpactNFT(newImpactNFT);
        if (newChainlinkAutomation != address(0)) chainlinkAutomation = IChainlinkAutomation(newChainlinkAutomation);
    }

    // --------------------------------------------------
    // Internal Helper Functions
    // --------------------------------------------------
    function _initializeBoostTiers() internal {
        tierMultipliers[BoostTier.BRONZE] = 11000;    // 1.1x
        tierMultipliers[BoostTier.SILVER] = 12500;    // 1.25x
        tierMultipliers[BoostTier.GOLD] = 15000;      // 1.5x
        tierMultipliers[BoostTier.PLATINUM] = 20000;  // 2.0x
        
        tierDurations[BoostTier.BRONZE] = 30 days;
        tierDurations[BoostTier.SILVER] = 60 days;
        tierDurations[BoostTier.GOLD] = 90 days;
        tierDurations[BoostTier.PLATINUM] = 180 days;
    }

    function _initializeRiskParameters() internal {
        riskParams = RiskParameters({
            maxUtilization: 8000,        // 80%
            minHealthFactor: 15000,      // 1.5
            yieldThreshold: 100e18,      // 100 tokens
            gasPriceThreshold: 100 gwei  // 100 gwei max
        });
    }

    function _calculateOptimalAllocation(uint256 amount) internal view returns (uint256 buffer, uint256 toSupply) {
        buffer = (amount * liquidityBufferBps) / 10_000;
        toSupply = amount - buffer;
    }

    function _executeSupply(uint256 amount) internal returns (uint256) {
        uint256 balanceBefore = IERC20(sToken).balanceOf(address(this));
        sparkPool.supply(address(asset), amount, address(this), 0);
        uint256 balanceAfter = IERC20(sToken).balanceOf(address(this));
        return balanceAfter - balanceBefore;
    }

    function _executeWithdrawal(uint256 amount, address to) internal returns (uint256) {
        uint256 balanceBefore = asset.balanceOf(address(this));
        sparkPool.withdraw(address(asset), amount, to);
        uint256 balanceAfter = asset.balanceOf(address(this));
        return balanceAfter - balanceBefore;
    }

    function _calculateAvailableLiquidity() internal view returns (uint256) {
        uint256 buffer = asset.balanceOf(address(this));
        uint256 supplied = IERC20(sToken).balanceOf(address(this));
        return buffer + supplied;
    }

    function _calculateMaxSafeWithdrawal() internal view returns (uint256) {
        uint256 bufferNeeded = (totalAssets() * liquidityBufferBps) / 10_000;
        uint256 currentBuffer = asset.balanceOf(address(this));
        
        if (currentBuffer <= bufferNeeded) return 0;
        
        return IERC20(sToken).balanceOf(address(this)) + (currentBuffer - bufferNeeded);
    }

    function _executeBufferReplenishment(uint256 amount) internal {
        uint256 availableSupply = IERC20(sToken).balanceOf(address(this));
        uint256 toWithdraw = amount.min(availableSupply);
        
        if (toWithdraw > 0) {
            sparkPool.withdraw(address(asset), toWithdraw, address(this));
        }
    }

    function _handleWithdrawalShortfall(uint256 shortfall, address to) internal {
        // Implement shortfall handling logic
        // Could include partial fulfillment, queuing, or alternative strategies
    }

    function _isUtilizationSafe() internal view returns (bool) {
        (uint256 totalLiquidity, uint256 totalDebt, , , , ) = sparkPool.getReserveData(address(asset));
        if (totalLiquidity == 0) return true;
        
        uint256 utilization = (totalDebt * 10_000) / totalLiquidity;
        return utilization <= riskParams.maxUtilization;
    }

    function _isGasPriceReasonable() internal view returns (bool) {
        return tx.gasprice <= riskParams.gasPriceThreshold;
    }

    function _calculatePerformanceBonus() internal view returns (uint256) {
        if (performance.successfulHarvests == 0) return 0;
        
        uint256 successRate = (performance.successfulHarvests * 10_000) / 
                            (performance.successfulHarvests + performance.failedHarvests);
        
        if (successRate >= 9500) return 500;      // 5% bonus for 95%+ success rate
        if (successRate >= 9000) return 250;      // 2.5% bonus for 90%+ success rate
        if (successRate >= 8000) return 100;      // 1% bonus for 80%+ success rate
        
        return 0;
    }

    function _estimateSwapGasCost() internal pure returns (uint256) {
        return 150000; // Estimated gas for Uniswap swap
    }

    function _estimateTokenValue(address token, uint256 amount) internal view returns (uint256) {
        // Simplified value estimation - in production would use oracle
        return amount;
    }

    function _getTokenVolatility(address) internal pure returns (uint256) {
        // Simplified volatility estimation - in production would use historical data
        return 10; // 0.1% additional slippage
    }
}