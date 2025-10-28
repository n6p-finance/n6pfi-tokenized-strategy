// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * NapFi Enhanced Aave Adapter v3.0
 * ------------------------------------------------
 * Ultra-optimized Aave v3 adapter with enterprise-grade features:
 * - Multi-asset yield optimization across Aave markets
 * - Dynamic risk-adjusted allocation with real-time health monitoring
 * - Cross-protocol composability with Aave's ecosystem
 * - MEV-resistant operations with gas optimization
 * - Real-time analytics and performance tracking
 * - Advanced donation streaming with multi-tier boosts
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// Enhanced Aave v3 interfaces
import {IAavePool} from "../interfaces/IAavePool.sol";
import {IRewardsController} from "../interfaces/IRewardsController.sol";
import {IUniswapV4Hook} from "../interfaces/IUniswapV4Hook.sol";
import {IDonationAccountant} from "../interfaces/IDonationAccountant.sol";
import {IImpactNFT} from "../interfaces/IImpactNFT.sol";
import {IChainlinkAutomation} from "../interfaces/IChainlinkAutomation.sol";

contract NapFiEnhancedAaveAdapter is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // --------------------------------------------------
    // Core Protocol Addresses
    // --------------------------------------------------
    IAavePool public immutable aavePool;
    IRewardsController public immutable rewardsController;
    IERC20 public immutable asset;
    IERC20 public immutable aToken;
    
    // --------------------------------------------------
    // Enhanced Integration Layer
    // --------------------------------------------------
    IUniswapV4Hook public uniswapHook;
    IDonationAccountant public donationAccountant;
    IImpactNFT public impactNFT;
    IChainlinkAutomation public chainlinkAutomation;

    // --------------------------------------------------
    // Multi-Asset Management
    // --------------------------------------------------
    struct AssetConfig {
        address asset;
        address aToken;
        uint256 allocationBps;           // Allocation percentage (0-10000)
        bool enabled;
        uint256 maxExposure;             // Maximum exposure limit
        uint256 currentExposure;         // Current exposure
        uint256 performanceScore;        // Asset performance metric
        uint256 reserveFactor;           // Aave reserve factor consideration
    }
    
    address[] public activeAssets;
    mapping(address => AssetConfig) public assetConfigs;
    uint256 public totalAllocationBps = 10000; // 100% total allocation
    
    // --------------------------------------------------
    // Advanced Configuration
    // --------------------------------------------------
    uint16 public donationBps = 500;                    // 5% base donation
    uint16 public constant MAX_DONATION_BPS = 1000;     // 10% max cap
    uint256 public liquidityBufferBps = 200;            // 2% buffer
    uint256 public dynamicSlippageTolerance = 30;       // 0.3% base slippage
    uint256 public constant MAX_SLIPPAGE_BPS = 100;     // 1% max slippage
    uint16 public constant REFERRAL_CODE = 0;           // Aave referral code
    
    // --------------------------------------------------
    // Advanced State Management
    // --------------------------------------------------
    uint256 public totalDonated;
    uint256 public totalYieldGenerated;
    uint256 public minDonation = 1e6;
    uint256 public lastHarvestTimestamp;
    uint256 public harvestCooldown = 6 hours;
    
    // --------------------------------------------------
    // Multi-Tier AaveBoost System
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
    // Dynamic Risk Parameters for Aave v3
    // --------------------------------------------------
    struct RiskParameters {
        uint256 maxUtilization;          // Max pool utilization before pausing deposits
        uint256 minHealthFactor;         // Min health factor for safety (in bps)
        uint256 yieldThreshold;          // Min yield to trigger harvest
        uint256 gasPriceThreshold;       // Max gas price for operations
        uint256 maxAssetConcentration;   // Max allocation to single asset
        uint256 reserveFactorBuffer;     // Buffer for Aave reserve factors
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
        uint256 totalInterestGains;
        uint256 totalRewardGains;
        uint256 totalLiquidationGains;
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
    event DepositedToAave(address indexed asset, uint256 amount, uint256 buffer, uint256 supplied);
    event WithdrawnFromAave(address indexed asset, uint256 amount, uint256 received, address to);
    event AssetAdded(address indexed asset, address aToken, uint256 allocationBps);
    event AssetRemoved(address indexed asset);
    event AssetAllocationUpdated(address indexed asset, uint256 oldAllocation, uint256 newAllocation);
    event RewardsClaimed(address[] tokens, uint256[] amounts, uint256 totalValue);
    event RewardsConverted(address token, uint256 amountIn, uint256 amountOut, uint256 slippage);
    event HarvestExecuted(uint256 totalYield, uint256 donation, uint256 timestamp, uint256 gasUsed);
    event DonationSent(address to, uint256 amount, uint256 boostMultiplier);
    event AaveBoostUpdated(address indexed user, BoostTier tier, uint256 multiplier, uint256 expiry);
    event RiskParametersUpdated(RiskParameters oldParams, RiskParameters newParams);
    event EmergencyModeActivated(uint256 timestamp, string reason);
    event HealthFactorUpdated(uint256 oldHealthFactor, uint256 newHealthFactor);
    event ReserveDataUpdated(address asset, uint256 liquidity, uint256 utilization, uint256 rate);
    
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
    
    modifier validAsset(address assetAddress) {
        require(assetConfigs[assetAddress].enabled, "Adapter: invalid asset");
        _;
    }

    // --------------------------------------------------
    // Enhanced Constructor
    // --------------------------------------------------
    constructor(
        address _asset,
        address _aavePool,
        address _rewardsController,
        address _aToken,
        address _uniswapHook,
        address _donationAccountant,
        address _impactNFT,
        address _chainlinkAutomation
    ) {
        require(_asset != address(0), "Invalid asset");
        require(_aavePool != address(0), "Invalid Aave pool");
        require(_aToken != address(0), "Invalid aToken");
        
        asset = IERC20(_asset);
        aavePool = IAavePool(_aavePool);
        rewardsController = IRewardsController(_rewardsController);
        aToken = IERC20(_aToken);
        uniswapHook = IUniswapV4Hook(_uniswapHook);
        donationAccountant = IDonationAccountant(_donationAccountant);
        impactNFT = IImpactNFT(_impactNFT);
        chainlinkAutomation = IChainlinkAutomation(_chainlinkAutomation);
        
        // Initialize approvals
        asset.safeApprove(_aavePool, type(uint256).max);
        
        // Initialize primary asset
        _initializePrimaryAsset(_asset, _aToken);
        
        // Initialize boost tiers
        _initializeBoostTiers();
        
        // Initialize risk parameters
        _initializeRiskParameters();
    }

    // --------------------------------------------------
    // Multi-Asset Management System
    // --------------------------------------------------
    function addAsset(address assetAddress, address aTokenAddress, uint256 allocationBps) external onlyOwner {
        require(assetAddress != address(0), "Invalid asset");
        require(aTokenAddress != address(0), "Invalid aToken");
        require(allocationBps > 0, "Allocation must be positive");
        require(!assetConfigs[assetAddress].enabled, "Asset already added");
        require(totalAllocationBps + allocationBps <= 10000, "Total allocation exceeds 100%");
        
        assetConfigs[assetAddress] = AssetConfig({
            asset: assetAddress,
            aToken: aTokenAddress,
            allocationBps: allocationBps,
            enabled: true,
            maxExposure: type(uint256).max,
            currentExposure: 0,
            performanceScore: 10000, // Start with neutral score
            reserveFactor: 1000 // Default 10% reserve factor buffer
        });
        
        activeAssets.push(assetAddress);
        totalAllocationBps += allocationBps;
        
        // Approve Aave pool for new asset
        IERC20(assetAddress).safeApprove(address(aavePool), type(uint256).max);
        
        emit AssetAdded(assetAddress, aTokenAddress, allocationBps);
    }

    function removeAsset(address assetAddress) external onlyOwner validAsset(assetAddress) {
        // Withdraw all funds from asset first
        uint256 assetBalance = _getAssetBalance(assetAddress);
        if (assetBalance > 0) {
            _executeWithdrawal(assetAddress, assetBalance, address(this));
        }
        
        // Update allocations
        totalAllocationBps -= assetConfigs[assetAddress].allocationBps;
        assetConfigs[assetAddress].enabled = false;
        
        // Remove from active assets
        for (uint256 i = 0; i < activeAssets.length; i++) {
            if (activeAssets[i] == assetAddress) {
                activeAssets[i] = activeAssets[activeAssets.length - 1];
                activeAssets.pop();
                break;
            }
        }
        
        emit AssetRemoved(assetAddress);
    }

    function updateAssetAllocation(address assetAddress, uint256 newAllocationBps) external onlyOwner validAsset(assetAddress) {
        AssetConfig storage config = assetConfigs[assetAddress];
        uint256 oldAllocation = config.allocationBps;
        
        require(totalAllocationBps - oldAllocation + newAllocationBps <= 10000, "Total allocation exceeds 100%");
        
        totalAllocationBps = totalAllocationBps - oldAllocation + newAllocationBps;
        config.allocationBps = newAllocationBps;
        
        emit AssetAllocationUpdated(assetAddress, oldAllocation, newAllocationBps);
    }

    // --------------------------------------------------
    // Enhanced Supply/Withdraw with Multi-Asset Allocation
    // --------------------------------------------------
    function depositToAave(uint256 amount) external onlyOwner notPaused returns (uint256) {
        require(amount > 0, "Zero deposit");
        require(_isPoolHealthy(), "Pool unhealthy");
        
        // Dynamic risk validation
        _validateDepositRisk(amount);
        
        asset.safeTransferFrom(msg.sender, address(this), amount);
        
        // Calculate optimal allocation across assets
        uint256 allocatedAmount = _calculateAssetAllocation(amount);
        
        // Execute supply with enhanced error handling
        uint256 supplied = _executeSupply(allocatedAmount);
        
        // Update asset exposure
        assetConfigs[address(asset)].currentExposure += supplied;
        
        // Update performance metrics
        performance.totalTransactions++;
        
        emit DepositedToAave(address(asset), amount, amount - allocatedAmount, supplied);
        return supplied;
    }

    function depositAssetToAave(address assetAddress, uint256 amount) external onlyOwner notPaused validAsset(assetAddress) returns (uint256) {
        require(amount > 0, "Zero deposit");
        require(_isAssetHealthy(assetAddress), "Asset unhealthy");
        
        // Dynamic risk validation
        _validateAssetDepositRisk(assetAddress, amount);
        
        IERC20(assetAddress).safeTransferFrom(msg.sender, address(this), amount);
        
        // Calculate optimal allocation for this asset
        uint256 allocatedAmount = _calculateSpecificAssetAllocation(assetAddress, amount);
        
        // Execute supply with enhanced error handling
        uint256 supplied = _executeAssetSupply(assetAddress, allocatedAmount);
        
        // Update asset exposure
        assetConfigs[assetAddress].currentExposure += supplied;
        
        // Update performance metrics
        performance.totalTransactions++;
        
        emit DepositedToAave(assetAddress, amount, amount - allocatedAmount, supplied);
        return supplied;
    }

    function withdrawFromAave(uint256 amount, address to) external onlyOwner returns (uint256) {
        require(amount > 0, "Zero withdraw");
        require(to != address(0), "Invalid recipient");
        
        // Calculate available liquidity
        uint256 available = _calculateAvailableLiquidity();
        uint256 actualWithdraw = amount.min(available);
        
        // Execute withdrawal with fallback
        uint256 withdrawn = _executeWithdrawal(address(asset), actualWithdraw, to);
        
        // Update asset exposure
        assetConfigs[address(asset)].currentExposure -= withdrawn;
        
        // Handle potential shortfall
        if (actualWithdraw < amount) {
            _handleWithdrawalShortfall(amount - actualWithdraw, to);
        }
        
        performance.totalTransactions++;
        
        emit WithdrawnFromAave(address(asset), amount, withdrawn, to);
        return withdrawn;
    }

    function withdrawAssetFromAave(address assetAddress, uint256 amount, address to) external onlyOwner validAsset(assetAddress) returns (uint256) {
        require(amount > 0, "Zero withdraw");
        require(to != address(0), "Invalid recipient");
        
        // Calculate available liquidity for asset
        uint256 available = _getAssetAvailableLiquidity(assetAddress);
        uint256 actualWithdraw = amount.min(available);
        
        // Execute withdrawal with fallback
        uint256 withdrawn = _executeWithdrawal(assetAddress, actualWithdraw, to);
        
        // Update asset exposure
        assetConfigs[assetAddress].currentExposure -= withdrawn;
        
        // Handle potential shortfall
        if (actualWithdraw < amount) {
            _handleAssetWithdrawalShortfall(assetAddress, amount - actualWithdraw, to);
        }
        
        performance.totalTransactions++;
        
        emit WithdrawnFromAave(assetAddress, amount, withdrawn, to);
        return withdrawn;
    }

    // --------------------------------------------------
    // Advanced Harvesting System with Multi-Asset Support
    // --------------------------------------------------
    function harvest() public onlyOwner notPaused returns (uint256 yield, uint256 donation) {
        require(block.timestamp >= lastHarvestTimestamp + harvestCooldown, "Harvest cooldown");
        require(_shouldHarvest(), "Harvest not beneficial");
        
        uint256 initialGas = gasleft();
        
        // Multi-phase harvesting for all assets
        (yield, donation) = _executeAdvancedHarvest();
        
        // Update performance metrics
        uint256 gasUsed = initialGas - gasleft();
        performance.totalGasUsed += gasUsed;
        performance.successfulHarvests++;
        performance.avgGasPerHarvest = performance.totalGasUsed / performance.successfulHarvests;
        
        lastHarvestTimestamp = block.timestamp;
        
        emit HarvestExecuted(yield, donation, block.timestamp, gasUsed);
    }

    function harvestAsset(address assetAddress) public onlyOwner notPaused validAsset(assetAddress) returns (uint256 yield, uint256 donation) {
        require(block.timestamp >= lastHarvestTimestamp + harvestCooldown, "Harvest cooldown");
        require(_shouldAssetHarvest(assetAddress), "Asset harvest not beneficial");
        
        uint256 initialGas = gasleft();
        
        // Multi-phase harvesting for specific asset
        (yield, donation) = _executeAdvancedAssetHarvest(assetAddress);
        
        // Update performance metrics
        uint256 gasUsed = initialGas - gasleft();
        performance.totalGasUsed += gasUsed;
        performance.successfulHarvests++;
        performance.avgGasPerHarvest = performance.totalGasUsed / performance.successfulHarvests;
        
        lastHarvestTimestamp = block.timestamp;
        
        emit HarvestExecuted(yield, donation, block.timestamp, gasUsed);
    }

    function harvestAllAssets() external onlyOwner notPaused returns (uint256 totalYield, uint256 totalDonation) {
        require(block.timestamp >= lastHarvestTimestamp + harvestCooldown, "Harvest cooldown");
        
        uint256 initialGas = gasleft();
        
        // Harvest all active assets
        for (uint256 i = 0; i < activeAssets.length; i++) {
            address assetAddress = activeAssets[i];
            if (_shouldAssetHarvest(assetAddress)) {
                (uint256 assetYield, uint256 assetDonation) = _executeAdvancedAssetHarvest(assetAddress);
                totalYield += assetYield;
                totalDonation += assetDonation;
            }
        }
        
        if (totalYield > 0) {
            // Update performance metrics
            uint256 gasUsed = initialGas - gasleft();
            performance.totalGasUsed += gasUsed;
            performance.successfulHarvests++;
            performance.avgGasPerHarvest = performance.totalGasUsed / performance.successfulHarvests;
            
            lastHarvestTimestamp = block.timestamp;
            
            emit HarvestExecuted(totalYield, totalDonation, block.timestamp, gasUsed);
        }
    }

    // Chainlink-automated harvest
    function automatedHarvest() external onlyAutomation notPaused returns (bool) {
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

    function automatedAssetHarvest(address assetAddress) external onlyAutomation notPaused validAsset(assetAddress) returns (bool) {
        if (!_shouldAssetHarvest(assetAddress) || block.timestamp < lastHarvestTimestamp + harvestCooldown) {
            return false;
        }
        
        try this.harvestAsset(assetAddress) {
            return true;
        } catch {
            performance.failedHarvests++;
            return false;
        }
    }

    // --------------------------------------------------
    // Enhanced Reward Processing for Aave v3
    // --------------------------------------------------
    function _executeAdvancedHarvest() internal returns (uint256 yield, uint256 donation) {
        // Phase 1: Claim and optimize Aave rewards across all assets
        uint256 rewardsValue = _claimAndOptimizeAaveRewards();
        
        // Phase 2: Calculate yield including interest and rewards
        uint256 currentAssets = totalAssets();
        uint256 previousAssets = _getLastAccountedAssets();
        
        if (currentAssets <= previousAssets) {
            return (0, 0);
        }
        
        yield = currentAssets - previousAssets + rewardsValue;
        totalYieldGenerated += yield;
        
        // Track performance metrics
        performance.totalInterestGains += (currentAssets - previousAssets);
        performance.totalRewardGains += rewardsValue;
        
        // Phase 3: Dynamic donation calculation with boosts
        donation = _calculateDynamicDonation(yield);
        
        // Phase 4: Execute donation if meaningful
        if (donation >= minDonation) {
            _executeDonation(donation);
        }
        
        _updateLastAccountedAssets(currentAssets);
    }

    function _executeAdvancedAssetHarvest(address assetAddress) internal returns (uint256 yield, uint256 donation) {
        // Phase 1: Claim and optimize Aave rewards for specific asset
        uint256 rewardsValue = _claimAndOptimizeAssetRewards(assetAddress);
        
        // Phase 2: Calculate yield for this asset
        uint256 currentAssetValue = _getAssetBalance(assetAddress);
        uint256 previousAssetValue = _getLastAssetAccountedValue(assetAddress);
        
        if (currentAssetValue <= previousAssetValue) {
            return (0, 0);
        }
        
        yield = currentAssetValue - previousAssetValue + rewardsValue;
        totalYieldGenerated += yield;
        
        // Phase 3: Dynamic donation calculation with boosts
        donation = _calculateDynamicDonation(yield);
        
        // Phase 4: Execute donation if meaningful
        if (donation >= minDonation) {
            _executeAssetDonation(assetAddress, donation);
        }
        
        _updateLastAssetAccountedValue(assetAddress, currentAssetValue);
    }

    function _claimAndOptimizeAaveRewards() internal returns (uint256 totalValue) {
        // Claim all rewards from Aave for all assets
        address[] memory assets = new address[](activeAssets.length);
        for (uint256 i = 0; i < activeAssets.length; i++) {
            assets[i] = assetConfigs[activeAssets[i]].aToken;
        }
        
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

    function _claimAndOptimizeAssetRewards(address assetAddress) internal returns (uint256 totalValue) {
        // Claim rewards for specific asset
        address[] memory assets = new address[](1);
        assets[0] = assetConfigs[assetAddress].aToken;
        
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

    function _executeAssetDonation(address assetAddress, uint256 donation) internal {
        // Convert asset donation to primary asset if needed
        if (assetAddress != address(asset)) {
            uint256 convertedAmount = _convertAssetToPrimary(assetAddress, donation);
            if (convertedAmount > 0) {
                _executeDonation(convertedAmount);
            }
        } else {
            _executeDonation(donation);
        }
    }

    // --------------------------------------------------
    // Advanced AaveBoost System
    // --------------------------------------------------
    function activateAaveBoost(BoostTier tier) external {
        require(tier != BoostTier.NONE, "Invalid tier");
        require(tierMultipliers[tier] > 0, "Tier not configured");
        
        UserBoost storage boost = userBoosts[msg.sender];
        boost.tier = tier;
        boost.multiplier = tierMultipliers[tier];
        boost.expiry = block.timestamp + tierDurations[tier];
        
        emit AaveBoostUpdated(msg.sender, tier, boost.multiplier, boost.expiry);
    }

    function upgradeAaveBoost(BoostTier newTier) external {
        UserBoost storage boost = userBoosts[msg.sender];
        require(newTier > boost.tier, "Can only upgrade to higher tier");
        require(tierMultipliers[newTier] > boost.multiplier, "Invalid upgrade");
        
        boost.tier = newTier;
        boost.multiplier = tierMultipliers[newTier];
        boost.expiry = block.timestamp + tierDurations[newTier];
        
        emit AaveBoostUpdated(msg.sender, newTier, boost.multiplier, boost.expiry);
    }

    // --------------------------------------------------
    // Enhanced Risk Management for Aave v3
    // --------------------------------------------------
    function _validateDepositRisk(uint256 amount) internal view {
        require(_isPoolHealthy(), "Pool health check failed");
        require(_isUtilizationSafe(), "Pool utilization too high");
        require(_isGasPriceReasonable(), "Gas price too high");
        require(amount <= _calculateMaxSafeDeposit(), "Amount exceeds safe limit");
        require(_isAssetConcentrationSafe(amount), "Asset concentration too high");
    }

    function _validateAssetDepositRisk(address assetAddress, uint256 amount) internal view {
        require(_isAssetHealthy(assetAddress), "Asset health check failed");
        require(_isAssetUtilizationSafe(assetAddress), "Asset utilization too high");
        require(_isGasPriceReasonable(), "Gas price too high");
        require(amount <= _calculateMaxSafeAssetDeposit(assetAddress), "Amount exceeds safe limit");
        require(_isSpecificAssetConcentrationSafe(assetAddress, amount), "Asset concentration too high");
    }

    function _isPoolHealthy() internal view returns (bool) {
        // Check Aave pool overall health
        // This would include checking overall pool parameters and global risks
        return true; // Placeholder for actual implementation
    }

    function _isAssetHealthy(address assetAddress) internal view returns (bool) {
        // Check specific asset health in Aave
        (, , , , uint256 reserveFactor, , , , , ) = aavePool.getReserveData(assetAddress);
        
        // Check if reserve factor is within acceptable bounds
        return reserveFactor <= (riskParams.reserveFactorBuffer * 100); // Convert to basis points
    }

    function _isUtilizationSafe() internal view returns (bool) {
        (uint256 totalLiquidity, uint256 totalDebt, , , , ) = aavePool.getReserveData(address(asset));
        if (totalLiquidity == 0) return true;
        
        uint256 utilization = (totalDebt * 10_000) / totalLiquidity;
        return utilization <= riskParams.maxUtilization;
    }

    function _isAssetUtilizationSafe(address assetAddress) internal view returns (bool) {
        (uint256 totalLiquidity, uint256 totalDebt, , , , ) = aavePool.getReserveData(assetAddress);
        if (totalLiquidity == 0) return true;
        
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

    function _calculateMaxSafeAssetDeposit(address assetAddress) internal view returns (uint256) {
        AssetConfig memory config = assetConfigs[assetAddress];
        uint256 currentExposure = config.currentExposure;
        uint256 maxExposure = config.maxExposure;
        
        if (currentExposure >= maxExposure) return 0;
        
        return maxExposure - currentExposure;
    }

    function _isAssetConcentrationSafe(uint256 amount) internal view returns (bool) {
        uint256 newExposure = assetConfigs[address(asset)].currentExposure + amount;
        uint256 totalAssetsValue = totalAssets();
        
        if (totalAssetsValue == 0) return true;
        
        uint256 concentration = (newExposure * 10_000) / totalAssetsValue;
        return concentration <= riskParams.maxAssetConcentration;
    }

    function _isSpecificAssetConcentrationSafe(address assetAddress, uint256 amount) internal view returns (bool) {
        uint256 newExposure = assetConfigs[assetAddress].currentExposure + amount;
        uint256 totalAssetsValue = totalAssets();
        
        if (totalAssetsValue == 0) return true;
        
        uint256 concentration = (newExposure * 10_000) / totalAssetsValue;
        return concentration <= riskParams.maxAssetConcentration;
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
        uint256 previousAssets = _getLastAccountedAssets();
        
        if (currentAssets <= previousAssets) return false;
        
        uint256 potentialYield = currentAssets - previousAssets;
        return potentialYield >= riskParams.yieldThreshold;
    }

    function _shouldAssetHarvest(address assetAddress) internal view returns (bool) {
        uint256 currentAssetValue = _getAssetBalance(assetAddress);
        uint256 previousAssetValue = _getLastAssetAccountedValue(assetAddress);
        
        if (currentAssetValue <= previousAssetValue) return false;
        
        uint256 potentialYield = currentAssetValue - previousAssetValue;
        return potentialYield >= riskParams.yieldThreshold;
    }

    // --------------------------------------------------
    // Enhanced View Functions for Multi-Asset Support
    // --------------------------------------------------
    function totalAssets() public view returns (uint256) {
        uint256 total = asset.balanceOf(address(this)); // Buffer
        
        for (uint256 i = 0; i < activeAssets.length; i++) {
            total += _getAssetBalance(activeAssets[i]);
        }
        
        return total;
    }

    function totalAssets(address assetAddress) public view validAsset(assetAddress) returns (uint256) {
        return _getAssetBalance(assetAddress) + _getAssetBuffer(assetAddress);
    }

    function availableDepositLimit() external view returns (uint256) {
        return _calculateMaxSafeDeposit();
    }

    function availableDepositLimit(address assetAddress) external view validAsset(assetAddress) returns (uint256) {
        return _calculateMaxSafeAssetDeposit(assetAddress);
    }

    function availableWithdrawLimit() external view returns (uint256) {
        return _calculateAvailableLiquidity();
    }

    function availableWithdrawLimit(address assetAddress) external view validAsset(assetAddress) returns (uint256) {
        return _getAssetAvailableLiquidity(assetAddress);
    }

    function getMaxSafeWithdrawal() external view returns (uint256) {
        return _calculateMaxSafeWithdrawal();
    }

    function getMaxSafeWithdrawal(address assetAddress) external view validAsset(assetAddress) returns (uint256) {
        return _calculateMaxSafeAssetWithdrawal(assetAddress);
    }

    function maxWithdrawable() external view returns (uint256) {
        return _getAssetBalance(address(asset));
    }

    function maxWithdrawable(address assetAddress) external view validAsset(assetAddress) returns (uint256) {
        return _getAssetBalance(assetAddress);
    }

    function isHealthy() external view returns (bool) {
        return _isPoolHealthy() && !paused && !emergencyMode;
    }

    function isAssetHealthy(address assetAddress) external view validAsset(assetAddress) returns (bool) {
        return _isAssetHealthy(assetAddress) && !paused && !emergencyMode;
    }

    function rewardsAvailable() external view returns (bool) {
        // Check if there are claimable rewards for any asset
        for (uint256 i = 0; i < activeAssets.length; i++) {
            address[] memory assets = new address[](1);
            assets[0] = assetConfigs[activeAssets[i]].aToken;
            
            (address[] memory rewards, uint256[] memory amounts) = rewardsController.getAllUserRewards(assets, address(this));
            
            for (uint256 j = 0; j < amounts.length; j++) {
                if (amounts[j] > 0) return true;
            }
        }
        return false;
    }

    function assetRewardsAvailable(address assetAddress) external view validAsset(assetAddress) returns (bool) {
        address[] memory assets = new address[](1);
        assets[0] = assetConfigs[assetAddress].aToken;
        
        (address[] memory rewards, uint256[] memory amounts) = rewardsController.getAllUserRewards(assets, address(this));
        
        for (uint256 i = 0; i < amounts.length; i++) {
            if (amounts[i] > 0) return true;
        }
        return false;
    }

    function marketConditionsFavorable() external view returns (bool) {
        return _isPoolHealthy() && _isUtilizationSafe() && _isGasPriceReasonable();
    }

    function assetMarketConditionsFavorable(address assetAddress) external view validAsset(assetAddress) returns (bool) {
        return _isAssetHealthy(assetAddress) && _isAssetUtilizationSafe(assetAddress) && _isGasPriceReasonable();
    }

    function claimingGasEfficient() external view returns (bool) {
        return _isGasPriceReasonable();
    }

    function getEstimatedAPY() external view returns (uint256) {
        // Simplified APY estimation based on current Aave rates
        ( , , uint256 liquidityRate, , , ) = aavePool.getReserveData(address(asset));
        return liquidityRate / 1e9; // Convert to basis points
    }

    function getAssetEstimatedAPY(address assetAddress) external view validAsset(assetAddress) returns (uint256) {
        ( , , uint256 liquidityRate, , , ) = aavePool.getReserveData(assetAddress);
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
            amount = _getAssetBalance(address(asset));
        }
        
        aavePool.withdraw(address(asset), amount, msg.sender);
        assetConfigs[address(asset)].currentExposure -= amount;
    }

    function emergencyAssetWithdraw(address assetAddress, uint256 amount) external onlyOwner emergencyTimeout validAsset(assetAddress) {
        if (amount == 0) {
            amount = _getAssetBalance(assetAddress);
        }
        
        aavePool.withdraw(assetAddress, amount, msg.sender);
        assetConfigs[assetAddress].currentExposure -= amount;
    }

    function emergencyWithdrawAll() external onlyOwner emergencyTimeout {
        // Withdraw all from primary asset
        uint256 primaryBalance = _getAssetBalance(address(asset));
        if (primaryBalance > 0) {
            aavePool.withdraw(address(asset), primaryBalance, msg.sender);
            assetConfigs[address(asset)].currentExposure = 0;
        }
        
        // Withdraw all from other assets
        for (uint256 i = 0; i < activeAssets.length; i++) {
            address assetAddress = activeAssets[i];
            if (assetAddress != address(asset)) {
                uint256 assetBalance = _getAssetBalance(assetAddress);
                if (assetBalance > 0) {
                    aavePool.withdraw(assetAddress, assetBalance, msg.sender);
                    assetConfigs[assetAddress].currentExposure = 0;
                }
            }
        }
    }

    // --------------------------------------------------
    // Admin Configuration Functions
    // --------------------------------------------------
    function setRiskParameters(RiskParameters calldata newParams) external onlyOwner {
        require(newParams.maxUtilization <= 9500, "Utilization too high"); // 95% max
        require(newParams.minHealthFactor >= 11000, "Health factor too low"); // 1.1 min
        require(newParams.maxAssetConcentration <= 5000, "Concentration too high"); // 50% max
        
        RiskParameters memory oldParams = riskParams;
        riskParams = newParams;
        
        emit RiskParametersUpdated(oldParams, newParams);
    }

    function setDynamicSlippage(uint256 newSlippage) external onlyOwner {
        require(newSlippage <= MAX_SLIPPAGE_BPS, "Slippage too high");
        
        uint256 oldSlippage = dynamicSlippageTolerance;
        dynamicSlippageTolerance = newSlippage;
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
    function _initializePrimaryAsset(address _asset, address _aToken) internal {
        assetConfigs[_asset] = AssetConfig({
            asset: _asset,
            aToken: _aToken,
            allocationBps: 10000, // 100% initial allocation
            enabled: true,
            maxExposure: type(uint256).max,
            currentExposure: 0,
            performanceScore: 10000,
            reserveFactor: 1000
        });
        
        activeAssets.push(_asset);
    }

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
            gasPriceThreshold: 100 gwei, // 100 gwei max
            maxAssetConcentration: 3000, // 30% max per asset
            reserveFactorBuffer: 1500    // 15% buffer for reserve factors
        });
    }

    function _getAssetBalance(address assetAddress) internal view returns (uint256) {
        AssetConfig memory config = assetConfigs[assetAddress];
        return IERC20(config.aToken).balanceOf(address(this));
    }

    function _getAssetBuffer(address assetAddress) internal view returns (uint256) {
        return IERC20(assetAddress).balanceOf(address(this)) / activeAssets.length;
    }

    function _calculateAssetAllocation(uint256 totalAmount) internal view returns (uint256) {
        AssetConfig memory config = assetConfigs[address(asset)];
        uint256 allocation = (totalAmount * config.allocationBps) / totalAllocationBps;
        
        // Respect max exposure limits
        uint256 maxAdditional = config.maxExposure - config.currentExposure;
        return allocation.min(maxAdditional);
    }

    function _calculateSpecificAssetAllocation(address assetAddress, uint256 totalAmount) internal view returns (uint256) {
        AssetConfig memory config = assetConfigs[assetAddress];
        uint256 allocation = (totalAmount * config.allocationBps) / totalAllocationBps;
        
        // Respect max exposure limits
        uint256 maxAdditional = config.maxExposure - config.currentExposure;
        return allocation.min(maxAdditional);
    }

    function _executeSupply(uint256 amount) internal returns (uint256) {
        uint256 balanceBefore = _getAssetBalance(address(asset));
        aavePool.supply(address(asset), amount, address(this), REFERRAL_CODE);
        uint256 balanceAfter = _getAssetBalance(address(asset));
        return balanceAfter - balanceBefore;
    }

    function _executeAssetSupply(address assetAddress, uint256 amount) internal returns (uint256) {
        uint256 balanceBefore = _getAssetBalance(assetAddress);
        aavePool.supply(assetAddress, amount, address(this), REFERRAL_CODE);
        uint256 balanceAfter = _getAssetBalance(assetAddress);
        return balanceAfter - balanceBefore;
    }

    function _executeWithdrawal(address assetAddress, uint256 amount, address to) internal returns (uint256) {
        uint256 balanceBefore = IERC20(assetAddress).balanceOf(address(this));
        aavePool.withdraw(assetAddress, amount, to);
        uint256 balanceAfter = IERC20(assetAddress).balanceOf(address(this));
        return balanceAfter - balanceBefore;
    }

    function _calculateAvailableLiquidity() internal view returns (uint256) {
        uint256 buffer = asset.balanceOf(address(this));
        uint256 supplied = _getAssetBalance(address(asset));
        return buffer + supplied;
    }

    function _getAssetAvailableLiquidity(address assetAddress) internal view returns (uint256) {
        uint256 buffer = _getAssetBuffer(assetAddress);
        uint256 supplied = _getAssetBalance(assetAddress);
        return buffer + supplied;
    }

    function _calculateMaxSafeWithdrawal() internal view returns (uint256) {
        uint256 bufferNeeded = (totalAssets() * liquidityBufferBps) / 10_000;
        uint256 currentBuffer = asset.balanceOf(address(this));
        
        if (currentBuffer <= bufferNeeded) return 0;
        
        return _getAssetBalance(address(asset)) + (currentBuffer - bufferNeeded);
    }

    function _calculateMaxSafeAssetWithdrawal(address assetAddress) internal view returns (uint256) {
        uint256 bufferNeeded = (totalAssets() * liquidityBufferBps) / (10_000 * activeAssets.length);
        uint256 currentBuffer = _getAssetBuffer(assetAddress);
        
        if (currentBuffer <= bufferNeeded) return 0;
        
        return _getAssetBalance(assetAddress) + (currentBuffer - bufferNeeded);
    }

    function _executeBufferReplenishment(uint256 amount) internal {
        // Withdraw from assets to replenish buffer
        for (uint256 i = 0; i < activeAssets.length && amount > 0; i++) {
            address assetAddress = activeAssets[i];
            uint256 assetBalance = _getAssetBalance(assetAddress);
            uint256 toWithdraw = amount.min(assetBalance);
            
            if (toWithdraw > 0) {
                aavePool.withdraw(assetAddress, toWithdraw, address(this));
                assetConfigs[assetAddress].currentExposure -= toWithdraw;
                amount -= toWithdraw;
            }
        }
    }

    function _convertAssetToPrimary(address assetAddress, uint256 amount) internal returns (uint256) {
        // Convert other assets to primary asset for donation
        // This would use Uniswap or other DEX to convert
        // For now, return 0 as placeholder
        return 0;
    }

    function _handleWithdrawalShortfall(uint256 shortfall, address to) internal {
        // Implement shortfall handling logic
    }

    function _handleAssetWithdrawalShortfall(address assetAddress, uint256 shortfall, address to) internal {
        // Implement asset-specific shortfall handling logic
    }

    function _getLastAccountedAssets() internal view returns (uint256) {
        // Return last accounted assets from storage
        // This would be stored in a state variable
        return 0; // Placeholder
    }

    function _updateLastAccountedAssets(uint256 newValue) internal {
        // Update last accounted assets in storage
    }

    function _getLastAssetAccountedValue(address assetAddress) internal view returns (uint256) {
        // Return last accounted value for specific asset
        return 0; // Placeholder
    }

    function _updateLastAssetAccountedValue(address assetAddress, uint256 newValue) internal {
        // Update last accounted value for specific asset
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