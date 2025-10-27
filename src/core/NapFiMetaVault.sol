// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * NapFiMetaVault.sol
 * -------------------------------------
 * A lightweight multi-strategy vault router
 * for Octant V2 Hackathon demonstration.
 *
 * Features:
 * - Deposits route capital into multiple adapters (Spark + Aave)
 * - Calls harvest on all strategies
 * - Withdraws proportionally
 * - Tracks total assets & total yield donated
 *
 * This contract acts as a "Vault Router" that combines
 * multiple tokenized strategies into one unified interface.
 */

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/security/ReentrancyGuard.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

import "../adapters/AaveAdapter.sol";
import "../adapters/SparkAdapter.sol";
import "../adapters/MorphoAdapter.sol";

contract NapFiMetaVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset; // e.g., USDC or DAI
    NapFiAaveAdapter public aaveAdapter;
    NapFiSparkAdapter public sparkAdapter;
    NapFiMorphoAdapter public morphoAdapter;

    uint256 public aaveWeightBps = 4000; // 60% Aave
    uint256 public sparkWeightBps = 3000; // 40% Spark
    uint256 public morphoWeightBps = 3000; // 30% Morpho

    event Deposited(uint256 totalAmount, uint256 aavePortion, uint256 sparkPortion, uint256 morphoPortion);
    event HarvestedAll(uint256 timestamp);
    event Withdrawn(uint256 amount);
    event WeightsUpdated(uint256 newAaveWeight, uint256 newSparkWeight, uint256 newMorphoWeight);

    constructor(
        address _asset,
        address _aaveAdapter,
        address _sparkAdapter,
        address _morphoAdapter
    ) {
        asset = IERC20(_asset);
        aaveAdapter = NapFiAaveAdapter(_aaveAdapter);
        sparkAdapter = NapFiSparkAdapter(_sparkAdapter);
        morphoAdapter = NapFiMorphoAdapter(_morphoAdapter);
    }

    //--------------------------------------------------
    // External Functions
    //--------------------------------------------------

    /// @notice Deposit funds into both adapters according to allocation weights
    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "zero deposit");
        asset.safeTransferFrom(msg.sender, address(this), amount);

        uint256 aavePortion = (amount * aaveWeightBps) / 10_000;
        uint256 sparkPortion = amount - aavePortion;

        // Route deposits
        asset.safeIncreaseAllowance(address(aaveAdapter), aavePortion);
        aaveAdapter.depositToAave(aavePortion);

        asset.safeIncreaseAllowance(address(sparkAdapter), sparkPortion);
        sparkAdapter.depositToSpark(sparkPortion);

        asset.safeIncreaseAllowance(address(morphoAdapter), morphoPortion);
        morphoAdapter.depositToMorpho(morphoPortion);

        emit Deposited(amount, aavePortion, sparkPortion, morphoPortion);
    }

    /// @notice Harvest yields from both strategies
    function harvestAll() external nonReentrant onlyOwner {
        aaveAdapter.harvest();
        sparkAdapter.harvest();
        morphoAdapter.harvest();
        emit HarvestedAll(block.timestamp);
    }

    /// @notice Withdraw funds proportionally from both adapters
    function withdraw(uint256 amount, address to) external nonReentrant onlyOwner {
        uint256 total = totalAssets();
        require(total > 0, "no assets");

        uint256 aaveShare = (amount * aaveAdapter.totalAssets()) / total;
        uint256 sparkShare = (amount * sparkAdapter.totalAssets()) / total;
        uint256 morphoShare = (amount * morphoAdapter.totalAssets()) / total;

        aaveAdapter.withdrawFromAave(aaveShare, to);
        sparkAdapter.withdrawFromSpark(sparkShare, to);
        morphoAdapter.withdrawFromMorpho(morphoShare, to);

        emit Withdrawn(amount);
    }

    /// @notice View combined total assets across both adapters
    function totalAssets() public view returns (uint256) {
        return aaveAdapter.totalAssets() + sparkAdapter.totalAssets(); + morphoAdapter.totalAssets();
    }

    ///----------------------------------------------
    // Owner Functions
    //----------------------------------------------

    function setWeights(uint256 _aaveBps, uint256 _sparkBps) external onlyOwner {
        require(_aaveBps + _sparkBps == 10_000, "must equal 100%");
        aaveWeightBps = _aaveBps;
        sparkWeightBps = _sparkBps;
        morphoWeightBps = 10_000 - _aaveBps - _sparkBps;
        emit WeightsUpdated(_aaveBps, _sparkBps, morphoWeightBps);
    }

    function emergencyWithdrawAll(address to) external onlyOwner {
        aaveAdapter.emergencyWithdrawAll(to);
        sparkAdapter.emergencyWithdrawAll(to);
        morphoAdapter.emergencyWithdrawAll(to);
    }
}
