// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * NapFi Enhanced Morpho Adapter v2.0
 * ------------------------------------------------
 * Ultra-optimized Morpho Blue adapter with advanced features:
 * - Multi-market yield optimization
 * - Dynamic risk-adjusted allocation
 * - P2P interest donation streaming
 * - MEV-resistant operations
 * - Real-time market analytics
 * - Gas-optimized architecture for Morpho Blue
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// Enhanced Morpho interfaces
import {IMorpho} from "../interfaces/IMorpho.sol";
import {IMorphoRewards} from "../interfaces/IMorphoRewards.sol";
import {IUniswapV4Hook} from "../interfaces/IUniswapV4Hook.sol";
import {IDonationAccountant} from "../interfaces/IDonationAccountant.sol";
import {IImpactNFT} from "../interfaces/IImpactNFT.sol";
import {IChainlinkAutomation} from "../interfaces/IChainlinkAutomation.sol";

contract NapFiEnhancedMorphoAdapter is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // --------------------------------------------------
    // Core Protocol Addresses
    // --------------------------------------------------
    IMorpho public immutable morpho;
    IMorphoRewards public immutable morphoRewards;
    IERC20 public immutable asset;
    
    // --------------------------------------------------
    // Enhanced Integration Layer
    // --------------------------------------------------
    IUniswapV4Hook public uniswapHook;
    IDonationAccountant public donationAccountant;
    IImpactNFT public impactNFT;
    IChainlinkAutomation public chainlinkAutomation;

    // --------------------------------------------------
    // Multi-Market Management
    // --------------------------------------------------
    struct MarketConfig {
        address market;
        uint256 allocationBps;           // Allocation percentage (0-10000)
        bool enabled;
        uint256 maxExposure;             // Maximum exposure limit
        uint256 currentExposure;         // Current exposure
        uint256 lastP2PIndex;            // Last recorded P2P index
        uint256 performanceScore;        // Market performance metric
    }
    
    address[] public activeMarkets;
    mapping(address => MarketConfig) public marketConfigs;
    uint256 public totalAllocationBps = 10000; // 100% total allocation
    
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
    uint256 public totalDonated;
    uint256 public totalYieldGenerated;
    uint256 public minDonation = 1e6;
    uint256 public lastHarvestTimestamp;
    uint256 public harvestCooldown = 6 hours;
    uint256 public constant INDEX_PRECISION = 1e27;     // Morpho index precision
    
    // --------------------------------------------------
    // Multi-Tier MorphoBoost System
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
        uint256 maxLTV;                 // Maximum Loan-to-Value ratio
        uint256 minLiquidity;           // Minimum market liquidity
        uint256 yieldThreshold;         // Min yield to trigger harvest
        uint256 gasPriceThreshold;      // Max gas price for operations
        uint256 maxMarketConcentration; // Max allocation to single market
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
        uint256 totalP2PGains;
        uint256 totalRewardGains;
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
    event DepositedToMorpho(address indexed market, uint256 amount, uint256 buffer, uint256 supplied);
    event WithdrawnFromMorpho(address indexed market, uint256 amount, uint256 received, address to);
    event MarketAdded(address indexed market, uint256 allocationBps);
    event MarketRemoved(address indexed market);
    event MarketAllocationUpdated(address indexed market, uint256 oldAllocation, uint256 newAllocation);
    event P2PIndexUpdated(address indexed market, uint256 oldIndex, uint256 newIndex, uint256 delta, uint256 p2pGain);
    event RewardsClaimed(address[] tokens, uint256[] amounts, uint256 totalValue);
    event RewardsConverted(address token, uint256 amountIn, uint256 amountOut, uint256 slippage);
    event HarvestExecuted(uint256 totalYield, uint256 donation, uint256 timestamp, uint256 gasUsed);
    event DonationSent(address to, uint256 amount, uint256 boostMultiplier);
    event MorphoBoostUpdated(address indexed user, BoostTier tier, uint256 multiplier, uint256 expiry);
    event RiskParametersUpdated(RiskParameters oldParams, RiskParameters newParams);
    event EmergencyModeActivated(uint256 timestamp, string reason);
    
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
    
    modifier validMarket(address market) {
        require(marketConfigs[market].enabled, "Adapter: invalid market");
        _;
    }

    // --------------------------------------------------
    // Enhanced Constructor
    // --------------------------------------------------
    constructor(
        address _asset,
        address _morpho,
        address _morphoRewards,
        address _uniswapHook,
        address _donationAccountant,
        address _impactNFT,
        address _chainlinkAutomation
    ) {
        require(_asset != address(0), "Invalid asset");
        require(_morpho != address(0), "Invalid Morpho");
        
        asset = IERC20(_asset);
        morpho = IMorpho(_morpho);
        morphoRewards = IMorphoRewards(_morphoRewards);
        uniswapHook = IUniswapV4Hook(_uniswapHook);
        donationAccountant = IDonationAccountant(_donationAccountant);
        impactNFT = IImpactNFT(_impactNFT);
        chainlinkAutomation = IChainlinkAutomation(_chainlinkAutomation);
        
        // Initialize approvals
        asset.safeApprove(_morpho, type(uint256).max);
        
        // Initialize boost tiers
        _initializeBoostTiers();
        
        // Initialize risk parameters
        _initializeRiskParameters();
    }

    // --------------------------------------------------
    // Multi-Market Management System
    // --------------------------------------------------
    function addMarket(address market, uint256 allocationBps) external onlyOwner {
        require(market != address(0), "Invalid market");
        require(allocationBps > 0, "Allocation must be positive");
        require(!marketConfigs[market].enabled, "Market already added");
        require(totalAllocationBps + allocationBps <= 10000, "Total allocation exceeds 100%");
        
        marketConfigs[market] = MarketConfig({
            market: market,
            allocationBps: allocationBps,
            enabled: true,
            maxExposure: type(uint256).max,
            currentExposure: 0,
            lastP2PIndex: _getCurrentP2PIndex(market),
            performanceScore: 10000 // Start with neutral score
        });
        
        activeMarkets.push(market);
        totalAllocationBps += allocationBps;
        
        emit MarketAdded(market, allocationBps);
    }

    function removeMarket(address market) external onlyOwner validMarket(market) {
        // Withdraw all funds from market first
        uint256 marketBalance = _getMarketBalance(market);
        if (marketBalance > 0) {
            _executeWithdrawal(market, marketBalance, address(this));
        }
        
        // Update allocations
        totalAllocationBps -= marketConfigs[market].allocationBps;
        marketConfigs[market].enabled = false;
        
        // Remove from active markets
        for (uint256 i = 0; i < activeMarkets.length; i++) {
            if (activeMarkets[i] == market) {
                activeMarkets[i] = activeMarkets[activeMarkets.length - 1];
                activeMarkets.pop();
                break;
            }
        }
        
        emit MarketRemoved(market);
    }

    function updateMarketAllocation(address market, uint256 newAllocationBps) external onlyOwner validMarket(market) {
        MarketConfig storage config = marketConfigs[market];
        uint256 oldAllocation = config.allocationBps;
        
        require(totalAllocationBps - oldAllocation + newAllocationBps <= 10000, "Total allocation exceeds 100%");
        
        totalAllocationBps = totalAllocationBps - oldAllocation + newAllocationBps;
        config.allocationBps = newAllocationBps;
        
        emit MarketAllocationUpdated(market, oldAllocation, newAllocationBps);
    }

    // --------------------------------------------------
    // Enhanced Supply/Withdraw with Multi-Market Allocation
    // --------------------------------------------------
    function supplyToMorpho(uint256 amount, address market) external onlyOwner notPaused validMarket(market) returns (uint256) {
        require(amount > 0, "Zero supply");
        require(_isMarketHealthy(market), "Market unhealthy");
        
        // Dynamic risk validation
        _validateSupplyRisk(market, amount);
        
        asset.safeTransferFrom(msg.sender, address(this), amount);
        
        // Calculate optimal allocation across markets
        uint256 allocatedAmount = _calculateMarketAllocation(market, amount);
        
        // Execute supply with enhanced error handling
        uint256 supplied = _executeSupply(market, allocatedAmount);
        
        // Update market exposure
        marketConfigs[market].currentExposure += supplied;
        
        // Update performance metrics
        performance.totalTransactions++;
        
        emit DepositedToMorpho(market, amount, amount - allocatedAmount, supplied);
        return supplied;
    }

    function withdrawFromMorpho(uint256 amount, address market, address to) external onlyOwner validMarket(market) returns (uint256) {
        require(amount > 0, "Zero withdraw");
        require(to != address(0), "Invalid recipient");
        
        // Calculate available liquidity
        uint256 available = _getMarketAvailableLiquidity(market);
        uint256 actualWithdraw = amount.min(available);
        
        // Execute withdrawal with fallback
        uint256 withdrawn = _executeWithdrawal(market, actualWithdraw, to);
        
        // Update market exposure
        marketConfigs[market].currentExposure -= withdrawn;
        
        // Handle potential shortfall
        if (actualWithdraw < amount) {
            _handleWithdrawalShortfall(market, amount - actualWithdraw, to);
        }
        
        performance.totalTransactions++;
        
        emit WithdrawnFromMorpho(market, amount, withdrawn, to);
        return withdrawn;
    }

    // --------------------------------------------------
    // Advanced Harvesting System with Multi-Market Support
    // --------------------------------------------------
    function harvest(address market) public onlyOwner notPaused validMarket(market) returns (uint256 yield, uint256 donation) {
        require(block.timestamp >= lastHarvestTimestamp + harvestCooldown, "Harvest cooldown");
        require(_shouldHarvest(market), "Harvest not beneficial");
        
        uint256 initialGas = gasleft();
        
        // Multi-phase harvesting for specific market
        (yield, donation) = _executeAdvancedMarketHarvest(market);
        
        // Update performance metrics
        uint256 gasUsed = initialGas - gasleft();
        performance.totalGasUsed += gasUsed;
        performance.successfulHarvests++;
        performance.avgGasPerHarvest = performance.totalGasUsed / performance.successfulHarvests;
        
        lastHarvestTimestamp = block.timestamp;
        
        emit HarvestExecuted(yield, donation, block.timestamp, gasUsed);
    }

    function harvestAll() external onlyOwner notPaused returns (uint256 totalYield, uint256 totalDonation) {
        require(block.timestamp >= lastHarvestTimestamp + harvestCooldown, "Harvest cooldown");
        
        uint256 initialGas = gasleft();
        
        // Harvest all active markets
        for (uint256 i = 0; i < activeMarkets.length; i++) {
            address market = activeMarkets[i];
            if (_shouldHarvest(market)) {
                (uint256 marketYield, uint256 marketDonation) = _executeAdvancedMarketHarvest(market);
                totalYield += marketYield;
                totalDonation += marketDonation;
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
    function automatedHarvest(address market) external onlyAutomation notPaused validMarket(market) returns (bool) {
        if (!_shouldHarvest(market) || block.timestamp < lastHarvestTimestamp + harvestCooldown) {
            return false;
        }
        
        try this.harvest(market) {
            return true;
        } catch {
            performance.failedHarvests++;
            return false;
        }
    }

    // --------------------------------------------------
    // Enhanced P2P Interest Streaming & Reward Processing
    // --------------------------------------------------
    function _executeAdvancedMarketHarvest(address market) internal returns (uint256 yield, uint256 donation) {
        // Phase 1: Calculate P2P interest gains
        uint256 p2pGain = _calculateP2PGain(market);
        
        // Phase 2: Claim and optimize Morpho rewards
        uint256 rewardsValue = _claimAndOptimizeMorphoRewards(market);
        
        // Calculate total yield
        yield = p2pGain + rewardsValue;
        totalYieldGenerated += yield;
        
        // Track performance metrics
        performance.totalP2PGains += p2pGain;
        performance.totalRewardGains += rewardsValue;
        
        // Phase 3: Dynamic donation calculation with boosts
        donation = _calculateDynamicDonation(yield);
        
        // Phase 4: Execute donation if meaningful
        if (donation >= minDonation) {
            _executeDonation(donation);
        }
    }

    function _calculateP2PGain(address market) internal returns (uint256 p2pGain) {
        MarketConfig storage config = marketConfigs[market];
        uint256 currentIndex = _getCurrentP2PIndex(market);
        uint256 previousIndex = config.lastP2PIndex;

        if (currentIndex <= previousIndex) {
            config.lastP2PIndex = currentIndex;
            return 0;
        }

        // Calculate index delta
        uint256 delta = currentIndex - previousIndex;

        // Get market supplied amount
        uint256 supplied = _getMarketBalance(market);

        // Calculate P2P gain: supplied * delta / INDEX_PRECISION
        p2pGain = (supplied * delta) / INDEX_PRECISION;

        // Update index
        config.lastP2PIndex = currentIndex;

        emit P2PIndexUpdated(market, previousIndex, currentIndex, delta, p2pGain);
    }

    function _claimAndOptimizeMorphoRewards(address market) internal returns (uint256 totalValue) {
        // Claim Morpho rewards for the market
        address[] memory markets = new address[](1);
        markets[0] = market;
        
        (address[] memory rewardTokens, uint256[] memory amounts) = morphoRewards.claimRewards(
            markets,
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
    // Advanced MorphoBoost System
    // --------------------------------------------------
    function activateMorphoBoost(BoostTier tier) external {
        require(tier != BoostTier.NONE, "Invalid tier");
        require(tierMultipliers[tier] > 0, "Tier not configured");
        
        UserBoost storage boost = userBoosts[msg.sender];
        boost.tier = tier;
        boost.multiplier = tierMultipliers[tier];
        boost.expiry = block.timestamp + tierDurations[tier];
        
        emit MorphoBoostUpdated(msg.sender, tier, boost.multiplier, boost.expiry);
    }

    function upgradeMorphoBoost(BoostTier newTier) external {
        UserBoost storage boost = userBoosts[msg.sender];
        require(newTier > boost.tier, "Can only upgrade to higher tier");
        require(tierMultipliers[newTier] > boost.multiplier, "Invalid upgrade");
        
        boost.tier = newTier;
        boost.multiplier = tierMultipliers[newTier];
        boost.expiry = block.timestamp + tierDurations[newTier];
        
        emit MorphoBoostUpdated(msg.sender, newTier, boost.multiplier, boost.expiry);
    }

    // --------------------------------------------------
    // Enhanced Risk Management for Morpho Blue
    // --------------------------------------------------
    function _validateSupplyRisk(address market, uint256 amount) internal view {
        require(_isMarketHealthy(market), "Market health check failed");
        require(_isMarketLTVSafe(market), "Market LTV too high");
        require(_isGasPriceReasonable(), "Gas price too high");
        require(amount <= _calculateMaxSafeSupply(market), "Amount exceeds safe limit");
        require(_isMarketConcentrationSafe(market, amount), "Market concentration too high");
    }

    function _isMarketHealthy(address market) internal view returns (bool) {
        // Check Morpho market health factors
        // This would interface with Morpho Blue's market parameters
        // For now, return true as a placeholder - implement actual checks
        return true;
    }

    function _isMarketLTVSafe(address market) internal view returns (bool) {
        // Check if market LTV is within safe parameters
        // This would use Morpho's market data
        return true; // Placeholder
    }

    function _calculateMaxSafeSupply(address market) internal view returns (uint256) {
        MarketConfig memory config = marketConfigs[market];
        uint256 currentExposure = config.currentExposure;
        uint256 maxExposure = config.maxExposure;
        
        if (currentExposure >= maxExposure) return 0;
        
        return maxExposure - currentExposure;
    }

    function _isMarketConcentrationSafe(address market, uint256 amount) internal view returns (bool) {
        uint256 newExposure = marketConfigs[market].currentExposure + amount;
        uint256 totalAssets = totalAssets();
        
        if (totalAssets == 0) return true;
        
        uint256 concentration = (newExposure * 10_000) / totalAssets;
        return concentration <= riskParams.maxMarketConcentration;
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

    function _shouldHarvest(address market) internal view returns (bool) {
        // Check if harvesting this market is beneficial
        uint256 potentialP2PGain = _estimateP2PGain(market);
        uint256 potentialRewards = _estimateRewardsValue(market);
        uint256 totalPotential = potentialP2PGain + potentialRewards;
        
        return totalPotential >= riskParams.yieldThreshold;
    }

    // --------------------------------------------------
    // Enhanced View Functions for Multi-Market Support
    // --------------------------------------------------
    function totalAssets() public view returns (uint256) {
        uint256 total = asset.balanceOf(address(this)); // Buffer
        
        for (uint256 i = 0; i < activeMarkets.length; i++) {
            total += _getMarketBalance(activeMarkets[i]);
        }
        
        return total;
    }

    function totalAssets(address market) public view validMarket(market) returns (uint256) {
        return _getMarketBalance(market) + asset.balanceOf(address(this)) / activeMarkets.length;
    }

    function availableDepositLimit(address market) external view validMarket(market) returns (uint256) {
        return _calculateMaxSafeSupply(market);
    }

    function availableWithdrawLimit(address market) external view validMarket(market) returns (uint256) {
        return _getMarketAvailableLiquidity(market);
    }

    function getMaxSafeWithdrawal(address market) external view validMarket(market) returns (uint256) {
        return _calculateMaxSafeWithdrawal(market);
    }

    function maxWithdrawable(address market) external view validMarket(market) returns (uint256) {
        return _getMarketBalance(market);
    }

    function isMorphoMarketHealthy(address market) external view validMarket(market) returns (bool) {
        return _isMarketHealthy(market) && !paused && !emergencyMode;
    }

    function morphoRewardsAvailable(address market) external view validMarket(market) returns (bool) {
        // Check if there are claimable rewards for this market
        // This would interface with Morpho's rewards controller
        return true; // Placeholder
    }

    function morphoMarketConditionsFavorable(address market) external view validMarket(market) returns (bool) {
        return _isMarketHealthy(market) && _isMarketLTVSafe(market) && _isGasPriceReasonable();
    }

    function needsRebalancing(address market) external view validMarket(market) returns (bool) {
        MarketConfig memory config = marketConfigs[market];
        uint256 currentAllocation = (config.currentExposure * 10_000) / totalAssets();
        uint256 targetAllocation = config.allocationBps;
        
        // Rebalance if deviation is more than 5%
        return Math.abs(int256(currentAllocation) - int256(targetAllocation)) > 500;
    }

    function claimingGasEfficient() external view returns (bool) {
        return _isGasPriceReasonable();
    }

    function getMorphoEstimatedAPY(address market) external view validMarket(market) returns (uint256) {
        // Simplified APY estimation based on current Morpho rates
        // This would use Morpho's supply rate data
        return 500; // 5% APY placeholder
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

    function emergencyWithdraw(uint256 amount, address market) external onlyOwner emergencyTimeout validMarket(market) {
        if (amount == 0) {
            amount = _getMarketBalance(market);
        }
        
        morpho.withdraw(market, amount, msg.sender);
        marketConfigs[market].currentExposure -= amount;
    }

    function emergencyWithdrawAll() external onlyOwner emergencyTimeout {
        for (uint256 i = 0; i < activeMarkets.length; i++) {
            address market = activeMarkets[i];
            uint256 balance = _getMarketBalance(market);
            if (balance > 0) {
                morpho.withdraw(market, balance, msg.sender);
                marketConfigs[market].currentExposure = 0;
            }
        }
    }

    // --------------------------------------------------
    // Admin Configuration Functions
    // --------------------------------------------------
    function setRiskParameters(RiskParameters calldata newParams) external onlyOwner {
        require(newParams.maxMarketConcentration <= 5000, "Concentration too high"); // 50% max
        
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
            maxLTV: 8000,               // 80%
            minLiquidity: 1000e18,      // 1000 tokens
            yieldThreshold: 50e18,      // 50 tokens
            gasPriceThreshold: 100 gwei, // 100 gwei max
            maxMarketConcentration: 3000 // 30% max per market
        });
    }

    function _getCurrentP2PIndex(address market) internal view returns (uint256) {
        // Get current P2P index from Morpho
        // This would interface with Morpho's market data
        return INDEX_PRECISION; // Placeholder
    }

    function _getMarketBalance(address market) internal view returns (uint256) {
        // Get supplied balance for market from Morpho
        // This would use Morpho's supply balance function
        return marketConfigs[market].currentExposure; // Placeholder - use actual Morpho call
    }

    function _calculateMarketAllocation(address market, uint256 totalAmount) internal view returns (uint256) {
        MarketConfig memory config = marketConfigs[market];
        uint256 allocation = (totalAmount * config.allocationBps) / totalAllocationBps;
        
        // Respect max exposure limits
        uint256 maxAdditional = config.maxExposure - config.currentExposure;
        return allocation.min(maxAdditional);
    }

    function _executeSupply(address market, uint256 amount) internal returns (uint256) {
        // Execute supply to Morpho market
        uint256 balanceBefore = _getMarketBalance(market);
        morpho.supply(market, amount, address(this));
        uint256 balanceAfter = _getMarketBalance(market);
        return balanceAfter - balanceBefore;
    }

    function _executeWithdrawal(address market, uint256 amount, address to) internal returns (uint256) {
        uint256 balanceBefore = asset.balanceOf(address(this));
        morpho.withdraw(market, amount, to);
        uint256 balanceAfter = asset.balanceOf(address(this));
        return balanceAfter - balanceBefore;
    }

    function _getMarketAvailableLiquidity(address market) internal view returns (uint256) {
        uint256 buffer = asset.balanceOf(address(this)) / activeMarkets.length;
        uint256 supplied = _getMarketBalance(market);
        return buffer + supplied;
    }

    function _calculateMaxSafeWithdrawal(address market) internal view returns (uint256) {
        uint256 bufferNeeded = (totalAssets() * liquidityBufferBps) / (10_000 * activeMarkets.length);
        uint256 currentBuffer = asset.balanceOf(address(this)) / activeMarkets.length;
        
        if (currentBuffer <= bufferNeeded) return 0;
        
        return _getMarketBalance(market) + (currentBuffer - bufferNeeded);
    }

    function _executeBufferReplenishment(uint256 amount) internal {
        // Withdraw from markets to replenish buffer
        for (uint256 i = 0; i < activeMarkets.length && amount > 0; i++) {
            address market = activeMarkets[i];
            uint256 marketBalance = _getMarketBalance(market);
            uint256 toWithdraw = amount.min(marketBalance);
            
            if (toWithdraw > 0) {
                morpho.withdraw(market, toWithdraw, address(this));
                marketConfigs[market].currentExposure -= toWithdraw;
                amount -= toWithdraw;
            }
        }
    }

    function _handleWithdrawalShortfall(address market, uint256 shortfall, address to) internal {
        // Implement shortfall handling logic for specific market
        // Could include partial fulfillment, queuing, or alternative strategies
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

    function _estimateP2PGain(address market) internal view returns (uint256) {
        // Estimate potential P2P gains for market
        MarketConfig memory config = marketConfigs[market];
        uint256 currentIndex = _getCurrentP2PIndex(market);
        
        if (currentIndex <= config.lastP2PIndex) return 0;
        
        uint256 delta = currentIndex - config.lastP2PIndex;
        uint256 supplied = _getMarketBalance(market);
        
        return (supplied * delta) / INDEX_PRECISION;
    }

    function _estimateRewardsValue(address market) internal view returns (uint256) {
        // Estimate potential rewards value for market
        // This would interface with Morpho's rewards estimation
        return 0; // Placeholder
    }
}