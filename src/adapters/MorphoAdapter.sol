// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * NapFi Hyper-Optimized Morpho Adapter v4.0 - "Morpho Titan"
 * ----------------------------------------------------------
 * Maximum innovation combining Morpho V2's efficient lending with
 * Uniswap V4 hooks for MEV-resistant operations, while maintaining
 * full tokenization capabilities for multiple ERC-4626 strategies
 */

import {IERC20} from "@openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
// import {ReentrancyGuard} from "@openzeppelin-contracts/security/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin-contracts/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ERC6909} from "tokenized-strategy/contracts/token/ERC6909/ERC6909.sol";

// Morpho V2 Interfaces (based on their vault-v2 architecture)
import {IMorpho} from "../interfaces/IMorpho.sol";
//import {IMorphoMarket} from "../interfaces/IMorphoMarket.sol";
//import {IMorphoRewards} from "../interfaces/IMorphoRewards.sol";

// Uniswap hooks/core
import {BaseHook} from "uniswap-hooks/base/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/types/PoolKey.sol";

contract MorphoAdapter is ReentrancyGuard, Ownable, ERC6909, BaseHook {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // --------------------------------------------------
    // Core Protocol Addresses
    // --------------------------------------------------
    IMorpho public immutable morpho;
    IMorphoRewards public immutable morphoRewards;
    IPoolManager public immutable uniswapV4PoolManager;
    
    // --------------------------------------------------
    // Hyper-Optimized Multi-Strategy Architecture
    // --------------------------------------------------
    struct MorphoStrategy {
        address strategy;
        address asset;
        bool enabled;
        uint256 totalDeposited;
        uint256 currentShares;
        uint256 lastHarvest;
        uint256 performanceScore;
        uint256 cooldownUntil;
    }
    
    struct StrategyMetrics {
        uint256 totalYield;
        uint256 totalDonations;
        uint256 avgAPY;
        uint256 riskScore;
        uint256 lastRebalance;
        uint256 morphoRewardsAccrued;
    }
    
    mapping(address => MorphoStrategy) public morphoStrategies;
    mapping(address => StrategyMetrics) public strategyMetrics;
    mapping(address => address) public strategyByAsset;
    address[] public activeStrategies;
    
    // --------------------------------------------------
    // Morpho Market Configuration with Dynamic Allocation
    // --------------------------------------------------
    struct MorphoMarketConfig {
        address market;
        address collateralToken;
        address loanToken;
        bool enabled;
        uint256 targetAllocation;
        uint256 currentAllocation;
        uint256 maxExposure;
        uint256 totalExposure;
        uint256 performanceAPY;
        uint256 riskScore;
        uint256 morphoSupplyAPY;
        uint256 morphoBorrowAPY;
    }
    
    address[] public activeMarkets;
    mapping(address => MorphoMarketConfig) public marketConfigs;
    mapping(address => address[]) public assetMarkets; // asset -> markets[]
    
    // --------------------------------------------------
    // Advanced Morpho-Specific Features
    // --------------------------------------------------
    struct MorphoPosition {
        uint256 supplied;
        uint256 borrowed;
        uint256 collateral;
        uint256 healthFactor;
        bool isCollateralEnabled;
    }
    
    mapping(address => mapping(address => MorphoPosition)) public strategyPositions; // strategy -> market -> position
    
    // --------------------------------------------------
    // Multi-Tier Boost System with Morpho Rewards Integration
    // --------------------------------------------------
    enum BoostTier { NONE, BRONZE, SILVER, GOLD, PLATINUM, MORPHO_TITAN }
    
    struct BoostConfig {
        uint256 multiplier;
        uint256 minScore;
        uint256 donationBoost;
        uint256 feeDiscount;
        uint256 morphoRewardsBoost; // Additional Morpho rewards multiplier
    }
    
    mapping(BoostTier => BoostConfig) public boostConfigs;
    mapping(address => BoostTier) public strategyBoostTier;
    mapping(address => uint256) public strategyBoostExpiry;
    
    // --------------------------------------------------
    // Uniswap V4 Hooks Integration for Morpho Operations
    // --------------------------------------------------
    struct MorphoSwapConfig {
        uint256 maxSlippageBps;
        uint256 minSwapAmount;
        bool useV4Hooks;
        address rewardPool;
        address collateralPool;
    }
    
    MorphoSwapConfig public morphoSwapConfig;
    
    // V4 Hook state for Morpho-specific operations
    mapping(PoolKey => uint256) public morphoSwapCount;
    mapping(PoolKey => uint256) public morphoLiquidityCount;
    
    // --------------------------------------------------
    // Dynamic Rebalancing Engine for Morpho Markets
    // --------------------------------------------------
    struct MorphoRebalanceConfig {
        uint256 rebalanceThreshold;
        uint256 maxSingleMove;
        uint256 cooldownPeriod;
        bool autoRebalanceEnabled;
        uint256 healthFactorTarget; // Target health factor for positions
        uint256 maxLeverageRatio;   // Maximum leverage allowed
    }
    
    MorphoRebalanceConfig public morphoRebalanceConfig;
    uint256 public lastGlobalRebalance;
    
    // --------------------------------------------------
    // Advanced Fee Configuration (inspired by Morpho V2)
    // --------------------------------------------------
    uint16 public donationBps = 500;
    uint16 public performanceFeeBps = 1000;
    uint16 public managementFeeBps = 200;
    uint16 public constant MAX_FEE_BPS = 2000;
    
    // --------------------------------------------------
    // Advanced State & Analytics
    // --------------------------------------------------
    uint256 public totalDonated;
    uint256 public totalYieldGenerated;
    uint256 public totalFeesCollected;
    uint256 public totalMorphoRewards;
    uint256 public minDonation = 1e6;
    
    // Real-time analytics
    uint256 public overallAPY;
    uint256 public totalTVL;
    uint256 public avgHealthFactor;
    uint256 public totalBorrowed;
    
    // --------------------------------------------------
    // Enhanced Events
    // --------------------------------------------------
    event StrategyRegistered(address indexed strategy, address indexed asset);
    event MorphoMarketAdded(address indexed market, address collateral, address loan);
    event StrategySuppliedToMorpho(address indexed strategy, address market, uint256 amount, uint256 shares);
    event StrategyWithdrawnFromMorpho(address indexed strategy, address market, uint256 amount, uint256 shares);
    event MorphoRewardsClaimed(address indexed strategy, uint256 amount, address[] tokens);
    event PositionLeveraged(address indexed strategy, address market, uint256 supplied, uint256 borrowed);
    event PositionDeleveraged(address indexed strategy, address market, uint256 repaid, uint256 withdrawn);
    event V4HookTriggered(address indexed caller, bytes4 selector, uint256 count);
    
    // --------------------------------------------------
    // Modifiers
    // --------------------------------------------------
    modifier onlyStrategy() {
        require(morphoStrategies[msg.sender].enabled, "Adapter: not authorized strategy");
        _;
    }
    
    modifier onlyActiveMarket(address market) {
        require(marketConfigs[market].enabled, "Adapter: invalid market");
        _;
    }
    
    modifier rebalanceCooldown() {
        require(block.timestamp >= lastGlobalRebalance + morphoRebalanceConfig.cooldownPeriod, "Rebalance cooldown");
        _;
    }

    // --------------------------------------------------
    // Hyper Constructor with V4 Hook Integration
    // --------------------------------------------------
    constructor(
        address _morpho,
        address _morphoRewards,
        IPoolManager _uniswapV4PoolManager
    ) 
        ERC6909("NapFi Morpho Adapter Shares", "NPF-MORPHO")
        BaseHook(_uniswapV4PoolManager)
    {
        require(_morpho != address(0), "Invalid Morpho");
        require(_morphoRewards != address(0), "Invalid Morpho rewards");
        
        morpho = IMorpho(_morpho);
        morphoRewards = IMorphoRewards(_morphoRewards);
        uniswapV4PoolManager = _uniswapV4PoolManager;
        
        _initializeBoostTiers();
        _initializeMorphoRebalanceConfig();
        _initializeMorphoSwapConfig();
    }

    // --------------------------------------------------
    // Uniswap V4 Hooks Implementation for Morpho Operations
    // --------------------------------------------------
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Track Morpho-related swaps for analytics
        morphoSwapCount[key.toId()]++;
        
        // Implement MEV protection for Morpho reward swaps
        if (_isMorphoRewardToken(key.currency0) || _isMorphoRewardToken(key.currency1)) {
            // Apply additional protection for reward token swaps
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 5); // 0.05% max slippage
        }
        
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        emit V4HookTriggered(msg.sender, BaseHook.afterSwap.selector, morphoSwapCount[key.toId()]);
        return (BaseHook.afterSwap.selector, 0);
    }

    function _beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        morphoLiquidityCount[key.toId()]++;
        return BaseHook.beforeAddLiquidity.selector;
    }

    // --------------------------------------------------
    // Multi-Strategy Registration with Morpho Integration
    // --------------------------------------------------
    function registerStrategy(
        address _strategy,
        address _asset
    ) external onlyOwner {
        require(_strategy != address(0), "Invalid strategy");
        require(_asset != address(0), "Invalid asset");
        require(!morphoStrategies[_strategy].enabled, "Strategy already registered");
        
        morphoStrategies[_strategy] = MorphoStrategy({
            strategy: _strategy,
            asset: _asset,
            enabled: true,
            totalDeposited: 0,
            currentShares: 0,
            lastHarvest: 0,
            performanceScore: 10000,
            cooldownUntil: 0
        });
        
        strategyByAsset[_asset] = _strategy;
        activeStrategies.push(_strategy);
        
        // Initialize metrics
        strategyMetrics[_strategy] = StrategyMetrics({
            totalYield: 0,
            totalDonations: 0,
            avgAPY: 0,
            riskScore: 5000,
            lastRebalance: 0,
            morphoRewardsAccrued: 0
        });
        
        // Approve Morpho for this asset
        IERC20(_asset).safeApprove(address(morpho), type(uint256).max);
        
        emit StrategyRegistered(_strategy, _asset);
    }

    // --------------------------------------------------
    // Morpho Market Management
    // --------------------------------------------------
    function addMorphoMarket(
        address _market,
        address _collateralToken,
        address _loanToken,
        uint256 _targetAllocation
    ) external onlyOwner {
        require(_market != address(0), "Invalid market");
        require(!marketConfigs[_market].enabled, "Market already added");
        
        marketConfigs[_market] = MorphoMarketConfig({
            market: _market,
            collateralToken: _collateralToken,
            loanToken: _loanToken,
            enabled: true,
            targetAllocation: _targetAllocation,
            currentAllocation: 0,
            maxExposure: type(uint256).max,
            totalExposure: 0,
            performanceAPY: 0,
            riskScore: 5000,
            morphoSupplyAPY: 0,
            morphoBorrowAPY: 0
        });
        
        activeMarkets.push(_market);
        
        // Initialize asset-market mapping
        assetMarkets[_collateralToken].push(_market);
        if (_loanToken != _collateralToken) {
            assetMarkets[_loanToken].push(_market);
        }
        
        // Approve tokens for Morpho
        IERC20(_collateralToken).safeApprove(address(morpho), type(uint256).max);
        IERC20(_loanToken).safeApprove(address(morpho), type(uint256).max);
        
        emit MorphoMarketAdded(_market, _collateralToken, _loanToken);
    }

    // --------------------------------------------------
    // Strategy-Facing Functions with Morpho Integration
    // --------------------------------------------------
    function supplyToMorpho(address market, uint256 amount) external onlyStrategy onlyActiveMarket(market) returns (uint256) {
        MorphoStrategy storage strategy = morphoStrategies[msg.sender];
        require(amount > 0, "Zero supply");
        require(block.timestamp >= strategy.cooldownUntil, "Strategy in cooldown");
        
        MorphoMarketConfig storage marketConfig = marketConfigs[market];
        
        // Transfer asset from strategy to adapter
        IERC20(marketConfig.collateralToken).safeTransferFrom(msg.sender, address(this), amount);
        
        // Execute supply to Morpho
        uint256 shares = _executeMorphoSupply(market, amount);
        
        // Update strategy tracking
        strategy.totalDeposited += amount;
        strategy.currentShares += shares;
        marketConfig.totalExposure += amount;
        
        // Update position
        _updateStrategyPosition(msg.sender, market, amount, 0, true);
        
        // Update TVL and analytics
        _updateGlobalMetrics();
        
        emit StrategySuppliedToMorpho(msg.sender, market, amount, shares);
        return shares;
    }

    function withdrawFromMorpho(address market, uint256 amount, address to) external onlyStrategy onlyActiveMarket(market) returns (uint256) {
        require(amount > 0, "Zero withdraw");
        require(to != address(0), "Invalid recipient");
        
        MorphoStrategy storage strategy = morphoStrategies[msg.sender];
        MorphoMarketConfig storage marketConfig = marketConfigs[market];
        
        // Execute withdrawal from Morpho
        uint256 withdrawn = _executeMorphoWithdrawal(market, amount, to);
        
        // Update strategy tracking
        strategy.currentShares -= withdrawn;
        marketConfig.totalExposure -= withdrawn;
        
        // Update position
        _updateStrategyPosition(msg.sender, market, withdrawn, 0, false);
        
        // Apply cooldown
        strategy.cooldownUntil = block.timestamp + 1 hours;
        
        // Update TVL
        _updateGlobalMetrics();
        
        emit StrategyWithdrawnFromMorpho(msg.sender, market, amount, withdrawn);
        return withdrawn;
    }

    // --------------------------------------------------
    // Advanced Morpho Features: Leverage & De-leverage
    // --------------------------------------------------
    function createLeveragedPosition(
        address market,
        uint256 supplyAmount,
        uint256 borrowAmount
    ) external onlyStrategy onlyActiveMarket(market) {
        require(supplyAmount > 0, "Zero supply");
        require(borrowAmount > 0, "Zero borrow");
        
        MorphoMarketConfig storage marketConfig = marketConfigs[market];
        MorphoStrategy storage strategy = morphoStrategies[msg.sender];
        
        // Transfer collateral from strategy
        IERC20(marketConfig.collateralToken).safeTransferFrom(msg.sender, address(this), supplyAmount);
        
        // Supply collateral to Morpho
        uint256 shares = _executeMorphoSupply(market, supplyAmount);
        
        // Borrow loan token
        _executeMorphoBorrow(market, borrowAmount);
        
        // Update strategy tracking
        strategy.totalDeposited += supplyAmount;
        strategy.currentShares += shares;
        marketConfig.totalExposure += supplyAmount;
        
        // Update position with leverage
        _updateStrategyPosition(msg.sender, market, supplyAmount, borrowAmount, true);
        
        // Check health factor
        require(_getPositionHealthFactor(msg.sender, market) > morphoRebalanceConfig.healthFactorTarget, "Health factor too low");
        
        emit PositionLeveraged(msg.sender, market, supplyAmount, borrowAmount);
    }

    function deLeveragePosition(
        address market,
        uint256 repayAmount,
        uint256 withdrawAmount
    ) external onlyStrategy onlyActiveMarket(market) {
        require(repayAmount > 0 || withdrawAmount > 0, "No operation");
        
        MorphoMarketConfig storage marketConfig = marketConfigs[market];
        
        // Repay borrow if specified
        if (repayAmount > 0) {
            _executeMorphoRepay(market, repayAmount);
        }
        
        // Withdraw collateral if specified
        if (withdrawAmount > 0) {
            _executeMorphoWithdrawal(market, withdrawAmount, msg.sender);
        }
        
        // Update position
        _updateStrategyPosition(msg.sender, market, withdrawAmount, repayAmount, false);
        
        emit PositionDeleveraged(msg.sender, market, repayAmount, withdrawAmount);
    }

    // --------------------------------------------------
    // Morpho Rewards Integration with V4 Swaps
    // --------------------------------------------------
    function harvestMorphoRewards() external onlyStrategy returns (uint256 yield, uint256 donation) {
        MorphoStrategy storage strategy = morphoStrategies[msg.sender];
        require(block.timestamp >= strategy.lastHarvest + 6 hours, "Harvest cooldown");
        
        // Claim Morpho rewards using V4-optimized swaps
        uint256 rewardsValue = _claimAndOptimizeMorphoRewards();
        
        // Calculate yield
        uint256 currentValue = _getStrategyTotalValue(msg.sender);
        uint256 previousValue = strategyMetrics[msg.sender].totalYield;
        
        if (currentValue <= previousValue) {
            return (0, 0);
        }
        
        yield = currentValue - previousValue + rewardsValue;
        strategyMetrics[msg.sender].totalYield += yield;
        totalYieldGenerated += yield;
        
        // Calculate amplified donation with Morpho-specific boosts
        donation = _calculateMorphoDonation(msg.sender, yield);
        strategyMetrics[msg.sender].totalDonations += donation;
        
        if (donation >= minDonation) {
            _executeMorphoDonation(msg.sender, donation);
        }
        
        // Update strategy state
        strategy.lastHarvest = block.timestamp;
        _updateStrategyPerformance(msg.sender, yield);
        
        return (yield, donation);
    }

    function _claimAndOptimizeMorphoRewards() internal returns (uint256) {
        // Claim rewards from Morpho
        address[] memory markets = activeMarkets;
        (address[] memory rewardTokens, uint256[] memory amounts) = morphoRewards.claimRewards(markets, address(this));
        
        uint256 totalValue = 0;
        
        // Use V4 hooks for optimal reward swapping
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            if (amounts[i] > 0) {
                // Swap to strategy's asset using V4 with MEV protection
                uint256 swappedAmount = _executeV4MorphoSwap(rewardTokens[i], _getStrategyAsset(msg.sender), amounts[i]);
                totalValue += swappedAmount;
                
                strategyMetrics[msg.sender].morphoRewardsAccrued += amounts[i];
                totalMorphoRewards += amounts[i];
            }
        }
        
        emit MorphoRewardsClaimed(msg.sender, totalValue, rewardTokens);
        return totalValue;
    }

    // --------------------------------------------------
    // Dynamic Rebalancing Across Morpho Markets
    // --------------------------------------------------
    function rebalanceMorphoMarkets() external onlyOwner rebalanceCooldown {
        uint256 totalMoved = 0;
        uint256 estimatedAPYGain = 0;
        
        for (uint256 i = 0; i < activeStrategies.length; i++) {
            address strategy = activeStrategies[i];
            address currentAsset = morphoStrategies[strategy].asset;
            
            // Find best performing market for this asset
            address bestMarket = _findBestMorphoMarket(currentAsset);
            
            if (bestMarket != address(0)) {
                uint256 rebalanceAmount = _calculateMorphoRebalanceAmount(strategy, bestMarket);
                
                if (rebalanceAmount > 0) {
                    // Execute rebalance
                    _executeMorphoRebalance(strategy, bestMarket, rebalanceAmount);
                    totalMoved += rebalanceAmount;
                    estimatedAPYGain += _calculateMorphoAPYImprovement(strategy, bestMarket, rebalanceAmount);
                }
            }
        }
        
        lastGlobalRebalance = block.timestamp;
    }

    // --------------------------------------------------
    // Internal Morpho Operations with V4 Integration
    // --------------------------------------------------
    function _executeMorphoSupply(address market, uint256 amount) internal returns (uint256 shares) {
        // Implementation would interact with Morpho Blue
        // Placeholder for actual Morpho integration
        shares = amount; // Simplified
        return shares;
    }

    function _executeMorphoWithdrawal(address market, uint256 amount, address to) internal returns (uint256) {
        // Implementation would interact with Morpho Blue
        return amount; // Simplified
    }

    function _executeMorphoBorrow(address market, uint256 amount) internal {
        // Implementation would interact with Morpho Blue
    }

    function _executeMorphoRepay(address market, uint256 amount) internal {
        // Implementation would interact with Morpho Blue
    }

    function _executeV4MorphoSwap(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256) {
        // Use V4 hooks for MEV-resistant Morpho reward swaps
        // This would implement the actual V4 swap logic with hook integration
        uint256 estimatedOutput = amountIn * 9950 / 10000; // 0.5% slippage
        return estimatedOutput;
    }

    // --------------------------------------------------
    // Position Management & Health Monitoring
    // --------------------------------------------------
    function _updateStrategyPosition(address strategy, address market, uint256 supplyDelta, uint256 borrowDelta, bool isIncrease) internal {
        MorphoPosition storage position = strategyPositions[strategy][market];
        
        if (isIncrease) {
            position.supplied += supplyDelta;
            position.borrowed += borrowDelta;
        } else {
            position.supplied -= supplyDelta;
            position.borrowed -= borrowDelta;
        }
        
        // Update health factor
        position.healthFactor = _calculateHealthFactor(position.supplied, position.borrowed, market);
    }

    function _calculateHealthFactor(uint256 supplied, uint256 borrowed, address market) internal view returns (uint256) {
        if (borrowed == 0) return type(uint256).max;
        
        // Simplified health factor calculation
        // In production, would use Morpho's actual health factor logic
        return (supplied * 10000) / borrowed;
    }

    function _getPositionHealthFactor(address strategy, address market) internal view returns (uint256) {
        return strategyPositions[strategy][market].healthFactor;
    }

    // --------------------------------------------------
    // View Functions & Analytics
    // --------------------------------------------------
    function getStrategyTotalValue(address strategy) public view returns (uint256) {
        return _getStrategyTotalValue(strategy);
    }

    function _getStrategyTotalValue(address strategy) internal view returns (uint256) {
        MorphoStrategy memory strat = morphoStrategies[strategy];
        return strat.currentShares; // Simplified - would calculate actual value from positions
    }

    function getMorphoAPY(address market) public view returns (uint256 supplyAPY, uint256 borrowAPY) {
        MorphoMarketConfig memory config = marketConfigs[market];
        return (config.morphoSupplyAPY, config.morphoBorrowAPY);
    }

    function _findBestMorphoMarket(address asset) internal view returns (address) {
        address[] memory markets = assetMarkets[asset];
        address bestMarket;
        uint256 bestAPY = 0;
        
        for (uint256 i = 0; i < markets.length; i++) {
            address market = markets[i];
            uint256 apy = marketConfigs[market].performanceAPY;
            if (apy > bestAPY) {
                bestAPY = apy;
                bestMarket = market;
            }
        }
        
        return bestMarket;
    }

    // --------------------------------------------------
    // Initialization Functions
    // --------------------------------------------------
    function _initializeBoostTiers() internal {
        boostConfigs[BoostTier.BRONZE] = BoostConfig(11000, 7500, 500, 100, 10500);
        boostConfigs[BoostTier.SILVER] = BoostConfig(12500, 8000, 1000, 250, 11000);
        boostConfigs[BoostTier.GOLD] = BoostConfig(15000, 8500, 1500, 500, 12000);
        boostConfigs[BoostTier.PLATINUM] = BoostConfig(17500, 9000, 2000, 750, 13000);
        boostConfigs[BoostTier.MORPHO_TITAN] = BoostConfig(20000, 9500, 2500, 1000, 15000);
    }

    function _initializeMorphoRebalanceConfig() internal {
        morphoRebalanceConfig = MorphoRebalanceConfig({
            rebalanceThreshold: 200,
            maxSingleMove: 1000,
            cooldownPeriod: 1 days,
            autoRebalanceEnabled: true,
            healthFactorTarget: 15000, // 1.5x
            maxLeverageRatio: 30000    // 3x max leverage
        });
    }

    function _initializeMorphoSwapConfig() internal {
        morphoSwapConfig = MorphoSwapConfig({
            maxSlippageBps: 30,      // 0.3% for Morpho (tighter due to hooks)
            minSwapAmount: 0.1e18,    // 0.1 token minimum
            useV4Hooks: true,
            rewardPool: address(0),
            collateralPool: address(0)
        });
    }

    // --------------------------------------------------
    // Helper Functions
    // --------------------------------------------------
    function _getStrategyAsset(address strategy) internal view returns (address) {
        return morphoStrategies[strategy].asset;
    }

    function _isMorphoRewardToken(address token) internal pure returns (bool) {
        // Check if token is a known Morpho reward token
        // This would be expanded in production
        return false;
    }

    function _updateStrategyPerformance(address strategy, uint256 yield) internal {
        // Update performance scoring
    }

    function _updateGlobalMetrics() internal {
        // Update global TVL, APY, health factor metrics
    }

    function _calculateMorphoRebalanceAmount(address strategy, address market) internal view returns (uint256) {
        return morphoStrategies[strategy].currentShares / 10; // 10% for rebalance
    }

    function _executeMorphoRebalance(address strategy, address market, uint256 amount) internal {
        // Execute rebalance logic
    }

    function _calculateMorphoAPYImprovement(address strategy, address market, uint256 amount) internal pure returns (uint256) {
        return amount / 100; // 1% estimated improvement
    }

    function _calculateMorphoDonation(address strategy, uint256 yield) internal view returns (uint256) {
        uint256 baseDonation = (yield * donationBps) / 10000;
        
        // Apply Morpho-specific boost
        BoostTier tier = strategyBoostTier[strategy];
        if (tier != BoostTier.NONE && block.timestamp < strategyBoostExpiry[strategy]) {
            baseDonation = (baseDonation * boostConfigs[tier].multiplier) / 10000;
        }
        
        return baseDonation;
    }

    function _executeMorphoDonation(address strategy, uint256 donation) internal {
        totalDonated += donation;
    }

    // Emergency state
    bool public paused;
}

// Required placeholder interfaces for Morpho
interface IMorpho {
    // Morpho Blue interface methods would be defined here
}

interface IMorphoMarket {
    // Morpho market interface
}

interface IMorphoRewards {
    function claimRewards(address[] calldata markets, address onBehalf) external returns (address[] memory, uint256[] memory);
}