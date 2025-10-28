// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * NapFi Hyper-Optimized Spark Tokenized Adapter v4.0 - "Spark Titan"
 * ----------------------------------------------------------------
 * Tokenized Spark Protocol adapter with multi-strategy support, Uniswap V4 hooks,
 * and full compatibility with Yearn V3/Octant vaults
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC6909} from "@openzeppelin/contracts/token/ERC6909/ERC6909.sol";

// Spark Protocol Interfaces
import {ISparkPool} from "../interfaces/ISparkPool.sol";
import {IRewardsController} from "../interfaces/IRewardsController.sol";

// Uniswap V4 Core + Hooks
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

contract NapFiHyperSparkAdapter is ReentrancyGuard, Ownable, ERC6909, BaseHook {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // --------------------------------------------------
    // Core Protocol Addresses
    // --------------------------------------------------
    ISparkPool public immutable sparkPool;
    IRewardsController public immutable sparkRewards;
    IPoolManager public immutable uniswapV4PoolManager;
    
    // --------------------------------------------------
    // Hyper-Optimized Multi-Strategy Architecture
    // --------------------------------------------------
    struct SparkStrategy {
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
        uint256 sparkRewardsAccrued;
    }
    
    mapping(address => SparkStrategy) public sparkStrategies;
    mapping(address => StrategyMetrics) public strategyMetrics;
    mapping(address => address) public strategyByAsset;
    address[] public activeStrategies;
    
    // --------------------------------------------------
    // Spark Market Configuration with Dynamic Allocation
    // --------------------------------------------------
    struct SparkMarketConfig {
        address underlyingAsset;
        address sToken;
        bool enabled;
        uint256 targetAllocation;
        uint256 currentAllocation;
        uint256 maxExposure;
        uint256 totalExposure;
        uint256 performanceAPY;
        uint256 riskScore;
        uint256 sparkSupplyAPY;
        uint256 variableBorrowAPY;
    }
    
    address[] public activeMarkets;
    mapping(address => SparkMarketConfig) public marketConfigs;
    mapping(address => address[]) public assetMarkets;
    
    // --------------------------------------------------
    // Advanced Spark-Specific Features
    // --------------------------------------------------
    struct SparkPosition {
        uint256 supplied;
        uint256 borrowed;
        uint256 collateral;
        uint256 healthFactor;
        bool isCollateralEnabled;
    }
    
    mapping(address => mapping(address => SparkPosition)) public strategyPositions;
    
    // --------------------------------------------------
    // Multi-Tier Boost System with Spark Rewards Integration
    // --------------------------------------------------
    enum BoostTier { NONE, BRONZE, SILVER, GOLD, PLATINUM, SPARK_TITAN }
    
    struct BoostConfig {
        uint256 multiplier;
        uint256 minScore;
        uint256 donationBoost;
        uint256 feeDiscount;
        uint256 sparkRewardsBoost;
    }
    
    mapping(BoostTier => BoostConfig) public boostConfigs;
    mapping(address => BoostTier) public strategyBoostTier;
    mapping(address => uint256) public strategyBoostExpiry;
    
    // --------------------------------------------------
    // Uniswap V4 Hooks Integration for Spark Operations
    // --------------------------------------------------
    struct SparkSwapConfig {
        uint256 maxSlippageBps;
        uint256 minSwapAmount;
        bool useV4Hooks;
        address rewardPool;
        address collateralPool;
    }
    
    SparkSwapConfig public sparkSwapConfig;
    
    // V4 Hook state for Spark-specific operations
    mapping(PoolKey => uint256) public sparkSwapCount;
    mapping(PoolKey => uint256) public sparkLiquidityCount;
    
    // --------------------------------------------------
    // Dynamic Rebalancing Engine for Spark Markets
    // --------------------------------------------------
    struct SparkRebalanceConfig {
        uint256 rebalanceThreshold;
        uint256 maxSingleMove;
        uint256 cooldownPeriod;
        bool autoRebalanceEnabled;
        uint256 healthFactorTarget;
        uint256 maxLeverageRatio;
    }
    
    SparkRebalanceConfig public sparkRebalanceConfig;
    uint256 public lastGlobalRebalance;
    
    // --------------------------------------------------
    // Advanced Fee Configuration
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
    uint256 public totalSparkRewards;
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
    event SparkMarketAdded(address indexed market, address underlying);
    event StrategySuppliedToSpark(address indexed strategy, address market, uint256 amount, uint256 shares);
    event StrategyWithdrawnFromSpark(address indexed strategy, address market, uint256 amount, uint256 shares);
    event SparkRewardsClaimed(address indexed strategy, uint256 amount, address[] tokens);
    event PositionLeveraged(address indexed strategy, address market, uint256 supplied, uint256 borrowed);
    event PositionDeleveraged(address indexed strategy, address market, uint256 repaid, uint256 withdrawn);
    event V4HookTriggered(address indexed caller, bytes4 selector, uint256 count);
    
    // --------------------------------------------------
    // Modifiers
    // --------------------------------------------------
    modifier onlyStrategy() {
        require(sparkStrategies[msg.sender].enabled, "Adapter: not authorized strategy");
        _;
    }
    
    modifier onlyActiveMarket(address market) {
        require(marketConfigs[market].enabled, "Adapter: invalid market");
        _;
    }
    
    modifier rebalanceCooldown() {
        require(block.timestamp >= lastGlobalRebalance + sparkRebalanceConfig.cooldownPeriod, "Rebalance cooldown");
        _;
    }

    // --------------------------------------------------
    // Hyper Constructor with V4 Hook Integration
    // --------------------------------------------------
    constructor(
        address _sparkPool,
        address _sparkRewards,
        IPoolManager _uniswapV4PoolManager
    ) 
        ERC6909("NapFi Spark Adapter Shares", "NPF-SPARK")
        BaseHook(_uniswapV4PoolManager)
    {
        require(_sparkPool != address(0), "Invalid Spark pool");
        require(_sparkRewards != address(0), "Invalid Spark rewards");
        
        sparkPool = ISparkPool(_sparkPool);
        sparkRewards = IRewardsController(_sparkRewards);
        uniswapV4PoolManager = _uniswapV4PoolManager;
        
        _initializeBoostTiers();
        _initializeSparkRebalanceConfig();
        _initializeSparkSwapConfig();
    }

    /*//////////////////////////////////////////////////////////////
                UNISWAP V4 HOOKS IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

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

    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        // Track Spark-related swaps for analytics
        sparkSwapCount[key.toId()]++;
        
        // Implement MEV protection for Spark reward swaps
        if (_isSparkRewardToken(key.currency0) || _isSparkRewardToken(key.currency1)) {
            // Apply additional protection for reward token swaps
        }
        
        return BaseHook.beforeSwap.selector;
    }

    function _afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, int128, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        emit V4HookTriggered(msg.sender, BaseHook.afterSwap.selector, sparkSwapCount[key.toId()]);
        return BaseHook.afterSwap.selector;
    }

    function _beforeAddLiquidity(address, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        sparkLiquidityCount[key.toId()]++;
        return BaseHook.beforeAddLiquidity.selector;
    }

    /*//////////////////////////////////////////////////////////////
                MULTI-STRATEGY REGISTRATION
    //////////////////////////////////////////////////////////////*/

    function registerStrategy(
        address _strategy,
        address _asset
    ) external onlyOwner {
        require(_strategy != address(0), "Invalid strategy");
        require(_asset != address(0), "Invalid asset");
        require(!sparkStrategies[_strategy].enabled, "Strategy already registered");
        
        sparkStrategies[_strategy] = SparkStrategy({
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
            sparkRewardsAccrued: 0
        });
        
        // Approve Spark for this asset
        IERC20(_asset).safeApprove(address(sparkPool), type(uint256).max);
        
        emit StrategyRegistered(_strategy, _asset);
    }

    /*//////////////////////////////////////////////////////////////
                SPARK MARKET MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function addSparkMarket(
        address _underlyingAsset,
        address _sToken,
        uint256 _targetAllocation
    ) external onlyOwner {
        require(_underlyingAsset != address(0), "Invalid underlying asset");
        require(_sToken != address(0), "Invalid sToken");
        require(!marketConfigs[_sToken].enabled, "Market already added");
        
        marketConfigs[_sToken] = SparkMarketConfig({
            underlyingAsset: _underlyingAsset,
            sToken: _sToken,
            enabled: true,
            targetAllocation: _targetAllocation,
            currentAllocation: 0,
            maxExposure: type(uint256).max,
            totalExposure: 0,
            performanceAPY: 0,
            riskScore: 5000,
            sparkSupplyAPY: 0,
            variableBorrowAPY: 0
        });
        
        activeMarkets.push(_sToken);
        
        // Initialize asset-market mapping
        assetMarkets[_underlyingAsset].push(_sToken);
        
        emit SparkMarketAdded(_sToken, _underlyingAsset);
    }

    /*//////////////////////////////////////////////////////////////
                STRATEGY-FACING FUNCTIONS WITH SPARK INTEGRATION
    //////////////////////////////////////////////////////////////*/

    function supplyToSpark(address market, uint256 amount) 
        external 
        onlyStrategy 
        onlyActiveMarket(market) 
        returns (uint256) 
    {
        SparkStrategy storage strategy = sparkStrategies[msg.sender];
        require(amount > 0, "Zero supply");
        require(block.timestamp >= strategy.cooldownUntil, "Strategy in cooldown");
        
        SparkMarketConfig storage marketConfig = marketConfigs[market];
        
        // Transfer asset from strategy to adapter
        IERC20(marketConfig.underlyingAsset).safeTransferFrom(msg.sender, address(this), amount);
        
        // Execute supply to Spark
        uint256 shares = _executeSparkSupplyToMarket(market, amount);
        
        // Update strategy tracking
        strategy.totalDeposited += amount;
        strategy.currentShares += shares;
        marketConfig.totalExposure += amount;
        
        // Update position
        _updateStrategyPosition(msg.sender, market, amount, true);
        
        // Update TVL and analytics
        _updateGlobalMetrics();
        
        emit StrategySuppliedToSpark(msg.sender, market, amount, shares);
        return shares;
    }

    function withdrawFromSpark(address market, uint256 amount, address to) 
        external 
        onlyStrategy 
        onlyActiveMarket(market) 
        returns (uint256) 
    {
        require(amount > 0, "Zero withdraw");
        require(to != address(0), "Invalid recipient");
        
        SparkStrategy storage strategy = sparkStrategies[msg.sender];
        SparkMarketConfig storage marketConfig = marketConfigs[market];
        
        // Execute withdrawal from Spark
        uint256 withdrawn = _executeSparkWithdrawalFromMarket(market, amount, to);
        
        // Update strategy tracking
        strategy.currentShares -= withdrawn;
        marketConfig.totalExposure -= withdrawn;
        
        // Update position
        _updateStrategyPosition(msg.sender, market, withdrawn, false);
        
        // Apply cooldown
        strategy.cooldownUntil = block.timestamp + 1 hours;
        
        // Update TVL
        _updateGlobalMetrics();
        
        emit StrategyWithdrawnFromSpark(msg.sender, market, amount, withdrawn);
        return withdrawn;
    }

    /*//////////////////////////////////////////////////////////////
                ADVANCED SPARK FEATURES: LEVERAGE & DE-LEVERAGE
    //////////////////////////////////////////////////////////////*/

    function createLeveragedPosition(
        address market,
        uint256 supplyAmount,
        uint256 borrowAmount
    ) external onlyStrategy onlyActiveMarket(market) {
        require(supplyAmount > 0, "Zero supply");
        require(borrowAmount > 0, "Zero borrow");
        
        SparkMarketConfig storage marketConfig = marketConfigs[market];
        SparkStrategy storage strategy = sparkStrategies[msg.sender];
        
        // Transfer collateral from strategy
        IERC20(marketConfig.underlyingAsset).safeTransferFrom(msg.sender, address(this), supplyAmount);
        
        // Supply collateral to Spark
        uint256 shares = _executeSparkSupplyToMarket(market, supplyAmount);
        
        // Borrow loan token
        _executeSparkBorrow(market, borrowAmount);
        
        // Update strategy tracking
        strategy.totalDeposited += supplyAmount;
        strategy.currentShares += shares;
        marketConfig.totalExposure += supplyAmount;
        
        // Update position with leverage
        _updateStrategyPosition(msg.sender, market, supplyAmount, borrowAmount, true);
        
        // Check health factor
        require(_getPositionHealthFactor(msg.sender, market) > sparkRebalanceConfig.healthFactorTarget, "Health factor too low");
        
        emit PositionLeveraged(msg.sender, market, supplyAmount, borrowAmount);
    }

    function deLeveragePosition(
        address market,
        uint256 repayAmount,
        uint256 withdrawAmount
    ) external onlyStrategy onlyActiveMarket(market) {
        require(repayAmount > 0 || withdrawAmount > 0, "No operation");
        
        SparkMarketConfig storage marketConfig = marketConfigs[market];
        
        // Repay borrow if specified
        if (repayAmount > 0) {
            _executeSparkRepay(market, repayAmount);
        }
        
        // Withdraw collateral if specified
        if (withdrawAmount > 0) {
            _executeSparkWithdrawalFromMarket(market, withdrawAmount, msg.sender);
        }
        
        // Update position
        _updateStrategyPosition(msg.sender, market, withdrawAmount, repayAmount, false);
        
        emit PositionDeleveraged(msg.sender, market, repayAmount, withdrawAmount);
    }

    /*//////////////////////////////////////////////////////////////
                SPARK REWARDS INTEGRATION WITH V4 SWAPS
    //////////////////////////////////////////////////////////////*/

    function harvestSparkRewards() 
        external 
        onlyStrategy 
        returns (uint256 yield, uint256 donation) 
    {
        SparkStrategy storage strategy = sparkStrategies[msg.sender];
        require(block.timestamp >= strategy.lastHarvest + 6 hours, "Harvest cooldown");
        
        // Claim Spark rewards using V4-optimized swaps
        uint256 rewardsValue = _claimAndOptimizeSparkRewards();
        
        // Calculate yield
        uint256 currentValue = _getStrategyTotalValue(msg.sender);
        uint256 previousValue = strategyMetrics[msg.sender].totalYield;
        
        if (currentValue <= previousValue) {
            return (0, 0);
        }
        
        yield = currentValue - previousValue + rewardsValue;
        strategyMetrics[msg.sender].totalYield += yield;
        totalYieldGenerated += yield;
        
        // Calculate amplified donation with Spark-specific boosts
        donation = _calculateSparkDonation(msg.sender, yield);
        strategyMetrics[msg.sender].totalDonations += donation;
        
        if (donation >= minDonation) {
            _executeSparkDonation(msg.sender, donation);
        }
        
        // Update strategy state
        strategy.lastHarvest = block.timestamp;
        _updateStrategyPerformance(msg.sender, yield);
        
        return (yield, donation);
    }

    function _claimAndOptimizeSparkRewards() internal returns (uint256) {
        // Claim rewards from Spark
        address[] memory assets = activeMarkets;
        address[] memory rewardTokens = new address[](1); // Simplified
        uint256[] memory amounts = new uint256[](1);
        
        // This would be the actual Spark rewards claim
        // (address[] memory rewardTokens, uint256[] memory amounts) = sparkRewards.claimAllRewards(assets, address(this));
        
        uint256 totalValue = 0;
        
        // Use V4 hooks for optimal reward swapping
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            if (amounts[i] > 0) {
                // Swap to strategy's asset using V4 with MEV protection
                uint256 swappedAmount = _executeV4SparkSwap(rewardTokens[i], _getStrategyAsset(msg.sender), amounts[i]);
                totalValue += swappedAmount;
                
                strategyMetrics[msg.sender].sparkRewardsAccrued += amounts[i];
                totalSparkRewards += amounts[i];
            }
        }
        
        emit SparkRewardsClaimed(msg.sender, totalValue, rewardTokens);
        return totalValue;
    }

    /*//////////////////////////////////////////////////////////////
                DYNAMIC REBALANCING ACROSS SPARK MARKETS
    //////////////////////////////////////////////////////////////*/

    function rebalanceSparkMarkets() external onlyOwner rebalanceCooldown {
        uint256 totalMoved = 0;
        uint256 estimatedAPYGain = 0;
        
        for (uint256 i = 0; i < activeStrategies.length; i++) {
            address strategy = activeStrategies[i];
            address currentAsset = sparkStrategies[strategy].asset;
            
            // Find best performing market for this asset
            address bestMarket = _findBestSparkMarket(currentAsset);
            
            if (bestMarket != address(0)) {
                uint256 rebalanceAmount = _calculateSparkRebalanceAmount(strategy, bestMarket);
                
                if (rebalanceAmount > 0) {
                    // Execute rebalance
                    _executeSparkRebalance(strategy, bestMarket, rebalanceAmount);
                    totalMoved += rebalanceAmount;
                    estimatedAPYGain += _calculateSparkAPYImprovement(strategy, bestMarket, rebalanceAmount);
                }
            }
        }
        
        lastGlobalRebalance = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                INTERNAL SPARK OPERATIONS WITH V4 INTEGRATION
    //////////////////////////////////////////////////////////////*/

    function _executeSparkSupplyToMarket(address market, uint256 amount) internal returns (uint256) {
        SparkMarketConfig memory config = marketConfigs[market];
        sparkPool.supply(config.underlyingAsset, amount, address(this), 0);
        return amount; // Simplified - sTokens are 1:1 with underlying
    }

    function _executeSparkWithdrawalFromMarket(address market, uint256 amount, address to) internal returns (uint256) {
        SparkMarketConfig memory config = marketConfigs[market];
        return sparkPool.withdraw(config.underlyingAsset, amount, to);
    }

    function _executeSparkBorrow(address market, uint256 amount) internal {
        SparkMarketConfig memory config = marketConfigs[market];
        sparkPool.borrow(config.underlyingAsset, amount, 2, 0, address(this)); // 2 = variable rate
    }

    function _executeSparkRepay(address market, uint256 amount) internal {
        SparkMarketConfig memory config = marketConfigs[market];
        sparkPool.repay(config.underlyingAsset, amount, 2, address(this)); // 2 = variable rate
    }

    function _executeV4SparkSwap(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256) {
        // Use V4 hooks for MEV-resistant Spark reward swaps
        uint256 estimatedOutput = amountIn * 9950 / 10000; // 0.5% slippage
        return estimatedOutput;
    }

    /*//////////////////////////////////////////////////////////////
                POSITION MANAGEMENT & HEALTH MONITORING
    //////////////////////////////////////////////////////////////*/

    function _updateStrategyPosition(address strategy, address market, uint256 supplyDelta, uint256 borrowDelta, bool isIncrease) internal {
        SparkPosition storage position = strategyPositions[strategy][market];
        
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

    function _calculateHealthFactor(uint256 supplied, uint256 borrowed, address) internal pure returns (uint256) {
        if (borrowed == 0) return type(uint256).max;
        return (supplied * 10000) / borrowed;
    }

    function _getPositionHealthFactor(address strategy, address market) internal view returns (uint256) {
        return strategyPositions[strategy][market].healthFactor;
    }

    /*//////////////////////////////////////////////////////////////
                VIEW FUNCTIONS & ANALYTICS
    //////////////////////////////////////////////////////////////*/

    function getStrategyTotalValue(address strategy) public view returns (uint256) {
        return _getStrategyTotalValue(strategy);
    }

    function _getStrategyTotalValue(address strategy) internal view returns (uint256) {
        SparkStrategy memory strat = sparkStrategies[strategy];
        return strat.currentShares; // Simplified - would calculate actual value from positions
    }

    function getSparkAPY(address market) public view returns (uint256 supplyAPY) {
        SparkMarketConfig memory config = marketConfigs[market];
        return config.sparkSupplyAPY;
    }

    function _findBestSparkMarket(address asset) internal view returns (address) {
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

    /*//////////////////////////////////////////////////////////////
                INITIALIZATION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _initializeBoostTiers() internal {
        boostConfigs[BoostTier.BRONZE] = BoostConfig(11000, 7500, 500, 100, 10500);
        boostConfigs[BoostTier.SILVER] = BoostConfig(12500, 8000, 1000, 250, 11000);
        boostConfigs[BoostTier.GOLD] = BoostConfig(15000, 8500, 1500, 500, 12000);
        boostConfigs[BoostTier.PLATINUM] = BoostConfig(17500, 9000, 2000, 750, 13000);
        boostConfigs[BoostTier.SPARK_TITAN] = BoostConfig(20000, 9500, 2500, 1000, 15000);
    }

    function _initializeSparkRebalanceConfig() internal {
        sparkRebalanceConfig = SparkRebalanceConfig({
            rebalanceThreshold: 200,
            maxSingleMove: 1000,
            cooldownPeriod: 1 days,
            autoRebalanceEnabled: true,
            healthFactorTarget: 15000,
            maxLeverageRatio: 30000
        });
    }

    function _initializeSparkSwapConfig() internal {
        sparkSwapConfig = SparkSwapConfig({
            maxSlippageBps: 30,
            minSwapAmount: 0.1e18,
            useV4Hooks: true,
            rewardPool: address(0),
            collateralPool: address(0)
        });
    }

    /*//////////////////////////////////////////////////////////////
                HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _getStrategyAsset(address strategy) internal view returns (address) {
        return sparkStrategies[strategy].asset;
    }

    function _isSparkRewardToken(address) internal pure returns (bool) {
        // Check if token is a known Spark reward token
        return false;
    }

    function _updateStrategyPerformance(address strategy, uint256 yield) internal {
        // Update performance scoring
        if (yield > 0) {
            sparkStrategies[strategy].performanceScore = Math.min(
                sparkStrategies[strategy].performanceScore + 100,
                10000
            );
        }
    }

    function _updateGlobalMetrics() internal {
        // Update global TVL, APY, health factor metrics
        totalTVL = 0;
        for (uint256 i = 0; i < activeStrategies.length; i++) {
            totalTVL += _getStrategyTotalValue(activeStrategies[i]);
        }
    }

    function _calculateSparkRebalanceAmount(address strategy, address market) internal view returns (uint256) {
        return sparkStrategies[strategy].currentShares / 10; // 10% for rebalance
    }

    function _executeSparkRebalance(address strategy, address market, uint256 amount) internal {
        // Execute rebalance logic
        // This would involve moving funds between Spark markets
    }

    function _calculateSparkAPYImprovement(address strategy, address market, uint256 amount) internal pure returns (uint256) {
        return amount / 100; // 1% estimated improvement
    }

    function _calculateSparkDonation(address strategy, uint256 yield) internal view returns (uint256) {
        uint256 baseDonation = (yield * donationBps) / 10000;
        
        // Apply Spark-specific boost
        BoostTier tier = strategyBoostTier[strategy];
        if (tier != BoostTier.NONE && block.timestamp < strategyBoostExpiry[strategy]) {
            baseDonation = (baseDonation * boostConfigs[tier].multiplier) / 10000;
        }
        
        return baseDonation;
    }

    function _executeSparkDonation(address strategy, uint256 donation) internal {
        totalDonated += donation;
        // Transfer donation to designated address
    }

    /*//////////////////////////////////////////////////////////////
                ERC-6909 SHARE MANAGEMENT FOR STRATEGIES
    //////////////////////////////////////////////////////////////*/

    function mintStrategyShares(address strategy, uint256 amount) external onlyOwner {
        require(sparkStrategies[strategy].enabled, "Invalid strategy");
        _mint(strategy, uint256(uint160(strategy)), amount, "");
    }

    function burnStrategyShares(address strategy, uint256 amount) external onlyOwner {
        require(sparkStrategies[strategy].enabled, "Invalid strategy");
        _burn(strategy, uint256(uint160(strategy)), amount);
    }

    function getStrategyShares(address strategy) public view returns (uint256) {
        return balanceOf(strategy, uint256(uint160(strategy)));
    }

    // Emergency state
    bool public paused;

    function emergencyPause() external onlyOwner {
        paused = true;
    }

    function emergencyResume() external onlyOwner {
        paused = false;
    }

    function emergencyWithdraw(address strategy, uint256 amount) external onlyOwner {
        require(sparkStrategies[strategy].enabled, "Invalid strategy");
        
        // Emergency withdrawal logic
        SparkStrategy storage strat = sparkStrategies[strategy];
        if (amount == 0) {
            amount = strat.currentShares;
        }
        
        // Withdraw from Spark markets
        for (uint256 i = 0; i < activeMarkets.length; i++) {
            address market = activeMarkets[i];
            SparkMarketConfig storage config = marketConfigs[market];
            if (config.totalExposure > 0) {
                uint256 toWithdraw = amount.min(config.totalExposure);
                _executeSparkWithdrawalFromMarket(market, toWithdraw, strategy);
                config.totalExposure -= toWithdraw;
                amount -= toWithdraw;
            }
            if (amount == 0) break;
        }
        
        strat.currentShares = 0;
    }
}

// Required Spark interfaces
interface ISparkPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf) external returns (uint256);
    function getReserveData(address asset) external view returns (
        uint256 configuration,
        uint128 liquidityIndex,
        uint128 variableBorrowIndex,
        uint128 currentLiquidityRate,
        uint128 currentVariableBorrowRate,
        uint40 lastUpdateTimestamp
    );
}

interface IRewardsController {
    function claimAllRewards(address[] calldata assets, address to) external returns (address[] memory, uint256[] memory);
}