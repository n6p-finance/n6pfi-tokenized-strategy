// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * NapFi Spark Tokenized Strategy (Adapter + ERC-4626)
 * ---------------------------------------------------
 * Advanced Octant/Yearn v3-compatible modular strategy for Spark Protocol
 * that integrates SparkAdapter for Spark Lending operations.
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseStrategy} from "tokenized-strategy/BaseStrategy.sol";
import {NapFiSparkAdapter} from "../adapters/SparkAdapter.sol";

contract NapFiSparkTokenizedStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------
    // Core Configuration
    // ------------------------------------------------------------
    NapFiSparkAdapter public immutable adapter;
    IERC20 public immutable ASSET;
    
    // ------------------------------------------------------------
    // Enhanced Strategy State
    // ------------------------------------------------------------
    uint256 public lastHarvestTimestamp;
    uint256 public cumulativeYield;
    uint256 public emergencyModeActivated;
    uint256 public constant MAX_SLIPPAGE = 50; // 0.5% max slippage
    
    // Spark-specific reward tokens (SPK, CRV, etc.)
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
    event SparkRewardsClaimed(address[] rewards, uint256[] amounts);

    // ------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------
    constructor(
        address _asset,
        string memory _name,
        address _adapter,
        address[] memory _rewardTokens
    ) BaseStrategy(_asset, _name) {
        require(_asset != address(0), "Invalid asset");
        require(_adapter != address(0), "Invalid adapter");

        adapter = NapFiSparkAdapter(_adapter);
        ASSET = IERC20(_asset);
        rewardTokens = _rewardTokens;

        // Enhanced pre-approvals for gas optimization
        ASSET.safeApprove(_adapter, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                REQUIRED BASE STRATEGY OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Deploy funds to Spark Protocol
     */
    function _deployFunds(uint256 _amount) internal override {
        if (_amount == 0) return;
        
        _validateDeploymentRisk(_amount);
        
        uint256 gasBefore = gasleft();
        try adapter.depositToSpark(_amount) {
            uint256 gasUsed = gasBefore - gasleft();
            emit AdapterInteraction(address(adapter), "depositToSpark", _amount, true);
            emit YieldOptimized(_amount, _getEstimatedAPY());
        } catch {
            emit AdapterInteraction(address(adapter), "depositToSpark", _amount, false);
            _handleDeploymentFailure(_amount);
        }
    }

    /**
     * @dev Free funds from Spark Protocol
     */
    function _freeFunds(uint256 _amount) internal override {
        if (_amount == 0) return;
        
        uint256 safeWithdrawAmount = _calculateSafeWithdrawal(_amount);
        
        if (safeWithdrawAmount > 0) {
            uint256 gasBefore = gasleft();
            try adapter.withdrawFromSpark(safeWithdrawAmount, address(this)) {
                uint256 gasUsed = gasBefore - gasleft();
                emit AdapterInteraction(address(adapter), "withdrawFromSpark", safeWithdrawAmount, true);
            } catch {
                emit AdapterInteraction(address(adapter), "withdrawFromSpark", safeWithdrawAmount, false);
                _handleWithdrawalFailure(safeWithdrawAmount);
            }
        }
        
        if (safeWithdrawAmount < _amount) {
            _handleWithdrawalShortfall(_amount - safeWithdrawAmount);
        }
    }

    /**
     * @dev Harvest Spark rewards and report total assets
     */
    function _harvestAndReport() internal override returns (uint256 _totalAssets) {
        uint256 initialGas = gasleft();
        uint256 preHarvestAssets = adapter.totalAssets();
        
        // Spark-specific harvesting with reward claiming
        _executeSparkHarvest();
        
        _postHarvestOptimization();
        
        _totalAssets = adapter.totalAssets();
        
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
                SPARK-SPECIFIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Execute Spark-specific harvesting with reward distribution
     */
    function _executeSparkHarvest() internal {
        // Phase 1: Claim Spark rewards (SPK, CRV, etc.)
        try adapter.claimSparkRewards() returns (address[] memory tokens, uint256[] memory amounts) {
            emit SparkRewardsClaimed(tokens, amounts);
            emit AdapterInteraction(address(adapter), "claimSparkRewards", 0, true);
        } catch (bytes memory reason) {
            emit AdapterInteraction(address(adapter), "claimSparkRewards", 0, false);
            _logHarvestError(reason);
        }
        
        // Phase 2: Process and compound rewards
        _processSparkRewards();
        
        // Phase 3: Standard harvest operations
        try adapter.harvest() {
            emit AdapterInteraction(address(adapter), "harvest", 0, true);
        } catch (bytes memory reason) {
            emit AdapterInteraction(address(adapter), "harvest", 0, false);
            _logHarvestError(reason);
        }
    }

    /**
     * @dev Process Spark-specific rewards (SPK, CRV, etc.)
     */
    function _processSparkRewards() internal {
        try adapter.processSparkRewards(rewardTokens) {
            emit AdapterInteraction(address(adapter), "processSparkRewards", 0, true);
        } catch {
            emit AdapterInteraction(address(adapter), "processSparkRewards", 0, false);
        }
    }

    /**
     * @dev Get Spark-specific health factor
     */
    function _getSparkHealthFactor() internal view returns (uint256) {
        try adapter.getHealthFactor() returns (uint256 healthFactor) {
            return healthFactor;
        } catch {
            return type(uint256).max; // Default to safe if not available
        }
    }

    /*//////////////////////////////////////////////////////////////
                OPTIONAL BASE STRATEGY OVERRIDES
    //////////////////////////////////////////////////////////////*/

    function availableDepositLimit(address) public view override returns (uint256) {
        try adapter.availableDepositLimit() returns (uint256 adapterLimit) {
            return adapterLimit;
        } catch {
            return type(uint256).max;
        }
    }

    function availableWithdrawLimit(address _owner) public view override returns (uint256) {
        uint256 baseLimit = asset.balanceOf(address(this));
        
        try adapter.availableWithdrawLimit() returns (uint256 adapterWithdrawLimit) {
            return baseLimit + adapterWithdrawLimit;
        } catch {
            return baseLimit + _calculateMaxWithdrawable();
        }
    }

    function _tend(uint256 _totalIdle) internal override {
        if (!_shouldTend()) return;
        
        if (_totalIdle > _getTendThreshold()) {
            _deployFunds(_totalIdle);
        }
        
        _claimSparkRewardsIfWorthwhile();
    }

    function _tendTrigger() internal view override returns (bool) {
        if (_hasSignificantIdleFunds()) return true;
        if (_sparkRewardsAreClaimable()) return true;
        if (_sparkMarketConditionsFavorable()) return true;
        
        return false;
    }

    function _emergencyWithdraw(uint256 _amount) internal override {
        emergencyModeActivated = block.timestamp;
        emit EmergencyModeActivated(block.timestamp, "Manual emergency withdrawal");
        
        try adapter.emergencyWithdraw(_amount) {
            emit AdapterInteraction(address(adapter), "emergencyWithdraw", _amount, true);
        } catch {
            try adapter.withdrawFromSpark(_amount, address(this)) {
                emit AdapterInteraction(address(adapter), "emergencyWithdraw_fallback", _amount, true);
            } catch {
                emit AdapterInteraction(address(adapter), "emergencyWithdraw_fallback", _amount, false);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                SPARK-SPECIFIC VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _sparkRewardsAreClaimable() internal view returns (bool) {
        try adapter.sparkRewardsAvailable() returns (bool available) {
            return available;
        } catch {
            return false;
        }
    }

    function _sparkMarketConditionsFavorable() internal view returns (bool) {
        try adapter.sparkMarketConditionsFavorable() returns (bool favorable) {
            return favorable;
        } catch {
            return true;
        }
    }

    function _claimSparkRewardsIfWorthwhile() internal {
        if (_sparkRewardsAreClaimable() && _isGasEfficientToClaim()) {
            try adapter.claimSparkRewards() {
                emit AdapterInteraction(address(adapter), "claimSparkRewards", 0, true);
            } catch {
                emit AdapterInteraction(address(adapter), "claimSparkRewards", 0, false);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                SHARED INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _calculateSafeWithdrawal(uint256 requestedAmount) internal view returns (uint256) {
        try adapter.getMaxSafeWithdrawal() returns (uint256 maxSafe) {
            return requestedAmount > maxSafe ? maxSafe : requestedAmount;
        } catch {
            return requestedAmount;
        }
    }

    function _calculateMaxWithdrawable() internal view returns (uint256) {
        try adapter.maxWithdrawable() returns (uint256 maxWithdraw) {
            return maxWithdraw;
        } catch {
            return adapter.totalAssets();
        }
    }

    function _validateDeploymentRisk(uint256 _amount) internal view {
        try adapter.isHealthy() returns (bool healthy) {
            require(healthy, "Adapter reports unhealthy state");
        } catch {}
        
        require(emergencyModeActivated == 0, "Strategy in emergency mode");
        require(_amount <= ASSET.balanceOf(address(this)), "Insufficient balance for deployment");
    }

    function _postHarvestOptimization() internal {
        uint256 idleAssets = ASSET.balanceOf(address(this));
        if (idleAssets > _getAutoCompoundThreshold()) {
            _deployFunds(idleAssets);
        }
    }

    function _getEstimatedAPY() internal view returns (uint256) {
        try adapter.getEstimatedAPY() returns (uint256 apy) {
            return apy;
        } catch {
            return 0;
        }
    }

    function _getAutoCompoundThreshold() internal view returns (uint256) {
        uint256 totalAssets = adapter.totalAssets();
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