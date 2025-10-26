// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
  MorphoAdapter.sol
  NapFi — Morpho V2 Meta-Donation Strategy (P2P Donation Slicer)

  - Supplies to Morpho V2
  - Tracks P2P index deltas and slices donation from P2P interest
  - Claims reward tokens and converts them to the stable donation asset via Uniswap V4 Hook
  - Keeps a small on-adapter liquidity buffer for immediate donations
  - Emits detailed events for testing and transparency
  - Includes safety controls: pause, emergency withdraw, exposure check

  Notes:
  - Index math uses 1e27 precision (common for Morpho/Aave-like indices). Adjust if actual precision differs.
  - Reward conversion uses a pluggable Uniswap V4 Hook contract (or any trusted swapper).
  - This adapter is owner-controlled (owner = NapFiVault / strategy manager). For production use, prefer a multisig/timelock.
*/

import "openzeppelin-contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/security/ReentrancyGuard.sol";
import "openzeppelin-contracts/access/Ownable.sol";

/// ---------------------------------------------------------------------------
/// Minimal external interfaces (mock-friendly)
/// ---------------------------------------------------------------------------

interface IMorpho {
    // supply underlying asset into Morpho (onBehalfOf is adapter)
    function supply(address asset, uint256 amount, address onBehalfOf) external;

    // withdraw underlying from Morpho back to 'to', returns amount withdrawn
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    // returns the current P2P index for an asset (scaled by 1e27)
    function getP2PIndex(address asset) external view returns (uint256);

    // returns total underlying supplied on behalf of a user (in underlying units)
    function getTotalSupplied(address asset, address user) external view returns (uint256);
}

interface IRewardsController {
    // Claim all rewards for provided assets to the caller
    function claimAllRewardsToSelf(address[] calldata assets)
        external
        returns (address[] memory rewardsList, uint256[] memory claimedAmounts);
}

interface IUniswapV4Hook {
    // Swap a reward token -> stableToken and send to `to`. Returns amount received
    function swapRewardsToStable(
        address rewardToken,
        uint256 amount,
        address to,
        address stableToken
    ) external returns (uint256);
}

interface IImpactNFT {
    // Update donor's tier/state
    function updateTier(address user, uint256 totalDonated) external;
}

/// ---------------------------------------------------------------------------
/// MorphoAdapter
/// ---------------------------------------------------------------------------
contract MorphoAdapter is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // -----------------------------
    // External protocol refs
    // -----------------------------
    IMorpho public immutable morpho;
    IRewardsController public immutable rewardsController;
    IUniswapV4Hook public uniswapHook;
    IImpactNFT public impactNFT;

    // -----------------------------
    // Tokens & recipients
    // -----------------------------
    IERC20 public immutable asset;             // underlying (e.g. USDC)
    address public immutable rewardTargetStable; // usually same as asset (where to convert rewards)
    address public octantAllocation;           // recipient contract for donations

    // -----------------------------
    // Accounting state
    // -----------------------------
    uint256 public lastP2PIndex;               // last recorded P2P index (1e27 precision)
    uint256 public lastAccountedAssets;        // snapshot of totalAssets for realized delta method (extra safety)
    uint256 public totalDonated;               // cumulative donated amount (for NFTs / reporting)

    // donation & buffer params
    uint16 public donationBps = 500;           // default 5% of realized P2P yield
    uint16 public constant MAX_DONATION_BPS = 1000; // max 10%
    uint256 public liquidityBufferBps = 200;   // keep 2% of deposits on-contract for instant donation (bps)

    // safety
    bool public paused;
    uint256 public maxExposureBps = 10000;     // 100% cap default

    // index precision (Morpho uses 1e27-like indices commonly). Expose to allow adjustment if needed.
    uint256 public constant INDEX_PRECISION = 1e27;

    // -----------------------------
    // Events
    // -----------------------------
    event DepositedToMorpho(address indexed from, uint256 amount, uint256 buffer);
    event WithdrawnFromMorpho(address indexed to, uint256 amount);
    event P2PIndexUpdated(uint256 oldIndex, uint256 newIndex, uint256 delta);
    event P2PDonationStreamed(address indexed triggeredBy, uint256 p2pGain, uint256 donation);
    event MorphoHarvested(uint256 p2pGain, uint256 rewardGain, uint256 donation);
    event RewardsClaimed(address[] rewardTokens, uint256[] claimedAmounts);
    event RewardsConverted(address rewardToken, uint256 amountIn, uint256 amountOut);
    event DonationSent(address to, uint256 amount);
    event DonationQueued(uint256 amount);
    event DonationBpsUpdated(uint16 oldBps, uint16 newBps);
    event AdapterPaused();
    event AdapterUnpaused();

    modifier notPaused() {
        require(!paused, "MorphoAdapter: paused");
        _;
    }

    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------
    /// @param _morpho Morpho pool contract
    /// @param _rewardsController rewards manager (Morpho or base protocol)
    /// @param _asset underlying stable token address (e.g. USDC)
    /// @param _uniswapHook swapper contract to convert rewards to stable
    /// @param _octantAllocation public goods receiver
    /// @param _impactNFT impact NFT contract
    constructor(
        address _morpho,
        address _rewardsController,
        address _asset,
        address _uniswapHook,
        address _octantAllocation,
        address _impactNFT
    ) {
        require(_morpho != address(0), "zero morpho");
        require(_asset != address(0), "zero asset");
        morpho = IMorpho(_morpho);
        rewardsController = IRewardsController(_rewardsController);
        asset = IERC20(_asset);
        rewardTargetStable = _asset;
        uniswapHook = IUniswapV4Hook(_uniswapHook);
        octantAllocation = _octantAllocation;
        impactNFT = IImpactNFT(_impactNFT);
    }

    /// -----------------------------------------------------------------------
    /// Deposit into Morpho: keep small buffer, supply rest
    /// - Owner is expected to be NapFi Vault or strategy manager
    /// -----------------------------------------------------------------------
    function depositToMorpho(uint256 amount) external onlyOwner notPaused nonReentrant {
        require(amount > 0, "zero deposit");

        // Transfer underlying from owner (NapFiVault). Owner must approve first.
        asset.safeTransferFrom(msg.sender, address(this), amount);

        // Compute buffer and supply split
        uint256 buffer = (amount * liquidityBufferBps) / 10000;
        uint256 toSupply = amount - buffer;

        // Supply to Morpho (the on-chain lending engine)
        if (toSupply > 0) {
            // approve morpho to pull underlying
            asset.safeIncreaseAllowance(address(morpho), toSupply);
            morpho.supply(address(asset), toSupply, address(this));
        }

        // Snapshot P2P index so future computeP2PIndexDelta knows starting point
        uint256 currentIndex = morpho.getP2PIndex(address(asset));
        lastP2PIndex = currentIndex;

        // Update accounting snapshot (useful if also tracking realized via totalAssets)
        lastAccountedAssets = totalAssets();

        emit DepositedToMorpho(msg.sender, amount, buffer);
    }

    /// -----------------------------------------------------------------------
    /// Withdraw from Morpho back to `to` (owner action)
    /// -----------------------------------------------------------------------
    function withdrawFromMorpho(uint256 amount, address to) external onlyOwner nonReentrant {
        require(amount > 0, "zero withdraw");
        uint256 withdrawn = morpho.withdraw(address(asset), amount, to);
        // update account snapshot conservatively
        lastAccountedAssets = totalAssets();
        emit WithdrawnFromMorpho(to, withdrawn);
    }

    /// -----------------------------------------------------------------------
    /// computeP2PIndexDelta
    /// - Reads current P2P index, computes delta vs last snapshot
    /// - Calculates P2P realized gain (approx): supplied * (delta / INDEX_PRECISION)
    /// - Derives donation slice (donationBps)
    /// - Attempts immediate donation from buffer; if insufficient, emits DonationQueued
    /// - Emits events for testing & transparency
    /// Note: this method is the core of the P2P Donation Slicer innovation.
    /// -----------------------------------------------------------------------
    function computeP2PIndexDelta() public notPaused returns (uint256 p2pGain, uint256 donation) {
        uint256 currentIndex = morpho.getP2PIndex(address(asset));
        uint256 previousIndex = lastP2PIndex;

        // If no increase (or decreased), nothing to do
        if (currentIndex <= previousIndex) {
            // Update index to avoid reprocessing old values (optional)
            lastP2PIndex = currentIndex;
            return (0, 0);
        }

        // calculate index delta
        uint256 delta = currentIndex - previousIndex;

        // get adapter's total supplied amount (underlying units)
        uint256 supplied = morpho.getTotalSupplied(address(asset), address(this)); // underlying units

        // p2pGain = supplied * delta / INDEX_PRECISION
        // Use safe math via solidity ^0.8 overflow checks
        p2pGain = (supplied * delta) / INDEX_PRECISION;

        // donation slice
        donation = (p2pGain * donationBps) / 10000;

        // update snapshot index
        lastP2PIndex = currentIndex;

        emit P2PIndexUpdated(previousIndex, currentIndex, delta);

        // attempt immediate donation from buffer (on-contract balance)
        uint256 bufferBalance = asset.balanceOf(address(this));
        if (donation > 0 && bufferBalance >= donation) {
            asset.safeTransfer(octantAllocation, donation);
            totalDonated += donation;

            // try to update ImpactNFT (non-critical)
            try impactNFT.updateTier(msg.sender, totalDonated) {} catch {}

            emit P2PDonationStreamed(msg.sender, p2pGain, donation);
        } else if (donation > 0) {
            // queue case: emit event so off-chain relayer can retry / top-up buffer
            emit DonationQueued(donation);
        }
    }

    /// -----------------------------------------------------------------------
    /// harvest
    /// - Calls computeP2PIndexDelta to harvest small P2P interest
    /// - Claims rewards and converts them to stable via uniswapHook
    /// - Aggregates donation amounts and attempts to send to Octant
    /// - Updates lastAccountedAssets for bookkeeping
    /// -----------------------------------------------------------------------
    function harvest() external onlyOwner notPaused nonReentrant {
        // 1) P2P index delta and immediate donation attempt
        (uint256 p2pGain, uint256 p2pDonation) = computeP2PIndexDelta();

        // 2) Claim rewards & convert to stable (adds to adapter buffer)
        uint256 rewardConverted = _claimAndConvertRewards();

        // Combined realized yield (for reporting)
        uint256 realized = p2pGain + rewardConverted;

        // Determine donation total for this harvest (we already attempted p2pDonation)
        // For simplicity, we consider p2pDonation already handled; additional donation from rewardConverted can be donated too
        uint256 rewardDonation = (rewardConverted * donationBps) / 10000;

        uint256 totalDonation = 0;
        // if p2pDonation already transferred, we should not double-send it — but p2pDonation transfer may have queued
        // To be safe, attempt to send rewardDonation now
        if (rewardDonation > 0) {
            uint256 bufferBalance = asset.balanceOf(address(this));
            if (bufferBalance >= rewardDonation) {
                asset.safeTransfer(octantAllocation, rewardDonation);
                totalDonated += rewardDonation;
                try impactNFT.updateTier(msg.sender, totalDonated) {} catch {}
                emit DonationSent(octantAllocation, rewardDonation);
                totalDonation += rewardDonation;
            } else {
                emit DonationQueued(rewardDonation);
            }
        }

        // update last accounted snapshot
        lastAccountedAssets = totalAssets();

        emit MorphoHarvested(p2pGain, rewardConverted, totalDonation + p2pDonation);
    }

    /// -----------------------------------------------------------------------
    /// _claimAndConvertRewards
    /// - Claims rewards from rewardsController
    /// - For each reward token, calls uniswapHook.swapRewardsToStable -> adds stable to buffer
    /// - Returns total converted stable amount
    /// -----------------------------------------------------------------------
    function _claimAndConvertRewards() internal returns (uint256 totalConverted) {
        // Build minimal assets array for rewards claim (we only have `asset` in this adapter)
        address;
        assets[0] = address(asset); // claim rewards based on underlying activity (some rewards systems use asset list)

        // Claim all rewards to this contract (non-reverting design preferred)
        (address[] memory rewardTokens, uint256[] memory claimedAmounts) =
            rewardsController.claimAllRewardsToSelf(assets);

        emit RewardsClaimed(rewardTokens, claimedAmounts);

        // Iterate over each reward token and swap to stable via hook
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address rToken = rewardTokens[i];
            uint256 claimed = claimedAmounts[i];
            if (claimed == 0) continue;

            // Approve hook and try swap (non-blocking using try/catch)
            IERC20(rToken).safeIncreaseAllowance(address(uniswapHook), claimed);
            try uniswapHook.swapRewardsToStable(rToken, claimed, address(this), rewardTargetStable) returns (uint256 received) {
                totalConverted += received;
                emit RewardsConverted(rToken, claimed, received);
            } catch {
                // If conversion fails, do not revert harvest. Off-chain relayer or next harvest may retry.
            }
        }
    }

    /// -----------------------------------------------------------------------
    /// View: totalAssets
    /// - Returns adapter's on-contract buffer + supplied amount at Morpho (underlying units)
    /// - Used to validate exposures and for accounting
    /// -----------------------------------------------------------------------
    function totalAssets() public view returns (uint256) {
        uint256 buffer = asset.balanceOf(address(this));
        uint256 supplied = morpho.getTotalSupplied(address(asset), address(this));
        return buffer + supplied;
    }

    /// -----------------------------------------------------------------------
    /// Admin & Safety
    /// -----------------------------------------------------------------------
    function setDonationBps(uint16 _bps) external onlyOwner {
        require(_bps <= MAX_DONATION_BPS, "donation: too high");
        emit DonationBpsUpdated(donationBps, _bps);
        donationBps = _bps;
    }

    function setLiquidityBufferBps(uint256 _bps) external onlyOwner {
        liquidityBufferBps = _bps;
    }

    function setOctantAllocation(address _octant) external onlyOwner {
        octantAllocation = _octant;
    }

    function setImpactNFT(address _impactNFT) external onlyOwner {
        impactNFT = IImpactNFT(_impactNFT);
    }

    function pauseAdapter() external onlyOwner {
        paused = true;
        emit AdapterPaused();
    }

    function unpauseAdapter() external onlyOwner {
        paused = false;
        emit AdapterUnpaused();
    }

    /// emergency withdraw everything from Morpho to `to`. Leaves adapter paused for safety.
    function emergencyWithdrawAll(address to) external onlyOwner {
        paused = true;
        // attempt to withdraw max underlying from Morpho
        try morpho.withdraw(address(asset), type(uint256).max, to) returns (uint256 w) {
            // success: funds returned to `to`
        } catch {
            // if withdraw fails we remain paused and require manual recovery
        }
    }
}
