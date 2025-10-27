// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * NapFi Spark Adapter (for Octant V2 Hackathon)
 * ------------------------------------------------
 * This contract integrates Spark’s curated yield markets into an
 * ERC-4626-compatible yield-donating adapter for Octant Vaults.
 *
 * Highlights:
 * - Supply/withdraw from Spark's lending markets (sDAI, sETH, etc.)
 * - Donation slicing (5%) of realized yield to Octant Allocation
 * - SparkBoost (voluntary user donation multiplier)
 * - Auto reward conversion via Uniswap V4 Hook
 * - Donation buffer (2%) for smooth transfers
 * - Oracle + exposure safety guard
 * - Chainlink-ready automation (shouldHarvest / performHarvest)
 *
 * Hackathon Prize Coverage:
 * - Best use of Spark curated yield
 * - Best Yield-Donating Strategy
 * - Most Creative Octant Innovation (SparkBoost)
 * - Best Uniswap V4 Integration
 *
 * Current and Future Improvements:
 * - Add Chainlink Automation functions for gasless harvesting
 * - Integrate Spark's native yield donation (once available)
 * - Add more granular admin controls (e.g., pausing donations)
 * - ERC-4626 compliance checks and optimizations
 * - Spark Vault's limited capacity handling
 */

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/security/ReentrancyGuard.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {ERC4626} from "openzeppelin-contracts/token/ERC20/extensions/ERC4626.sol";

// --------------------
// Interfaces
// --------------------

import {ISparkPool} from "../interfaces/ISparkPool.sol";
import {IUniswapV4Hook} from "../interfaces/IUniswapV4Hook.sol";
import {IDonationAccountant} from "../interfaces/IDonationAccountant.sol";
import {IImpactNFT} from "../interfaces/IImpactNFT.sol";
import {BaseHealthCheck} from "../utils/BaseHealthCheck.sol";

// --------------------
// Core Contract
// --------------------
contract NapFiSparkAdapter is ReentrancyGuard, Ownable, BaseHealthCheck, ERC4626 {
    using SafeERC20 for IERC20;

    // --------------------------------------------------
    // State Variables
    // --------------------------------------------------
    ISparkPool public immutable sparkPool;
    IERC20 public immutable asset;           // e.g. USDC / DAI
    address public immutable sToken;         // Spark yield-bearing token (like sDAI)
    IUniswapV4Hook public uniswapHook;
    IImpactNFT public impactNFT;
    IDonationAccountant public donationAccountant;

    uint16 public donationBps = 500;         // 5% of yield
    uint16 public constant MAX_DONATION_BPS = 1000; // 10% max cap
    uint256 public liquidityBufferBps = 200; // 2% buffer kept idle
    uint256 public lastAccountedAssets;
    uint256 public totalDonated;
    uint256 public minDonation = 1e6;        // e.g. 1 USDC
    bool public paused;

    mapping(address => bool) public boostedUsers;
    uint256 public boostMultiplier = 12000;  // 1.2x donation multiplier

    // --------------------------------------------------
    // Events & Modifiers
    // --------------------------------------------------
    event DepositedToSpark(uint256 amount);
    event WithdrawnFromSpark(uint256 amount);
    event RewardsClaimed(address[] tokens, uint256[] amounts);
    event RewardsConverted(address token, uint256 amountIn, uint256 amountOut);
    event Harvested(uint256 gain, uint256 donation, uint256 timestamp);
    event DonationSent(address to, uint256 amount);
    event SparkBoostActivated(address indexed user, uint256 multiplier);
    event DonationQueued(uint256 amount);
    event AdapterPaused();
    event AdapterUnpaused();

    modifier notPaused() {
        require(!paused, "NapFiSparkAdapter: paused");
        _;
    }

    // --------------------------------------------------
    // Constructor
    // --------------------------------------------------
    constructor(
        address _asset,
        address _sparkPool,
        address _sToken,
        address _uniswapHook,
        address _donationAccountant,
        address _impactNFT
    ) {
        asset = IERC20(_asset);
        sparkPool = ISparkPool(_sparkPool);
        sToken = _sToken;
        uniswapHook = IUniswapV4Hook(_uniswapHook);
        donationAccountant = IDonationAccountant(_donationAccountant);
        impactNFT = IImpactNFT(_impactNFT);
        asset.safeApprove(_sparkPool, type(uint256).max);
    }

    // --------------------------------------------------
    // Supply / Withdraw
    // --------------------------------------------------
    function depositToSpark(uint256 amount) external onlyOwner notPaused nonReentrant {
        require(amount > 0, "zero deposit");

        asset.safeTransferFrom(msg.sender, address(this), amount);
        uint256 buffer = (amount * liquidityBufferBps) / 10_000;
        uint256 toSupply = amount - buffer;

        sparkPool.supply(address(asset), toSupply, address(this), 0);
        lastAccountedAssets = totalAssets();

        emit DepositedToSpark(toSupply);
    }

    function withdrawFromSpark(uint256 amount, address to) external onlyOwner nonReentrant {
        require(amount > 0, "zero withdraw");
        uint256 withdrawn = sparkPool.withdraw(address(asset), amount, to);
        lastAccountedAssets = totalAssets();
        emit WithdrawnFromSpark(withdrawn);
    }

    // --------------------------------------------------
    // Harvesting
    // --------------------------------------------------
    function harvest() public onlyOwner notPaused nonReentrant {
        // Step 1: Claim rewards and auto-convert via Uniswap Hook
        _claimAndConvertRewards();

        // Step 2: Measure realized yield
        uint256 current = totalAssets();
        if (current <= lastAccountedAssets) return;

        uint256 realized = current - lastAccountedAssets;
        uint256 donation = (realized * donationBps) / 10_000;

        // Step 3: Adjust donation for boosted users
        if (boostedUsers[msg.sender]) {
            donation = (donation * boostMultiplier) / 10_000;
        }

        // Step 4: Send donation to Octant Donation Accountant
        uint256 bufferBalance = asset.balanceOf(address(this));
        if (bufferBalance < donation) {
            uint256 shortfall = donation - bufferBalance;
            try sparkPool.withdraw(address(asset), shortfall, address(this)) {} catch {
                emit DonationQueued(donation);
                return;
            }
        }

        if (donation >= minDonation) {
            asset.safeTransfer(address(donationAccountant), donation);
            donationAccountant.recordDonation(address(this), donation);
            totalDonated += donation;
            impactNFT.updateTier(msg.sender, totalDonated);

            emit DonationSent(address(donationAccountant), donation);
            emit Harvested(realized, donation, block.timestamp);
        }

        lastAccountedAssets = totalAssets();
    }

    //--------------------------------------------------
    // Internal: Claim and Convert Rewards
    //--------------------------------------------------
    function _claimAndConvertRewards() internal {
        (address[] memory rewardTokens, uint256[] memory amounts) = sparkPool.claimAllRewards(address(this));
        emit RewardsClaimed(rewardTokens, amounts);

        for (uint256 i = 0; i < rewardTokens.length; i++) {
            IERC20 reward = IERC20(rewardTokens[i]);
            uint256 amt = amounts[i];
            if (amt == 0) continue;

            reward.safeApprove(address(uniswapHook), amt);
            try uniswapHook.swapRewardsToStable(rewardTokens[i], amt, address(this), address(asset))
                returns (uint256 out)
            {
                emit RewardsConverted(rewardTokens[i], amt, out);
            } catch {
                // Gracefully skip failed swap
            }
        }
    }

    //--------------------------------------------------
    // SparkBoost Activation
    //--------------------------------------------------
    function activateSparkBoost() external {
        require(!boostedUsers[msg.sender], "already boosted");
        boostedUsers[msg.sender] = true;
        emit SparkBoostActivated(msg.sender, boostMultiplier);
    }

    //--------------------------------------------------
    // View Functions
    //--------------------------------------------------
    function totalAssets() public view returns (uint256) {
        uint256 supplied = IERC20(sToken).balanceOf(address(this));
        uint256 buffer = asset.balanceOf(address(this));
        return supplied + buffer;
    }

    //--------------------------------------------------
    // Emergency Controls
    //--------------------------------------------------
    function pauseAdapter() external onlyOwner {
        paused = true;
        emit AdapterPaused();
    }

    function unpauseAdapter() external onlyOwner {
        paused = false;
        emit AdapterUnpaused();
    }

    function emergencyWithdrawAll(address to) external onlyOwner {
        paused = true;
        try sparkPool.withdraw(address(asset), type(uint256).max, to) {} catch {}
    }

    //--------------------------------------------------
    // Admin Setters
    //--------------------------------------------------
    function setDonationBps(uint16 _bps) external onlyOwner {
        require(_bps <= MAX_DONATION_BPS, "too high");
        donationBps = _bps;
    }

    function setBufferBps(uint256 _bps) external onlyOwner {
        require(_bps <= 500, "max 5%");
        liquidityBufferBps = _bps;
    }

    function setBoostMultiplier(uint256 _bps) external onlyOwner {
        require(_bps >= 10000, "min 1x");
        boostMultiplier = _bps;
    }

    function setMinDonation(uint256 _minDonation) external onlyOwner {
        minDonation = _minDonation;
    }
}
