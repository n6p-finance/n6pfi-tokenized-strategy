// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../strategy/src/MorphoAdapter.sol"; // adjust path if needed
import "openzeppelin-contracts/token/ERC20/ERC20.sol";

// -----------------------------------------------------------
// Mock contracts
// -----------------------------------------------------------

// Mock ERC20 token (USDC, reward, etc.)
contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Mock Morpho protocol
contract MockMorpho is IMorpho {
    mapping(address => mapping(address => uint256)) public supplied;
    mapping(address => uint256) public p2pIndex;

    function supply(address asset, uint256 amount, address onBehalfOf) external override {
        supplied[asset][onBehalfOf] += amount;
        ERC20(asset).transferFrom(msg.sender, address(this), amount);
    }

    function withdraw(address asset, uint256 amount, address to) external override returns (uint256) {
        uint256 bal = supplied[asset][msg.sender];
        if (amount > bal) amount = bal;
        supplied[asset][msg.sender] -= amount;
        ERC20(asset).transfer(to, amount);
        return amount;
    }

    function getP2PIndex(address asset) external view override returns (uint256) {
        return p2pIndex[asset];
    }

    function getTotalSupplied(address asset, address user) external view override returns (uint256) {
        return supplied[asset][user];
    }

    // helper for test to simulate yield growth
    function simulateYield(address asset, uint256 delta) external {
        p2pIndex[asset] += delta;
    }
}

// Mock Rewards Controller
contract MockRewardsController is IRewardsController {
    address public rewardToken;
    uint256 public rewardAmount;

    constructor(address _rewardToken) {
        rewardToken = _rewardToken;
    }

    function setRewardAmount(uint256 amt) external {
        rewardAmount = amt;
    }

    function claimAllRewardsToSelf(address[] calldata)
        external
        override
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        tokens = new address ;
        tokens[0] = rewardToken;
        amounts = new uint256 ;
        amounts[0] = rewardAmount;

        if (rewardAmount > 0) {
            MockERC20(rewardToken).mint(msg.sender, rewardAmount);
        }
    }
}

// Mock Uniswap Hook (1:1 swap)
contract MockUniswapHook is IUniswapV4Hook {
    function swapRewardsToStable(
        address rewardToken,
        uint256 amount,
        address to,
        address stableToken
    ) external override returns (uint256) {
        // Burn reward token (simulate swap)
        ERC20(rewardToken).transferFrom(msg.sender, address(0xdead), amount);
        // Mint equal stable token amount
        MockERC20(stableToken).mint(to, amount);
        return amount;
    }
}

// Mock ImpactNFT
contract MockImpactNFT is IImpactNFT {
    mapping(address => uint256) public donated;
    function updateTier(address user, uint256 totalDonated) external override {
        donated[user] = totalDonated;
    }
}

// -----------------------------------------------------------
// Main Test Contract
// -----------------------------------------------------------

contract MorphoAdapterTest is Test {
    MorphoAdapter adapter;
    MockERC20 usdc;
    MockERC20 reward;
    MockMorpho morpho;
    MockRewardsController rewards;
    MockUniswapHook hook;
    MockImpactNFT nft;

    address owner = address(this);
    address octant = address(0xBEEF);

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC");
        reward = new MockERC20("Reward", "RWD");
        morpho = new MockMorpho();
        rewards = new MockRewardsController(address(reward));
        hook = new MockUniswapHook();
        nft = new MockImpactNFT();

        adapter = new MorphoAdapter(
            address(morpho),
            address(rewards),
            address(usdc),
            address(hook),
            octant,
            address(nft)
        );

        adapter.transferOwnership(owner);

        // mint funds for owner
        usdc.mint(owner, 1_000_000e6);
    }

    // -------------------------------------------------------
    // 1. Deposit tests
    // -------------------------------------------------------
    function testDepositToMorpho() public {
        uint256 amount = 1000e6;
        usdc.approve(address(adapter), amount);
        adapter.depositToMorpho(amount);

        // buffer retained
        uint256 buffer = (amount * adapter.liquidityBufferBps()) / 10000;
        assertEq(usdc.balanceOf(address(adapter)), buffer, "buffer mismatch");
        // rest supplied
        assertEq(morpho.supplied(address(usdc), address(adapter)), amount - buffer);
    }

    // -------------------------------------------------------
    // 2. P2P Donation Slicer tests
    // -------------------------------------------------------
    function testP2PDonationSlicer() public {
        uint256 amount = 1000e6;
        usdc.approve(address(adapter), amount);
        adapter.depositToMorpho(amount);

        // simulate yield index +1e24 (~0.1%)
        morpho.simulateYield(address(usdc), 1e24);

        uint256 beforeOctant = usdc.balanceOf(octant);
        adapter.computeP2PIndexDelta();
        uint256 afterOctant = usdc.balanceOf(octant);

        assertGt(afterOctant, beforeOctant, "donation not streamed");
        assertEq(nft.donated(address(adapter)), adapter.totalDonated(), "NFT not updated");
    }

    // -------------------------------------------------------
    // 3. Harvest with rewards
    // -------------------------------------------------------
    function testHarvestWithRewards() public {
        uint256 amount = 1000e6;
        usdc.approve(address(adapter), amount);
        adapter.depositToMorpho(amount);

        // simulate yield + rewards
        morpho.simulateYield(address(usdc), 2e24); // P2P gain
        rewards.setRewardAmount(50e6);             // reward = 50 USDC worth

        uint256 before = usdc.balanceOf(octant);
        adapter.harvest();
        uint256 after = usdc.balanceOf(octant);

        assertGt(after, before, "no donation sent");
        assertGt(adapter.totalDonated(), 0, "donation not recorded");
    }

    // -------------------------------------------------------
    // 4. Donation queued path (buffer too low)
    // -------------------------------------------------------
    function testDonationQueuedWhenBufferLow() public {
        uint256 amount = 1000e6;
        adapter.setLiquidityBufferBps(0); // no buffer
        usdc.approve(address(adapter), amount);
        adapter.depositToMorpho(amount);

        morpho.simulateYield(address(usdc), 5e24);
        vm.expectEmit(false, false, false, false);
        emit DonationQueued(0); // generic check for queued event
        adapter.computeP2PIndexDelta();
    }

    // -------------------------------------------------------
    // 5. Pause & emergency
    // -------------------------------------------------------
    function testPauseAndEmergencyWithdraw() public {
        uint256 amount = 1000e6;
        usdc.approve(address(adapter), amount);
        adapter.depositToMorpho(amount);
        adapter.pauseAdapter();

        vm.expectRevert();
        adapter.depositToMorpho(amount); // should revert

        adapter.emergencyWithdrawAll(owner);
        assertTrue(adapter.paused(), "adapter should remain paused");
    }
}
