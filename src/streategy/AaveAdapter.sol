// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
  AaveAdapter.sol - NapFi
  - Adapter that supplies/withdraws to Aave v3 pool
  - Tracks realized yield and slices a donation portion to Octant Allocation
  - Claims rewards, auto-converts them via Uniswap (hook integration point)
  - Safety checks: oracle sanity, max exposure, pause/unwind, donation buffer
  - Automation hook (Chainlink-compatible performUpkeep pattern)

  Key Note:
  Still a skeleton implementation; in production, ensure proper integration
  with Aave interfaces, reward tokens, Uniswap swaps, and oracles.
  Thoroughly test all edge cases, reentrancy, and security aspects before use.

  - Still not implemented:
    - Actual reward token enumeration and swap logic
    - On-chain oracle integration (Chainlink)
    - Max exposure checks against real protocol data
    - Comprehensive error handling and events
  - YearnV3 Strategy Guide https://docs.yearn.fi/developers/v3/strategy_writing_guide
*/

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/security/ReentrancyGuard.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";

interface IAavePool {
    // minimal methods we call
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getReserveNormalizedIncome(address asset) external view returns (uint256);
    function getUserAccountData(address user) external view returns (
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 availableBorrowsBase,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
    );
}

interface IRewardController {
    // minimal example; actual Aave rewards interface may differ
    function claimRewards(address[] calldata assets, uint256 amount, address to) external returns (uint256);
}

interface IUniswapV4Hook {
    // integration point for reward -> stable swaps
    function swapRewardsToStable(address rewardToken, uint256 amount, address to) external returns (uint256);
}

interface IImpactNFT {
    function updateTier(address user, uint256 totalDonated) external;
}

contract AaveAdapter is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // --- Configurable parameters ---
    IAavePool public immutable aavePool;
    IERC20 public immutable asset;           // underlying asset e.g. USDC
    IERC20 public immutable aToken;          // aToken for the supplied asset
    IRewardController public rewardController;
    IUniswapV4Hook public uniswapHook;       // reward -> stable converter
    address public octantAllocation;         // Octant allocation contract address
    IImpactNFT public impactNFT;             // optional impact NFT contract

    // donation params (bps)
    uint16 public donationBps = 500; // 500 bps = 5%
    uint16 public constant MAX_DONATION_BPS = 1000; // 10% cap

    // accounting
    uint256 public lastAccountedAssets; // snapshot of accounted total assets (in underlying asset units)
    uint256 public minDonation = 1e6; // min donation to avoid dust (example for USDC; set appropriately)
    uint256 public liquidityBufferBps = 200; // 2% liquidity buffer kept on contract (bps)
    uint256 public totalDonated;     // global total donated via this adapter

    // safety
    bool public paused;
    uint256 public maxExposureBps = 10000; // 100% by default; set to lower to limit concentration

    // events
    event DepositedToAave(address indexed from, uint256 amount);
    event WithdrawnFromAave(address indexed to, uint256 amount);
    event AaveHarvested(uint256 realizedGain, uint256 donationAmount, uint256 timestamp);
    event DonationQueued(uint256 amount);
    event DonationSent(address indexed to, uint256 amount);
    event AdapterPaused();
    event AdapterUnpaused();
    event DonationBpsUpdated(uint16 oldBps, uint16 newBps);

    modifier notPaused() {
        require(!paused, "AaveAdapter: paused");
        _;
    }

    constructor(
        address _aavePool,
        address _asset,
        address _aToken,
        address _rewardController,
        address _uniswapHook,
        address _octantAllocation,
        address _impactNFT
    ) {
        aavePool = IAavePool(_aavePool);
        asset = IERC20(_asset);
        aToken = IERC20(_aToken);
        rewardController = IRewardController(_rewardController);
        uniswapHook = IUniswapV4Hook(_uniswapHook);
        octantAllocation = _octantAllocation;
        impactNFT = IImpactNFT(_impactNFT);
        // initial lastAccountedAssets is set when first deposit occurs
    }

    // ------------------------
    // USER-FACING / STRATEGY CALLS
    // ------------------------

    /// @notice Deposit underlying asset to Aave on behalf of this adapter
    function depositToAave(uint256 amount) external nonReentrant onlyOwner notPaused {
        require(amount > 0, "AaveAdapter: zero deposit");
        // pull asset into this contract - owner (NapFi vault) should have approved
        asset.safeTransferFrom(msg.sender, address(this), amount);

        // keep liquidity buffer on-contract: transfer buffer portion to internal variable (we keep it as balance)
        uint256 buffer = (amount * liquidityBufferBps) / 10000;
        // buffer remains on-contract for instant donation payouts; the rest is supplied
        uint256 toSupply = amount - buffer;

        if (toSupply > 0) {
            asset.safeIncreaseAllowance(address(aavePool), toSupply);
            aavePool.supply(address(asset), toSupply, address(this), 0);
        }

        // update accounting snapshots
        _updateAccountedAssetsAfterDeposit(buffer, toSupply);

        emit DepositedToAave(msg.sender, amount);
    }

    /// @notice Withdraw a given amount of underlying asset from Aave back to `to`
    function withdrawFromAave(uint256 amount, address to) external nonReentrant onlyOwner {
        require(amount > 0, "AaveAdapter: zero withdraw");
        // withdraw may return less due to slippage; we forward returned amount
        uint256 withdrawn = aavePool.withdraw(address(asset), amount, to);
        // update accounted assets snapshot conservatively
        _updateAccountedAssetsAfterWithdraw(withdrawn);
        emit WithdrawnFromAave(to, withdrawn);
    }

    /// @notice Harvest realized yield, claim rewards, convert and donate slice
    function harvest() external nonReentrant onlyOwner notPaused {
        // 1) claim rewards & convert to underlying (via uniswap hook)
        _claimAndConvertRewards();

        // 2) calculate realized yield relative to accounting snapshot
        uint256 currentAssets = totalAssets();
        uint256 realized = 0;
        if (currentAssets > lastAccountedAssets) {
            realized = currentAssets - lastAccountedAssets;
        }

        if (realized == 0) {
            // nothing to donate or compound
            lastAccountedAssets = currentAssets;
            return;
        }

        // 3) compute donation slice
        uint256 donation = (realized * donationBps) / 10000;

        // 4) ensure liquidity buffer can satisfy donation immediately
        uint256 bufferBalance = asset.balanceOf(address(this));
        if (bufferBalance < donation) {
            // attempt to withdraw small amount from Aave to top up buffer (non-blocking)
            uint256 needed = donation - bufferBalance;
            // try withdraw; note: if withdraw fails, we will queue donation (emit event) - non-blocking
            try aavePool.withdraw(address(asset), needed, address(this)) returns (uint256 w) {
                // success: buffer funded
            } catch {
                // if withdraw fails, we do not revert; we queue donation for later
                emit DonationQueued(donation - bufferBalance);
            }
        }

        // 5) send donation if buffer now sufficient
        uint256 sendAmount = 0;
        bufferBalance = asset.balanceOf(address(this));
        if (bufferBalance >= donation && donation >= minDonation) {
            asset.safeTransfer(octantAllocation, donation);
            sendAmount = donation;
            totalDonated += donation;
            emit DonationSent(octantAllocation, donation);
            // notify ImpactNFT & strategy (if needed)
            try impactNFT.updateTier(msg.sender, totalDonated) {} catch {}
        } else {
            // queue donation (emit) - off-chain relayer or next harvest should fulfill
            emit DonationQueued(donation);
        }

        // 6) remaining realized goes to compounding: we leave it in Aave or re-deposit
        // Step: update accounted assets
        uint256 newAssets = totalAssets();
        lastAccountedAssets = newAssets;

        emit AaveHarvested(realized, sendAmount, block.timestamp);
    }

    // ------------------------
    // REWARDS + CONVERSION
    // ------------------------
    /// @notice Claim rewards from Aave reward controller and convert to underlying using Uniswap Hook
    function _claimAndConvertRewards() internal {
        // this is a simplistic "claim all" approach - in prod you may specify assets & amounts
        address;
        assets[0] = address(aToken);
        // claim rewards to this contract
        try rewardController.claimRewards(assets, type(uint256).max, address(this)) returns (uint256 claimed) {
            // on success, claimToken must be determined or listed; for skeleton we assume reward token is known
            // For each reward token, call the uniswap hook to convert to underlying stable (asset)
            // Example: uniswapHook.swapRewardsToStable(rewardToken, claimed, address(this));
            // Note: implement reward token enumeration and actual swap logic in real implementation
        } catch {
            // If reward claim fails, don't revert harvest entirely
        }
    }

    // ------------------------
    // ACCOUNTING / VIEWS
    // ------------------------

    /// @notice Returns the total assets controlled by the adapter, in underlying units.
    /// This should include aToken balance (converted to underlying) + on-contract buffer
    function totalAssets() public view returns (uint256) {
        // 1) aToken balance (aTokens are 1:1 with underlying in Aave v3 normalized terms)
        uint256 aTokenBal = aToken.balanceOf(address(this));
        // If aTokens are non-rebasing and represent underlying 1:1, you can use aTokenBal directly.
        // If not, use pool.getReserveNormalizedIncome() to compute underlying; here we assume 1:1 for simplicity.
        uint256 buffer = asset.balanceOf(address(this));
        return aTokenBal + buffer;
    }

    // ------------------------
    // SAFETY & ORACLES
    // ------------------------

    /// @notice Oracle sanity check - placeholder for on-chain price checks (Chainlink)
    function oracleSanityCheck(uint256 priceAsset, uint256 priceRef) public view returns (bool) {
        // Implement checks: e.g. if price deviates more than X% between aggregator & ref, return false
        // This is a placeholder - integrate Chainlink oracles in production
        uint256 diff = priceAsset > priceRef ? priceAsset - priceRef : priceRef - priceAsset;
        // allow e.g. 10% deviation
        uint256 tolerance = (priceRef * 1000) / 10000; // 10%
        return diff <= tolerance;
    }

    /// @notice max exposure check relative to total protocol deposits (owner must set policy)
    function maxExposureCheck(uint256 protocolTotal) public view returns (bool) {
        uint256 myExposure = totalAssets();
        // require myExposure <= protocolTotal * maxExposureBps / 10000
        return myExposure <= ((protocolTotal * maxExposureBps) / 10000);
    }

    // ------------------------
    // ADMIN / CONFIG
    // ------------------------
    function setDonationBps(uint16 _bps) external onlyOwner {
        require(_bps <= MAX_DONATION_BPS, "AaveAdapter: donation bps too high");
        emit DonationBpsUpdated(donationBps, _bps);
        donationBps = _bps;
    }

    function setMinDonation(uint256 _minDonation) external onlyOwner {
        minDonation = _minDonation;
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

    // Emergency withdraw everything to owner (should be protected & timelocked in prod)
    function emergencyWithdrawAll(address to) external onlyOwner {
        paused = true;
        // withdraw max uint to get everything back
        try aavePool.withdraw(address(asset), type(uint256).max, to) returns (uint256 w) {
            // fine
        } catch {
            // If withdraw fails, we leave adapter paused for manual recovery
        }
    }

    // ------------------------
    // CHAINLINK / AUTO TRIGGER HOOK (basic)
    // ------------------------
    // Minimal performUpkeep style interface: external keeper can call shouldHarvest & performHarvest
    function shouldHarvest(uint256 minDeltaBps) external view returns (bool) {
        uint256 current = totalAssets();
        if (current <= lastAccountedAssets) return false;
        uint256 delta = current - lastAccountedAssets;
        // treat minDeltaBps relative to lastAccounted
        uint256 threshold = (lastAccountedAssets * minDeltaBps) / 10000;
        return delta >= threshold;
    }

    function performHarvest() external nonReentrant notPaused {
        // this is a permissive function; in production restrict to keeper or Chainlink automation
        harvest();
    }

}
