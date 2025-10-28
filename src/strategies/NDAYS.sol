// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.20;

/*//////////////////////////////////////////////////////////////
                        INTERFACES
//////////////////////////////////////////////////////////////*/
import { BaseStrategy, ERC20 } from "@tokenized-strategy/BaseStrategy.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IAavePool } from "../interfaces/aave/IAavePool.sol";
import { IRewardsController } from "../interfaces/aave/IRewardsController.sol";
import { IUniswapV4Hook } from "../interfaces/uniswap/IUniswapV4Hook.sol";

/**
 * @title NapFi ZenLend Strategy (Optimized Aave v3)
 * @notice Dynamic, risk-aware Aave v3 strategy that self-optimizes rewards
 *         and compounds yield using Uniswap v4 hooks.
 */
contract NapFiZenLendStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            IMMUTABLES
    //////////////////////////////////////////////////////////////*/
    IAavePool public immutable aavePool;
    IRewardsController public immutable rewards;
    IUniswapV4Hook public immutable swapHook;
    address public immutable aToken;

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/
    uint16 public constant REFERRAL_CODE = 0;
    uint256 public constant MAX_SLIPPAGE_BPS = 50; // 0.5%
    uint256 public constant HEALTH_FACTOR_MIN = 1.5e18;
    uint256 public constant IDLE_THRESHOLD = 1 ether;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/
    address[] public rewardTokens;
    bool public emergencyMode;
    uint256 public lastHarvest;
    uint256 public cumulativeYield;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    event Harvested(uint256 totalAssets, uint256 yieldGenerated, uint256 gasUsed);
    event EmergencyActivated(string reason);
    event RiskCheck(string parameter, bool ok);
    event RewardCompounded(address indexed token, uint256 amount, uint256 assetGained);

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(
        address _asset,
        string memory _name,
        address _aavePool,
        address _rewards,
        address _swapHook,
        address[] memory _rewardTokens
    ) BaseStrategy(_asset, _name) {
        require(_aavePool != address(0) && _rewards != address(0) && _swapHook != address(0), "Invalid addresses");

        aavePool = IAavePool(_aavePool);
        rewards = IRewardsController(_rewards);
        swapHook = IUniswapV4Hook(_swapHook);
        rewardTokens = _rewardTokens;

        // Get aToken from Aave reserve data
        (, , , , , ) = aavePool.getUserAccountData(address(this));
        // Simplified mapping logic: assume aToken address known from external config
        // In production, you’d fetch from Aave’s Data Provider

        IERC20(_asset).safeApprove(_aavePool, type(uint256).max);
        for (uint256 i; i < _rewardTokens.length; ++i) {
            IERC20(_rewardTokens[i]).safeApprove(address(_swapHook), type(uint256).max);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        CORE STRATEGY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _deployFunds(uint256 amount) internal override {
        if (amount == 0) return;
        _validateRisk();
        aavePool.supply(address(asset), amount, address(this), REFERRAL_CODE);
    }

    function _freeFunds(uint256 amount) internal override {
        if (amount == 0) return;
        uint256 available = IERC20(aToken).balanceOf(address(this));
        uint256 toWithdraw = amount > available ? available : amount;
        aavePool.withdraw(address(asset), toWithdraw, address(this));
    }

    function _harvestAndReport() internal override returns (uint256 totalAssets) {
        uint256 gasStart = gasleft();
        if (emergencyMode) return _totalAssetsView();

        // Claim and compound rewards
        uint256 compoundedValue = _claimAndCompound();

        totalAssets = _totalAssetsView();
        uint256 yieldGen = compoundedValue > 0 ? compoundedValue : 0;
        cumulativeYield += yieldGen;
        lastHarvest = block.timestamp;

        emit Harvested(totalAssets, yieldGen, gasStart - gasleft());
    }

    /*//////////////////////////////////////////////////////////////
                        RISK MANAGEMENT LAYER
    //////////////////////////////////////////////////////////////*/

    function _validateRisk() internal view {
        (, , , , , uint256 healthFactor) = aavePool.getUserAccountData(address(this));
        require(healthFactor == 0 || healthFactor >= HEALTH_FACTOR_MIN, "Health factor below threshold");

        bool poolHealthy = _isAavePoolHealthy();
        bool stable = _isAssetPriceStable();
        bool manipulated = _isMarketManipulationDetected();

        emit RiskCheck("AavePool", poolHealthy);
        emit RiskCheck("PriceStability", stable);
        emit RiskCheck("MarketManipulation", !manipulated);

        require(poolHealthy && stable && !manipulated, "Risk validation failed");
    }

    function _isAavePoolHealthy() internal pure returns (bool) {
        // Placeholder for on-chain reserve health analysis
        return true;
    }

    function _isAssetPriceStable() internal pure returns (bool) {
        // Oracle or volatility metric logic can go here
        return true;
    }

    function _isMarketManipulationDetected() internal pure returns (bool) {
        // Simple MEV detection placeholder
        return false;
    }

    /*//////////////////////////////////////////////////////////////
                        REWARD OPTIMIZATION
    //////////////////////////////////////////////////////////////*/

    function _claimAndCompound() internal returns (uint256 totalValue) {
        address ;
        assets[0] = aToken;

        // Claim all rewards from Aave
        (address[] memory tokens, uint256[] memory amounts) =
            rewards.claimAllRewardsToSelf(assets);

        for (uint256 i; i < tokens.length; ++i) {
            uint256 amt = amounts[i];
            if (amt == 0) continue;

            // Convert reward to base asset using Uniswap v4 Hook
            uint256 assetReceived = swapHook.swapRewardsToStable(tokens[i], amt, address(this), address(asset));

            if (assetReceived > 0) {
                _deployFunds(assetReceived);
                totalValue += assetReceived;
                emit RewardCompounded(tokens[i], amt, assetReceived);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        TEND / AUTOMATION LAYER
    //////////////////////////////////////////////////////////////*/

    function _tend(uint256 idle) internal override {
        if (idle > IDLE_THRESHOLD) _deployFunds(idle);
        if (_shouldClaimRewards()) _claimAndCompound();
    }

    function _tendTrigger() internal view override returns (bool) {
        return asset.balanceOf(address(this)) > IDLE_THRESHOLD || _shouldClaimRewards();
    }

    function _shouldClaimRewards() internal view returns (bool) {
        return block.timestamp > lastHarvest + 6 hours;
    }

    /*//////////////////////////////////////////////////////////////
                        EMERGENCY HANDLING
    //////////////////////////////////////////////////////////////*/

    function _emergencyWithdraw(uint256) internal override {
        emergencyMode = true;
        emit EmergencyActivated("Emergency mode activated");

        uint256 balance = IERC20(aToken).balanceOf(address(this));
        if (balance > 0) {
            aavePool.withdraw(address(asset), balance, address(this));
        }
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _totalAssetsView() internal view returns (uint256) {
        uint256 aaveBal = IERC20(aToken).balanceOf(address(this));
        uint256 idleBal = asset.balanceOf(address(this));
        return aaveBal + idleBal;
    }
}
