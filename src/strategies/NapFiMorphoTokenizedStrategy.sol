// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * NapFi Morpho Tokenized Strategy (Adapter + ERC-4626)
 * ----------------------------------------------------
 * Advanced Octant/Yearn v3-compatible modular strategy for Morpho Protocol
 * that integrates MorphoAdapter for Morpho Blue operations.
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseStrategy} from "tokenized-strategy/BaseStrategy.sol";
import {NapFiMorphoAdapter} from "../adapters/MorphoAdapter.sol";

contract NapFiMorphoTokenizedStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------
    // Core Configuration
    // ------------------------------------------------------------
    NapFiMorphoAdapter public immutable adapter;
    IERC20 public immutable ASSET;
    
    // ------------------------------------------------------------
    // Enhanced Strategy State
    // ------------------------------------------------------------
    uint256 public lastHarvestTimestamp;
    uint256 public cumulativeYield;
    uint256 public emergencyModeActivated;
    uint256 public constant MAX_SLIPPAGE = 50;
    
    // Morpho-specific parameters
    address public morphoMarket;
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
    event MorphoMarketUpdated(address oldMarket, address newMarket);
    event MorphoRewardsClaimed(address[] rewards, uint256[] amounts);

    // ------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------
    constructor(
        address _asset,
        string memory _name,
        address _adapter,
        address _morphoMarket,
        address[] memory _rewardTokens
    ) BaseStrategy(_asset, _name) {
        require(_asset != address(0), "Invalid asset");
        require(_adapter != address(0), "Invalid adapter");
        require(_morphoMarket != address(0), "Invalid Morpho market");

        adapter = NapFiMorphoAdapter(_adapter);
        ASSET = IERC20(_asset);
        morphoMarket = _morphoMarket;
        rewardTokens = _rewardTokens;

        ASSET.safeApprove(_adapter, type(uint256).max);
        
        // Initialize Morpho market in adapter
        _initializeMorphoMarket();
    }

    /*//////////////////////////////////////////////////////////////
                REQUIRED BASE STRATEGY OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Deploy funds to Morpho Blue market
     */
    function _deployFunds(uint256 _amount) internal override {
        if (_amount == 0) return;
        
        _validateMorphoDeploymentRisk(_amount);
        
        uint256 gasBefore = gasleft();
        try adapter.supplyToMorpho(_amount, morphoMarket) {
            uint256 gasUsed = gasBefore - gasleft();
            emit AdapterInteraction(address(adapter), "supplyToMorpho", _amount, true);
            emit YieldOptimized(_amount, _getMorphoEstimatedAPY());
        } catch {
            emit AdapterInteraction(address(adapter), "supplyToMorpho", _amount, false);
            _handleDeploymentFailure(_amount);
        }
    }

    /**
     * @dev Free funds from Morpho Blue market
     */
    function _freeFunds(uint256 _amount) internal override {
        if (_amount == 0) return;
        
        uint256 safeWithdrawAmount = _calculateMorphoSafeWithdrawal(_amount);
        
        if (safeWithdrawAmount > 0) {
            uint256 gasBefore = gasleft();
            try adapter.withdrawFromMorpho(safeWithdrawAmount, morphoMarket, address(this)) {
                uint256 gasUsed = gasBefore - gasleft();
                emit AdapterInteraction(address(adapter), "withdrawFromMorpho", safeWithdrawAmount, true);
            } catch {
                emit AdapterInteraction(address(adapter), "withdrawFromMorpho", safeWithdrawAmount, false);
                _handleWithdrawalFailure(safeWithdrawAmount);
            }
        }
        
        if (safeWithdrawAmount < _amount) {
            _handleWithdrawalShortfall(_amount - safeWithdrawAmount);
        }
    }

    /**
     * @dev Harvest Morpho rewards and report total assets
     */
    function _harvestAndReport() internal override returns (uint256 _totalAssets) {
        uint256 initialGas = gasleft();
        uint256 preHarvestAssets = adapter.totalAssets(morphoMarket);
        
        // Morpho-specific harvesting with reward claiming
        _executeMorphoHarvest();
        
        _postHarvestOptimization();
        
        _totalAssets = adapter.totalAssets(morphoMarket);
        
        uint256 yieldGenerated = _totalAssets > preHarvestAssets ? 
            _totalAssets - preHarvestAssets : 0;
        cumulativeYield += yieldGenerated;
        lastHarvestTimestamp = block.timestamp;
        
        uint256 gasUsed = initialGas - gasleft();
        
        emit StrategyEnhancedHarvest(
            _totalAssets, 
            yieldGenerated, 
            block.timestamp, 
            gasUsed
        );
    }

    /*//////////////////////////////////////////////////////////////
                MORPHO-SPECIFIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Initialize Morpho market in adapter
     */
    function _initializeMorphoMarket() internal {
        try adapter.initializeMarket(morphoMarket) {
            emit AdapterInteraction(address(adapter), "initializeMarket", 0, true);
        } catch {
            emit AdapterInteraction(address(adapter), "initializeMarket", 0, false);
        }
    }

    /**
     * @dev Execute Morpho-specific harvesting with reward claiming
     */
    function _executeMorphoHarvest() internal {
        // Phase 1: Claim Morpho rewards (MORPHO tokens, market rewards)
        try adapter.claimMorphoRewards(morphoMarket) returns (address[] memory tokens, uint256[] memory amounts) {
            emit MorphoRewardsClaimed(tokens, amounts);
            emit AdapterInteraction(address(adapter), "claimMorphoRewards", 0, true);
        } catch (bytes memory reason) {
            emit AdapterInteraction(address(adapter), "claimMorphoRewards", 0, false);
            _logHarvestError(reason);
        }
        
        // Phase 2: Process and compound Morpho rewards
        _processMorphoRewards();
        
        // Phase 3: Standard harvest operations
        try adapter.harvest(morphoMarket) {
            emit AdapterInteraction(address(adapter), "harvest", 0, true);
        } catch (bytes memory reason) {
            emit AdapterInteraction(address(adapter), "harvest", 0, false);
            _logHarvestError(reason);
        }
    }

    /**
     * @dev Process Morpho-specific rewards
     */
    function _processMorphoRewards() internal {
        try adapter.processMorphoRewards(morphoMarket, rewardTokens) {
            emit AdapterInteraction(address(adapter), "processMorphoRewards", 0, true);
        } catch {
            emit AdapterInteraction(address(adapter), "processMorphoRewards", 0, false);
        }
    }

    /**
     * @dev Update Morpho market (only management)
     */
    function updateMorphoMarket(address newMarket) external onlyManagement {
        require(newMarket != address(0), "Invalid market");
        require(newMarket != morphoMarket, "Same market");
        
        address oldMarket = morphoMarket;
        morphoMarket = newMarket;
        
        // Reinitialize with new market
        _initializeMorphoMarket();
        
        emit MorphoMarketUpdated(oldMarket, newMarket);
    }

    /**
     * @dev Get Morpho market health metrics
     */
    function _getMorphoMarketHealth() internal view returns (uint256 collateralRatio, uint256 ltv) {
        try adapter.getMarketHealth(morphoMarket) returns (uint256 _collateralRatio, uint256 _ltv) {
            return (_collateralRatio, _ltv);
        } catch {
            return (type(uint256).max, 0);
        }
    }

    /*//////////////////////////////////////////////////////////////
                OPTIONAL BASE STRATEGY OVERRIDES
    //////////////////////////////////////////////////////////////*/

    function availableDepositLimit(address) public view override returns (uint256) {
        try adapter.availableDepositLimit(morphoMarket) returns (uint256 adapterLimit) {
            return adapterLimit;
        } catch {
            return type(uint256).max;
        }
    }

    function availableWithdrawLimit(address _owner) public view override returns (uint256) {
        uint256 baseLimit = asset.balanceOf(address(this));
        
        try adapter.availableWithdrawLimit(morphoMarket) returns (uint256 adapterWithdrawLimit) {
            return baseLimit + adapterWithdrawLimit;
        } catch {
            return baseLimit + _calculateMorphoMaxWithdrawable();
        }
    }

    function _tend(uint256 _totalIdle) internal override {
        if (!_shouldTend()) return;
        
        if (_totalIdle > _getTendThreshold()) {
            _deployFunds(_totalIdle);
        }
        
        _claimMorphoRewardsIfWorthwhile();
    }

    function _tendTrigger() internal view override returns (bool) {
        if (_hasSignificantIdleFunds()) return true;
        if (_morphoRewardsAreClaimable()) return true;
        if (_morphoMarketConditionsFavorable()) return true;
        if (_morphoNeedsRebalancing()) return true;
        
        return false;
    }

    function _emergencyWithdraw(uint256 _amount) internal override {
        emergencyModeActivated = block.timestamp;
        emit EmergencyModeActivated(block.timestamp, "Manual emergency withdrawal");
        
        try adapter.emergencyWithdraw(_amount, morphoMarket) {
            emit AdapterInteraction(address(adapter), "emergencyWithdraw", _amount, true);
        } catch {
            try adapter.withdrawFromMorpho(_amount, morphoMarket, address(this)) {
                emit AdapterInteraction(address(adapter), "emergencyWithdraw_fallback", _amount, true);
            } catch {
                emit AdapterInteraction(address(adapter), "emergencyWithdraw_fallback", _amount, false);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                MORPHO-SPECIFIC VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _morphoRewardsAreClaimable() internal view returns (bool) {
        try adapter.morphoRewardsAvailable(morphoMarket) returns (bool available) {
            return available;
        } catch {
            return false;
        }
    }

    function _morphoMarketConditionsFavorable() internal view returns (bool) {
        try adapter.morphoMarketConditionsFavorable(morphoMarket) returns (bool favorable) {
            return favorable;
        } catch {
            return true;
        }
    }

    function _morphoNeedsRebalancing() internal view returns (bool) {
        try adapter.needsRebalancing(morphoMarket) returns (bool needsRebalance) {
            return needsRebalance;
        } catch {
            return false;
        }
    }

    function _calculateMorphoSafeWithdrawal(uint256 requestedAmount) internal view returns (uint256) {
        try adapter.getMaxSafeWithdrawal(morphoMarket) returns (uint256 maxSafe) {
            return requestedAmount > maxSafe ? maxSafe : requestedAmount;
        } catch {
            return requestedAmount;
        }
    }

    function _calculateMorphoMaxWithdrawable() internal view returns (uint256) {
        try adapter.maxWithdrawable(morphoMarket) returns (uint256 maxWithdraw) {
            return maxWithdraw;
        } catch {
            return adapter.totalAssets(morphoMarket);
        }
    }

    function _getMorphoEstimatedAPY() internal view returns (uint256) {
        try adapter.getMorphoEstimatedAPY(morphoMarket) returns (uint256 apy) {
            return apy;
        } catch {
            return 0;
        }
    }

    function _validateMorphoDeploymentRisk(uint256 _amount) internal view {
        try adapter.isMorphoMarketHealthy(morphoMarket) returns (bool healthy) {
            require(healthy, "Morpho market unhealthy");
        } catch {}
        
        require(emergencyModeActivated == 0, "Strategy in emergency mode");
        require(_amount <= ASSET.balanceOf(address(this)), "Insufficient balance for deployment");
    }

    function _claimMorphoRewardsIfWorthwhile() internal {
        if (_morphoRewardsAreClaimable() && _isGasEfficientToClaim()) {
            try adapter.claimMorphoRewards(morphoMarket) {
                emit AdapterInteraction(address(adapter), "claimMorphoRewards", 0, true);
            } catch {
                emit AdapterInteraction(address(adapter), "claimMorphoRewards", 0, false);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                SHARED INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _postHarvestOptimization() internal {
        uint256 idleAssets = ASSET.balanceOf(address(this));
        if (idleAssets > _getAutoCompoundThreshold()) {
            _deployFunds(idleAssets);
        }
    }

    function _getAutoCompoundThreshold() internal view returns (uint256) {
        uint256 totalAssets = adapter.totalAssets(morphoMarket);
        uint256 dynamicThreshold = totalAssets / 1000;
        uint256 minThreshold = 1 * 10**IERC20Metadata(address(ASSET)).decimals();
        return dynamicThreshold > minThreshold ? dynamicThreshold : minThreshold;
    }

    function _getTendThreshold() internal view returns (uint256) {
        return _getAutoCompoundThreshold() / 10;
    }

    function _shouldTend() internal view returns (bool) {
        return !_isEmergencyMode() && _tendTrigger();
    }

    function _isEmergencyMode() internal view returns (bool) {
        return emergencyModeActivated > 0;
    }

    function _hasSignificantIdleFunds() internal view returns (bool) {
        return ASSET.balanceOf(address(this)) > _getTendThreshold();
    }

    function _isGasEfficientToClaim() internal view returns (bool) {
        try adapter.claimingGasEfficient() returns (bool efficient) {
            return efficient;
        } catch {
            return true;
        }
    }

    function _handleDeploymentFailure(uint256) internal {}
    function _handleWithdrawalFailure(uint256) internal {}
    function _handleWithdrawalShortfall(uint256) internal {}
    function _logHarvestError(bytes memory) internal {}
}

interface IERC20Metadata {
    function decimals() external view returns (uint8);
}