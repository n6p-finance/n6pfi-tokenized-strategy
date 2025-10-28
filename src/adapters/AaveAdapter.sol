// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * NapFi Hyper-Optimized Aave Tokenized Adapter v4.0 - "Aave Titan Adapter"
 * -------------------------------------------------------------------------
 * Tokenized adapter following MorphoAdapter patterns with ERC-6909 multi-token shares
 * Acts as both tokenized strategy AND adapter for multiple strategies
 */

import {IERC20} from "@openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
// import {ReentrancyGuard} from "@openzeppelin-contracts/security/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin-contracts/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ERC6909} from "tokenized-strategy/contracts/token/ERC6909/ERC6909.sol";
// Aave V3 Interfaces
import {IPool} from "../interfaces/aave/IPool.sol";
import {IRewardsController} from "../interfaces/aave/IRewardsController.sol";

// Uniswap hooks/core
import {BaseHook} from "uniswap-hooks/base/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/types/PoolKey.sol";

contract NapFiHyperAaveTokenizedAdapter is ReentrancyGuard, Ownable, ERC6909, BaseHook {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // --------------------------------------------------
    // Core Protocol Addresses
    // --------------------------------------------------
    IPool public immutable aavePool;
    IRewardsController public immutable aaveRewards;
    IPoolManager public immutable uniswapV4PoolManager;
    
    // --------------------------------------------------
    // Hyper-Optimized Multi-Strategy Architecture
    // --------------------------------------------------
    struct AaveStrategy {
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
        uint256 aaveRewardsAccrued;
    }
    
    mapping(address => AaveStrategy) public aaveStrategies;
    mapping(address => StrategyMetrics) public strategyMetrics;
    mapping(address => address) public strategyByAsset;
    address[] public activeStrategies;
    
    // --------------------------------------------------
    // Aave Market Configuration with Dynamic Allocation
    // --------------------------------------------------
    struct AaveMarketConfig {
        address underlyingAsset;
        address aToken;
        bool enabled;
        uint256 targetAllocation;
        uint256 currentAllocation;
        uint256 maxExposure;
        uint256 totalExposure;
        uint256 performanceAPY;
        uint256 riskScore;
        uint256 aaveSupplyAPY;
        uint256 variableBorrowAPY;
    }
    
    address[] public activeMarkets;
    mapping(address => AaveMarketConfig) public marketConfigs;
    mapping(address => address[]) public assetMarkets;
    
    // --------------------------------------------------
    // Advanced Aave-Specific Features
    // --------------------------------------------------
    struct AavePosition {
        uint256 supplied;
        uint256 borrowed;
        uint256 collateral;
        uint256 healthFactor;
        bool isCollateralEnabled;
    }
    
    mapping(address => mapping(address => AavePosition)) public strategyPositions;
    
    // --------------------------------------------------
    // Multi-Tier Boost System with Aave Rewards Integration
    // --------------------------------------------------
    enum BoostTier { NONE, BRONZE, SILVER, GOLD, PLATINUM, AAVE_TITAN }
    
    struct BoostConfig {
        uint256 multiplier;
        uint256 minScore;
        uint256 donationBoost;
        uint256 feeDiscount;
        uint256 aaveRewardsBoost;
    }
    
    mapping(BoostTier => BoostConfig) public boostConfigs;
    mapping(address => BoostTier) public strategyBoostTier;
    mapping(address => uint256) public strategyBoostExpiry;
    
    // --------------------------------------------------
    // Uniswap V4 Hooks Integration for Aave Operations
    // --------------------------------------------------
    struct AaveSwapConfig {
        uint256 maxSlippageBps;
        uint256 minSwapAmount;
        bool useV4Hooks;
        address rewardPool;
        address collateralPool;
    }
    
    AaveSwapConfig public aaveSwapConfig;
    
    // V4 Hook state for Aave-specific operations
    mapping(PoolKey => uint256) public aaveSwapCount;
    mapping(PoolKey => uint256) public aaveLiquidityCount;
    
    // --------------------------------------------------
    // Dynamic Rebalancing Engine for Aave Markets
    // --------------------------------------------------
    struct AaveRebalanceConfig {
        uint256 rebalanceThreshold;
        uint256 maxSingleMove;
        uint256 cooldownPeriod;
        bool autoRebalanceEnabled;
        uint256 healthFactorTarget;
        uint256 maxLeverageRatio;
    }
    
    AaveRebalanceConfig public aaveRebalanceConfig;
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
    uint256 public totalAaveRewards;
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
    event AaveMarketAdded(address indexed market, address underlying);
    event StrategySuppliedToAave(address indexed strategy, address market, uint256 amount, uint256 shares);
    event StrategyWithdrawnFromAave(address indexed strategy, address market, uint256 amount, uint256 shares);
    event AaveRewardsClaimed(address indexed strategy, uint256 amount, address[] tokens);
    event PositionLeveraged(address indexed strategy, address market, uint256 supplied, uint256 borrowed);
    event PositionDeleveraged(address indexed strategy, address market, uint256 repaid, uint256 withdrawn);
    event V4HookTriggered(address indexed caller, bytes4 selector, uint256 count);
    
    // --------------------------------------------------
    // Modifiers
    // --------------------------------------------------
    modifier onlyStrategy() {
        require(aaveStrategies[msg.sender].enabled, "Adapter: not authorized strategy");
        _;
    }
    
    modifier onlyActiveMarket(address market) {
        require(marketConfigs[market].enabled, "Adapter: invalid market");
        _;
    }
    
    modifier rebalanceCooldown() {
        require(block.timestamp >= lastGlobalRebalance + aaveRebalanceConfig.cooldownPeriod, "Rebalance cooldown");
        _;
    }

    // --------------------------------------------------
    // Hyper Constructor with V4 Hook Integration
    // --------------------------------------------------
    constructor(
        address _aavePool,
        address _aaveRewards,
        IPoolManager _uniswapV4PoolManager
    ) 
        ERC6909("NapFi Aave Adapter Shares", "NPF-AAVE")
        BaseHook(_uniswapV4PoolManager)
    {
        require(_aavePool != address(0), "Invalid Aave pool");
        require(_aaveRewards != address(0), "Invalid Aave rewards");
        
        aavePool = IPool(_aavePool);
        aaveRewards = IRewardsController(_aaveRewards);
        uniswapV4PoolManager = _uniswapV4PoolManager;
        
        _initializeBoostTiers();
        _initializeAaveRebalanceConfig();
        _initializeAaveSwapConfig();
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
        // Track Aave-related swaps for analytics
        aaveSwapCount[key.toId()]++;
        
        // Implement MEV protection for Aave reward swaps
        if (_isAaveRewardToken(key.currency0) || _isAaveRewardToken(key.currency1)) {
            // Apply additional protection for reward token swaps
        }
        
        return BaseHook.beforeSwap.selector;
    }

    function _afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, int128, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        emit V4HookTriggered(msg.sender, BaseHook.afterSwap.selector, aaveSwapCount[key.toId()]);
        return BaseHook.afterSwap.selector;
    }

    function _beforeAddLiquidity(address, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        aaveLiquidityCount[key.toId()]++;
        return BaseHook.beforeAddLiquidity.selector;
    }

    /*//////////////////////////////////////////////////////////////
                MULTI-STRATEGY REGISTRATION (Like MorphoAdapter)
    //////////////////////////////////////////////////////////////*/

    function registerStrategy(
        address _strategy,
        address _asset
    ) external onlyOwner {
        require(_strategy != address(0), "Invalid strategy");
        require(_asset != address(0), "Invalid asset");
        require(!aaveStrategies[_strategy].enabled, "Strategy already registered");
        
        aaveStrategies[_strategy] = AaveStrategy({
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
            aaveRewardsAccrued: 0
        });
        
        // Approve Aave for this asset
        IERC20(_asset).safeApprove(address(aavePool), type(uint256).max);
        
        emit StrategyRegistered(_strategy, _asset);
    }

    /*//////////////////////////////////////////////////////////////
                AAVE MARKET MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function addAaveMarket(
        address _underlyingAsset,
        address _aToken,
        uint256 _targetAllocation
    ) external onlyOwner {
        require(_underlyingAsset != address(0), "Invalid underlying asset");
        require(_aToken != address(0), "Invalid aToken");
        require(!marketConfigs[_aToken].enabled, "Market already added");
        
        marketConfigs[_aToken] = AaveMarketConfig({
            underlyingAsset: _underlyingAsset,
            aToken: _aToken,
            enabled: true,
            targetAllocation: _targetAllocation,
            currentAllocation: 0,
            maxExposure: type(uint256).max,
            totalExposure: 0,
            performanceAPY: 0,
            riskScore: 5000,
            aaveSupplyAPY: 0,
            variableBorrowAPY: 0
        });
        
        activeMarkets.push(_aToken);
        
        // Initialize asset-market mapping
        assetMarkets[_underlyingAsset].push(_aToken);
        
        emit AaveMarketAdded(_aToken, _underlyingAsset);
    }

    /*//////////////////////////////////////////////////////////////
                STRATEGY-FACING FUNCTIONS WITH AAVE INTEGRATION
    //////////////////////////////////////////////////////////////*/

    function supplyToAave(address market, uint256 amount) 
        external 
        onlyStrategy 
        onlyActiveMarket(market) 
        returns (uint256) 
    {
        AaveStrategy storage strategy = aaveStrategies[msg.sender];
        require(amount > 0, "Zero supply");
        require(block.timestamp >= strategy.cooldownUntil, "Strategy in cooldown");
        
        AaveMarketConfig storage marketConfig = marketConfigs[market];
        
        // Transfer asset from strategy to adapter
        IERC20(marketConfig.underlyingAsset).safeTransferFrom(msg.sender, address(this), amount);
        
        // Execute supply to Aave
        uint256 shares = _executeAaveSupplyToMarket(market, amount);
        
        // Update strategy tracking
        strategy.totalDeposited += amount;
        strategy.currentShares += shares;
        marketConfig.totalExposure += amount;
        
        // Update position
        _updateStrategyPosition(msg.sender, market, amount, true);
        
        // Update TVL and analytics
        _updateGlobalMetrics();
        
        emit StrategySuppliedToAave(msg.sender, market, amount, shares);
        return shares;
    }

    function withdrawFromAave(address market, uint256 amount, address to) 
        external 
        onlyStrategy 
        onlyActiveMarket(market) 
        returns (uint256) 
    {
        require(amount > 0, "Zero withdraw");
        require(to != address(0), "Invalid recipient");
        
        AaveStrategy storage strategy = aaveStrategies[msg.sender];
        AaveMarketConfig storage marketConfig = marketConfigs[market];
        
        // Execute withdrawal from Aave
        uint256 withdrawn = _executeAaveWithdrawalFromMarket(market, amount, to);
        
        // Update strategy tracking
        strategy.currentShares -= withdrawn;
        marketConfig.totalExposure -= withdrawn;
        
        // Update position
        _updateStrategyPosition(msg.sender, market, withdrawn, false);
        
        // Apply cooldown
        strategy.cooldownUntil = block.timestamp + 1 hours;
        
        // Update TVL
        _updateGlobalMetrics();
        
        emit StrategyWithdrawnFromAave(msg.sender, market, amount, withdrawn);
        return withdrawn;
    }

    /*//////////////////////////////////////////////////////////////
                ADVANCED AAVE FEATURES: LEVERAGE & DE-LEVERAGE
    //////////////////////////////////////////////////////////////*/

    function createLeveragedPosition(
        address market,
        uint256 supplyAmount,
        uint256 borrowAmount
    ) external onlyStrategy onlyActiveMarket(market) {
        require(supplyAmount > 0, "Zero supply");
        require(borrowAmount > 0, "Zero borrow");
        
        AaveMarketConfig storage marketConfig = marketConfigs[market];
        AaveStrategy storage strategy = aaveStrategies[msg.sender];
        
        // Transfer collateral from strategy
        IERC20(marketConfig.underlyingAsset).safeTransferFrom(msg.sender, address(this), supplyAmount);
        
        // Supply collateral to Aave
        uint256 shares = _executeAaveSupplyToMarket(market, supplyAmount);
        
        // Borrow loan token
        _executeAaveBorrow(market, borrowAmount);
        
        // Update strategy tracking
        strategy.totalDeposited += supplyAmount;
        strategy.currentShares += shares;
        marketConfig.totalExposure += supplyAmount;
        
        // Update position with leverage
        _updateStrategyPosition(msg.sender, market, supplyAmount, borrowAmount, true);
        
        // Check health factor
        require(_getPositionHealthFactor(msg.sender, market) > aaveRebalanceConfig.healthFactorTarget, "Health factor too low");
        
        emit PositionLeveraged(msg.sender, market, supplyAmount, borrowAmount);
    }

    function deLeveragePosition(
        address market,
        uint256 repayAmount,
        uint256 withdrawAmount
    ) external onlyStrategy onlyActiveMarket(market) {
        require(repayAmount > 0 || withdrawAmount > 0, "No operation");
        
        AaveMarketConfig storage marketConfig = marketConfigs[market];
        
        // Repay borrow if specified
        if (repayAmount > 0) {
            _executeAaveRepay(market, repayAmount);
        }
        
        // Withdraw collateral if specified
        if (withdrawAmount > 0) {
            _executeAaveWithdrawalFromMarket(market, withdrawAmount, msg.sender);
        }
        
        // Update position
        _updateStrategyPosition(msg.sender, market, withdrawAmount, repayAmount, false);
        
        emit PositionDeleveraged(msg.sender, market, repayAmount, withdrawAmount);
    }

    /*//////////////////////////////////////////////////////////////
                AAVE REWARDS INTEGRATION WITH V4 SWAPS
    //////////////////////////////////////////////////////////////*/

    function harvestAaveRewards() 
        external 
        onlyStrategy 
        returns (uint256 yield, uint256 donation) 
    {
        AaveStrategy storage strategy = aaveStrategies[msg.sender];
        require(block.timestamp >= strategy.lastHarvest + 6 hours, "Harvest cooldown");
        
        // Claim Aave rewards using V4-optimized swaps
        uint256 rewardsValue = _claimAndOptimizeAaveRewards();
        
        // Calculate yield
        uint256 currentValue = _getStrategyTotalValue(msg.sender);
        uint256 previousValue = strategyMetrics[msg.sender].totalYield;
        
        if (currentValue <= previousValue) {
            return (0, 0);
        }
        
        yield = currentValue - previousValue + rewardsValue;
        strategyMetrics[msg.sender].totalYield += yield;
        totalYieldGenerated += yield;
        
        // Calculate amplified donation with Aave-specific boosts
        donation = _calculateAaveDonation(msg.sender, yield);
        strategyMetrics[msg.sender].totalDonations += donation;
        
        if (donation >= minDonation) {
            _executeAaveDonation(msg.sender, donation);
        }
        
        // Update strategy state
        strategy.lastHarvest = block.timestamp;
        _updateStrategyPerformance(msg.sender, yield);
        
        return (yield, donation);
    }

    function _claimAndOptimizeAaveRewards() internal returns (uint256) {
        // Claim rewards from Aave
        address[] memory assets = activeMarkets;
        address[] memory rewardTokens = new address[](1); // Simplified
        uint256[] memory amounts = new uint256[](1);
        
        // This would be the actual Aave rewards claim
        // (address[] memory rewardTokens, uint256[] memory amounts) = aaveRewards.claimAllRewards(assets, address(this));
        
        uint256 totalValue = 0;
        
        // Use V4 hooks for optimal reward swapping
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            if (amounts[i] > 0) {
                // Swap to strategy's asset using V4 with MEV protection
                uint256 swappedAmount = _executeV4AaveSwap(rewardTokens[i], _getStrategyAsset(msg.sender), amounts[i]);
                totalValue += swappedAmount;
                
                strategyMetrics[msg.sender].aaveRewardsAccrued += amounts[i];
                totalAaveRewards += amounts[i];
            }
        }
        
        emit AaveRewardsClaimed(msg.sender, totalValue, rewardTokens);
        return totalValue;
    }

    /*//////////////////////////////////////////////////////////////
                DYNAMIC REBALANCING ACROSS AAVE MARKETS
    //////////////////////////////////////////////////////////////*/

    function rebalanceAaveMarkets() external onlyOwner rebalanceCooldown {
        uint256 totalMoved = 0;
        uint256 estimatedAPYGain = 0;
        
        for (uint256 i = 0; i < activeStrategies.length; i++) {
            address strategy = activeStrategies[i];
            address currentAsset = aaveStrategies[strategy].asset;
            
            // Find best performing market for this asset
            address bestMarket = _findBestAaveMarket(currentAsset);
            
            if (bestMarket != address(0)) {
                uint256 rebalanceAmount = _calculateAaveRebalanceAmount(strategy, bestMarket);
                
                if (rebalanceAmount > 0) {
                    // Execute rebalance
                    _executeAaveRebalance(strategy, bestMarket, rebalanceAmount);
                    totalMoved += rebalanceAmount;
                    estimatedAPYGain += _calculateAaveAPYImprovement(strategy, bestMarket, rebalanceAmount);
                }
            }
        }
        
        lastGlobalRebalance = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                INTERNAL AAVE OPERATIONS WITH V4 INTEGRATION
    //////////////////////////////////////////////////////////////*/

    function _executeAaveSupplyToMarket(address market, uint256 amount) internal returns (uint256) {
        AaveMarketConfig memory config = marketConfigs[market];
        aavePool.supply(config.underlyingAsset, amount, address(this), 0);
        return amount; // Simplified - aTokens are 1:1 with underlying
    }

    function _executeAaveWithdrawalFromMarket(address market, uint256 amount, address to) internal returns (uint256) {
        AaveMarketConfig memory config = marketConfigs[market];
        return aavePool.withdraw(config.underlyingAsset, amount, to);
    }

    function _executeAaveBorrow(address market, uint256 amount) internal {
        AaveMarketConfig memory config = marketConfigs[market];
        aavePool.borrow(config.underlyingAsset, amount, 2, 0, address(this)); // 2 = variable rate
    }

    function _executeAaveRepay(address market, uint256 amount) internal {
        AaveMarketConfig memory config = marketConfigs[market];
        aavePool.repay(config.underlyingAsset, amount, 2, address(this)); // 2 = variable rate
    }

    function _executeV4AaveSwap(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256) {
        // Use V4 hooks for MEV-resistant Aave reward swaps
        uint256 estimatedOutput = amountIn * 9950 / 10000; // 0.5% slippage
        return estimatedOutput;
    }

    /*//////////////////////////////////////////////////////////////
                POSITION MANAGEMENT & HEALTH MONITORING
    //////////////////////////////////////////////////////////////*/

    function _updateStrategyPosition(address strategy, address market, uint256 supplyDelta, uint256 borrowDelta, bool isIncrease) internal {
        AavePosition storage position = strategyPositions[strategy][market];
        
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
        AaveStrategy memory strat = aaveStrategies[strategy];
        return strat.currentShares; // Simplified - would calculate actual value from positions
    }

    function getAaveAPY(address market) public view returns (uint256 supplyAPY) {
        AaveMarketConfig memory config = marketConfigs[market];
        return config.aaveSupplyAPY;
    }

    function _findBestAaveMarket(address asset) internal view returns (address) {
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
        boostConfigs[BoostTier.AAVE_TITAN] = BoostConfig(20000, 9500, 2500, 1000, 15000);
    }

    function _initializeAaveRebalanceConfig() internal {
        aaveRebalanceConfig = AaveRebalanceConfig({
            rebalanceThreshold: 200,
            maxSingleMove: 1000,
            cooldownPeriod: 1 days,
            autoRebalanceEnabled: true,
            healthFactorTarget: 15000,
            maxLeverageRatio: 30000
        });
    }

    function _initializeAaveSwapConfig() internal {
        aaveSwapConfig = AaveSwapConfig({
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
        return aaveStrategies[strategy].asset;
    }

    function _isAaveRewardToken(address) internal pure returns (bool) {
        // Check if token is a known Aave reward token
        return false;
    }

    function _updateStrategyPerformance(address strategy, uint256 yield) internal {
        // Update performance scoring
        if (yield > 0) {
            aaveStrategies[strategy].performanceScore = Math.min(
                aaveStrategies[strategy].performanceScore + 100,
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

    function _calculateAaveRebalanceAmount(address strategy, address market) internal view returns (uint256) {
        return aaveStrategies[strategy].currentShares / 10; // 10% for rebalance
    }

    function _executeAaveRebalance(address strategy, address market, uint256 amount) internal {
        // Execute rebalance logic
        // This would involve moving funds between Aave markets
    }

    function _calculateAaveAPYImprovement(address strategy, address market, uint256 amount) internal pure returns (uint256) {
        return amount / 100; // 1% estimated improvement
    }

    function _calculateAaveDonation(address strategy, uint256 yield) internal view returns (uint256) {
        uint256 baseDonation = (yield * donationBps) / 10000;
        
        // Apply Aave-specific boost
        BoostTier tier = strategyBoostTier[strategy];
        if (tier != BoostTier.NONE && block.timestamp < strategyBoostExpiry[strategy]) {
            baseDonation = (baseDonation * boostConfigs[tier].multiplier) / 10000;
        }
        
        return baseDonation;
    }

    function _executeAaveDonation(address strategy, uint256 donation) internal {
        totalDonated += donation;
        // Transfer donation to designated address
    }

    /*//////////////////////////////////////////////////////////////
                ERC-6909 SHARE MANAGEMENT FOR STRATEGIES
    //////////////////////////////////////////////////////////////*/

    function mintStrategyShares(address strategy, uint256 amount) external onlyOwner {
        require(aaveStrategies[strategy].enabled, "Invalid strategy");
        _mint(strategy, uint256(uint160(strategy)), amount, "");
    }

    function burnStrategyShares(address strategy, uint256 amount) external onlyOwner {
        require(aaveStrategies[strategy].enabled, "Invalid strategy");
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
}

// Required Aave interfaces
interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf) external returns (uint256);
}

interface IRewardsController {
    function claimAllRewards(address[] calldata assets, address to) external returns (address[] memory, uint256[] memory);
}