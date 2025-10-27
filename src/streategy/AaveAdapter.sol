// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
  AaveAdapter.sol - NapFi
  This contract is the Aave-based yield strategy that routes part of yield
  to public goods (Octant) and updates a Proof-of-Impact NFT (ImpactNFT).
    Features:
  - Adapter that supplies/withdraws to Aave v3 pool
  - Tracks realized yield and slices a donation portion to Octant Allocation
  - Claims rewards, auto-converts them via Uniswap (hook integration point)
  - Safety checks: oracle sanity, max exposure, pause/unwind, donation buffer
  - Automation hook (Chainlink-compatible performUpkeep pattern)

  Key Note:
  Still a skeleton implementation; in production, ensure proper integration
  with Aave interfaces, reward tokens, Uniswap swaps, and oracles.
  Thoroughly test all edge cases, reentrancy, and security aspects before use.

  - It demonstrates:
     - ave V3 ERC-4626 semantics (deposit/withdraw via pool.supply())
     - Reward harvesting + Uniswap V4 Hook conversion
     - Donation slicing (e.g. 5%) and liquidity buffer
     - Safety checks (oracle + max exposure)
     - Chainlink-compatible automation hooks (shouldHarvest, performHarvest)

   - Prize Track Coverage:
     - Aave v3 Vaults (safe yield accounting + interfaces)
     - Uniswap V4 Hooks (reward conversion integration)
     - Octant v2 for Public Goods (yield donation mechanism)
     - Creative Impact NFT system (social proof & gamification)

  - Still not implemented:
    - Actual reward token enumeration and swap logic
    - On-chain oracle integration (Chainlink)
    - Max exposure checks against real protocol data
    - Comprehensive error handling and events
  - YearnV3 Strategy Guide https://docs.yearn.fi/developers/v3/strategy_writing_guide

  - Architecture of AaveAdapter:
        [NapFi/YearnV3 Vault]
                |
                | owns
                v
        [AaveAdapter] <--> [Aave v3 Pool]
                |                   |
                | supplies/withdraws|
                v                   v
        [Underlying Asset]    [aTokens]
                |
                | donates slice
                v
        [Octant Allocation]

   - Overall Architecture:
   
User
 │
 ▼
Octant Vault (ERC-4626)  ──(deposits shares)──►  (Octant manages vault shares)
 │
 ▼
NapFi Meta-Donation Strategy  (ERC-4626 TokenizedStrategy)
 ├─ Yearn/Kalani Adapter
 │     └─ tokenizedStrategy.harvest() → realizeGain() → report()
 ├─ Aave Adapter  <──────────── INTERNALS + INNOVATIONS 
 │     ├─ depositToAave(amount) -> pool.supply(asset, amount, address(this), 0)
 │     ├─ withdrawFromAave(amount) -> pool.withdraw(asset, amount, to)
 │     │
 │     ├─ claimRewards() -> RewardHandler.claim()
 │     │     ├─ RewardHandler:
 │     │     │     ├─ swapRewardsToStable() via Uniswap V4 Hook
 │     │     │     ├─ route 5% to DonationAccountant
 │     │     │     └─ stakeRemaining() for compounding
 │     │
 │     ├─ accounting:
 │     │     ├─ lastAccountedAssets
 │     │     ├─ totalAssets() reads aToken balance + converted rewards
 │     │     ├─ realizedYield = max(0, currentAssets - lastAccountedAssets)
 │     │     ├─ donationSlice = realizedYield * donationRate
 │     │     ├─ donationBuffer = liquidityReserve (2–3%) for instant donation payouts
 │     │     └─ dynamicAPY = weighted(AaveInterest + RewardYield)
 │     │
 │     ├─ innovations:
 │     │     ├─  Donation-Sliced Yield Stream (DST):
 │     │     │     Real-time slicing of Aave interest into DonationAccountant.
 │     │     ├─  Dynamic Risk Scoring Engine:
 │     │     │     Adjusts exposure limits using on-chain oracle + volatility data.
 │     │     ├─  Reserve Buffer System:
 │     │     │     Keeps small liquidity pool to smooth donation transfers.
 │     │     ├─  Reward Auto-Conversion Hook:
 │     │     │     Uses Uniswap V4 Hooks to convert stkAAVE / GHO → USDC for donation.
 │     │     ├─  Chainlink Automation Triggers:
 │     │     │     Auto-call harvest() when aToken yield > threshold.
 │     │     ├─  Liquidation Safety Watchdog:
 │     │     │     Monitors healthFactor() and pauses deposits if market risk rises.
 │     │     └─  Impact Reporting Feed:
 │     │           Publishes donation metrics to Octant + off-chain dashboards.
 │     │
 │     ├─ safety:
 │     │     ├─ oracleSanityCheck() — price validity & deviation limit
 │     │     ├─ maxExposureCheck() — asset concentration limiter
 │     │     ├─ pause/unwind() — emergency withdraw & fund recovery
 │     │     ├─ minDonationThreshold() — avoids dust transactions
 │     │     └─ ReentrancyGuard + SafeERC20 wrappers
 │     │
 │     └─ emits:
 │           AaveHarvested(gain, donationAmount, riskScore, timestamp)
 │           AaveRiskUpdated(asset, exposure, volatility, timestamp)
 │
 ├─ Spark Adapter
 ├─ Morpho Adapter
 └─ Donation Accountant
        ├─ computeDonation(realizedYield)  // e.g. 5%
        ├─ call OctantAllocation.transfer(donationAmount)
        ├─ update totalDonated[user]
        └─ emit YieldDonated(user, donationAmount, timestamp)
        │
        ▼
Proof-of-Impact NFT (ImpactNFT)
        ├─ updateTier(user, totalDonated[user])
        └─ emit TierUpgraded(user, newTier)
        │
        ▼
User Wallet + Dashboard
        ├─ show: totalEarned | totalDonated | NFT tier | leaderboard
        └─ optional: donation-rate slider (1-10%), revoke/withdraw option

*/

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/security/ReentrancyGuard.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {ERC4626} from "openzeppelin-contracts/token/ERC20/extensions/ERC4626.sol";

// --------------------------------------------------
// External Interfaces
// --------------------------------------------------
import {IRewardsController} from "../interfaces/IRewardsController.sol";
import {IUniswapV4Hook} from "../interfaces/IUniswapV4Hook.sol";
import {IImpactNFT} from "../interfaces/IImpactNFT.sol";
import {BaseHealthCheck} from "../utils/BaseHealthCheck.sol";
import {IAavePool} from "../interfaces/IAavePool.sol";

// --------------------------------------------------
// AaveAdapter - Core Contract
// --------------------------------------------------
contract AaveAdapter is ERC4626, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // -------------------------
    // Protocol dependencies
    // -------------------------
    IAavePool public immutable aavePool;           // Aave v3 Pool
    IRewardsController public immutable rewardsController; // Rewards manager (Aave emissions)
    IUniswapV4Hook public uniswapHook;             // External Uniswap hook for conversions

    // -------------------------
    // Token configuration
    // -------------------------
    IERC20 public immutable asset;                 // Underlying asset (e.g. USDC)
    IERC20 public immutable aToken;                // Aave's interest-bearing token
    address public immutable rewardTargetStable;   // Token we want to hold rewards in (same as asset)

    // -------------------------
    // Donation configuration
    // -------------------------
    address public octantAllocation;               // Public goods allocation address (Octant)
    IImpactNFT public impactNFT;                   // Proof-of-Impact NFT contract

    uint16 public donationBps = 500;               // 5% donation slice (basis points)
    uint16 public constant MAX_DONATION_BPS = 1000; // Cap at 10%
    uint256 public liquidityBufferBps = 200;       // 2% kept liquid in adapter for instant donations
    uint256 public lastAccountedAssets;            // Tracks last measured totalAssets()
    uint256 public totalDonated;                   // Cumulative total donated
    uint256 public minDonation = 1e6;              // Minimum donation threshold (1 USDC)

    // -------------------------
    // Safety Parameters
    // -------------------------
    bool public paused;                            // Pause switch (for emergencies)
    uint256 public maxExposureBps = 10000;         // Limit exposure (% of total protocol)

    // -------------------------
    // Events
    // -------------------------
    event DepositedToAave(address indexed from, uint256 amount);
    event WithdrawnFromAave(address indexed to, uint256 amount);
    event RewardsClaimed(address[] rewardTokens, uint256[] claimedAmounts);
    event RewardsConverted(address rewardToken, uint256 amountIn, uint256 amountOut);
    event HarvestExecuted(uint256 realized, uint256 donation, uint256 timestamp);
    event DonationSent(address to, uint256 amount);
    event DonationQueued(uint256 amount);
    event DonationBpsUpdated(uint16 oldBps, uint16 newBps);
    event AdapterPaused();
    event AdapterUnpaused();

    modifier notPaused() {
        require(!paused, "AaveAdapter: paused");
        _;
    }

    // --------------------------------------------------
    // Constructor
    // --------------------------------------------------
    /*
    The role assignments follow Octant v2's standardized pattern for operational security:
        - Management is the primary administrator who can change other roles, intervene when safety bounds are hit, and redirect reward destinations
        - Keeper calls the report() function to harvest and distribute accumulated rewards—this role can be automated and/or outsourced to 3rd-party services like Gelato
        - Emergency Administrator can shut down the strategy and perform emergency withdrawals—perfect for delegation to 24/7 monitoring services
        - Donation Address receives newly minted shares, which can be redeemed for the underlying USDC rewards
        - Enable Burning is a boolean used in the event the strategy has a loss, based on its value the recovery mechanism will burn some of the donation address shares in order to compensate for the loss
    */
    constructor(
        address _asset, // Octant docs
        string memory _name, // Octant docs (update because unused here)
        address _rewardsController, // Aave RewardsController
        address _bot, // keepers bot (update because unused here)
        address _emergencyAdmin, // emergency admin (update because unused here)
        address _octantAllocation, // Octant allocation address
        address _aavePool, // Aave v3 Pool address // tokenizedStrategy address
        address _aToken,
        address _uniswapHook,
        address _impactNFT
    ) BaseHealthCheck(/* parameters */){
        // Assign external dependencies
        aavePool = IAavePool(_aavePool);
        rewardsController = IRewardsController(_rewardsController);
        asset = IERC20(_asset);
        aToken = IERC20(_aToken);
        uniswapHook = IUniswapV4Hook(_uniswapHook);
        rewardTargetStable = _asset;
        octantAllocation = _octantAllocation;
        impactNFT = IImpactNFT(_impactNFT);
    }

    // --------------------------------------------------
    // Deposit / Withdraw
    // --------------------------------------------------

    /// @notice Deposit underlying asset into Aave
    /// Splits deposit into:
    ///   - buffer: kept liquid in this contract for donation payouts
    ///   - toSupply: actually supplied to Aave to earn yield
    function depositToAave(uint256 amount) external onlyOwner notPaused nonReentrant {
        require(amount > 0, "AaveAdapter: zero deposit");

        // Pull funds from caller (e.g. NapFi Vault)
        asset.safeTransferFrom(msg.sender, address(this), amount);

        // Compute buffer & supply split
        uint256 buffer = (amount * liquidityBufferBps) / 10000;
        uint256 toSupply = amount - buffer;

        // Supply portion into Aave
        if (toSupply > 0) {
            asset.safeIncreaseAllowance(address(aavePool), toSupply);
            aavePool.supply(address(asset), toSupply, address(this), 0);
        }

        // Update accounting snapshot
        lastAccountedAssets = totalAssets();
        emit DepositedToAave(msg.sender, amount);
    }

    /// @notice Withdraw a given amount of underlying from Aave
    /// Only callable by strategy owner (NapFiVault)
    function withdrawFromAave(uint256 amount, address to) external onlyOwner nonReentrant {
        require(amount > 0, "AaveAdapter: zero withdraw");
        uint256 withdrawn = aavePool.withdraw(address(asset), amount, to);
        lastAccountedAssets = totalAssets();
        emit WithdrawnFromAave(to, withdrawn);
    }

    // --------------------------------------------------
    // Harvest Logic (core yield → donation)
    // --------------------------------------------------

    /// @notice Core harvest routine:
    ///   1. Claim & convert Aave rewards to USDC
    ///   2. Measure new totalAssets() vs last snapshot
    ///   3. Compute yield & slice a portion for donation
    ///   4. Send donation to Octant and update NFT tier
    function harvest() external onlyOwner notPaused nonReentrant {
        // Step 1: claim Aave rewards and convert via Uniswap Hook
        _claimAndConvertRewards();

        // Step 2: compute realized yield (Δ totalAssets)
        uint256 currentAssets = totalAssets();
        uint256 realized = currentAssets > lastAccountedAssets ? currentAssets - lastAccountedAssets : 0;

        // If no profit, exit early
        if (realized == 0) {
            lastAccountedAssets = currentAssets;
            return;
        }

        // Step 3: compute donation amount (e.g. 5%)
        uint256 donation = (realized * donationBps) / 10000;
        uint256 bufferBalance = asset.balanceOf(address(this));

        // Step 4: ensure buffer has enough liquidity to donate immediately
        if (bufferBalance < donation) {
            uint256 needed = donation - bufferBalance;
            try aavePool.withdraw(address(asset), needed, address(this)) {
                // Try pulling small amount from Aave
            } catch {
                // If failed, queue for later
                emit DonationQueued(donation - bufferBalance);
            }
        }

        // Step 5: execute donation if buffer now sufficient
        bufferBalance = asset.balanceOf(address(this));
        if (donation >= minDonation && bufferBalance >= donation) {
            // Send donation to Octant allocation contract
            asset.safeTransfer(octantAllocation, donation);
            totalDonated += donation;
            emit DonationSent(octantAllocation, donation);

            // Notify ImpactNFT (tier upgrades / gamification)
            try impactNFT.updateTier(msg.sender, totalDonated) {} catch {}
        } else {
            emit DonationQueued(donation);
        }

        // Step 6: finalize accounting snapshot
        lastAccountedAssets = totalAssets();
        emit HarvestExecuted(realized, donation, block.timestamp);
    }

    // --------------------------------------------------
    // Rewards Claiming & Conversion
    // --------------------------------------------------

    /// @dev Internal helper that:
    ///   - Calls Aave RewardsController to claim all reward tokens
    ///   - For each reward token → swaps into stable via Uniswap Hook
    function _claimAndConvertRewards() internal {
        address ;
        assets[0] = address(aToken); // claim rewards based on aToken activity

        // Claim rewards from Aave
        (address[] memory rewardTokens, uint256[] memory claimedAmounts) =
            rewardsController.claimAllRewardsToSelf(assets);
        emit RewardsClaimed(rewardTokens, claimedAmounts);

        // Iterate through all claimed tokens and swap to USDC
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address rToken = rewardTokens[i];
            uint256 claimed = claimedAmounts[i];
            if (claimed == 0) continue;

            // Approve Uniswap hook for conversion
            IERC20(rToken).safeIncreaseAllowance(address(uniswapHook), claimed);

            // Attempt swap; non-blocking in case of hook failure
            try uniswapHook.swapRewardsToStable(rToken, claimed, address(this), rewardTargetStable)
                returns (uint256 received)
            {
                emit RewardsConverted(rToken, claimed, received);
            } catch {
                // skip if swap fails — yield unaffected
            }
        }
    }

    // --------------------------------------------------
    // Accounting & Safety Utilities
    // --------------------------------------------------

    /// @notice Return current total asset exposure (buffer + aToken)
    function totalAssets() public view returns (uint256) {
        uint256 buffer = asset.balanceOf(address(this));      // on-contract liquidity
        uint256 supplied = aToken.balanceOf(address(this));   // Aave-supplied tokens (1:1)
        return buffer + supplied;
    }

    /// @notice Oracle sanity check placeholder (for Chainlink price validation)
    function oracleSanityCheck(uint256 priceAsset, uint256 priceRef) public pure returns (bool) {
        uint256 diff = priceAsset > priceRef ? priceAsset - priceRef : priceRef - priceAsset;
        uint256 tolerance = (priceRef * 1000) / 10000; // allow 10% deviation
        return diff <= tolerance;
    }

    /// @notice Limit concentration risk: ensures we don’t exceed max exposure
    function maxExposureCheck(uint256 protocolTotal) public view returns (bool) {
        uint256 myExposure = totalAssets();
        return myExposure <= ((protocolTotal * maxExposureBps) / 10000);
    }

    // --------------------------------------------------
    // Chainlink / Automation Hooks
    // --------------------------------------------------

    /// @notice Returns true if gain ≥ minDeltaBps threshold since last snapshot
    /// Used by off-chain keepers (Chainlink Automation)
    function shouldHarvest(uint256 minDeltaBps) external view returns (bool) {
        uint256 current = totalAssets();
        if (current <= lastAccountedAssets) return false;
        uint256 delta = current - lastAccountedAssets;
        uint256 threshold = (lastAccountedAssets * minDeltaBps) / 10000;
        return delta >= threshold;
    }

    /// @notice External trigger to perform harvest
    function performHarvest() external notPaused nonReentrant {
        harvest();
    }

    // --------------------------------------------------
    // Admin Configuration
    // --------------------------------------------------

    /// @notice Adjust donation percentage
    function setDonationBps(uint16 _bps) external onlyOwner {
        require(_bps <= MAX_DONATION_BPS, "too high");
        emit DonationBpsUpdated(donationBps, _bps);
        donationBps = _bps;
    }

    /// @notice Adjust liquidity buffer percentage
    function setLiquidityBufferBps(uint256 _bps) external onlyOwner {
        liquidityBufferBps = _bps;
    }

    /// @notice Adjust minimum donation threshold
    function setMinDonation(uint256 _minDonation) external onlyOwner {
        minDonation = _minDonation;
    }

    /// @notice Update Octant allocation address
    function setOctantAllocation(address _octant) external onlyOwner {
        octantAllocation = _octant;
    }

    /// @notice Update NFT contract (in case of upgrades)
    function setImpactNFT(address _nft) external onlyOwner {
        impactNFT = IImpactNFT(_nft);
    }

    /// @notice Pause adapter (emergency shutdown)
    function pauseAdapter() external onlyOwner {
        paused = true;
        emit AdapterPaused();
    }

    /// @notice Resume adapter operations
    function unpauseAdapter() external onlyOwner {
        paused = false;
        emit AdapterUnpaused();
    }

    /// @notice Emergency withdraw everything to owner
    /// Leaves contract paused until manual recovery
    function emergencyWithdrawAll(address to) external onlyOwner {
        paused = true;
        try aavePool.withdraw(address(asset), type(uint256).max, to) {
            // success
        } catch {
            // stay paused if fails
        }
    }
}
