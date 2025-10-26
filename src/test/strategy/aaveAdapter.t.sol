// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/strategy/aaveAdapter.sol";

// ------------------------------------------------------------
// Mock contracts
// ------------------------------------------------------------
contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) { name = n; symbol = s; }

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; totalSupply += amount; }
    function approve(address spender, uint256 amount) external returns (bool) { allowance[msg.sender][spender] = amount; return true; }
    function transfer(address to, uint256 amount) external returns (bool) { balanceOf[msg.sender]-=amount; balanceOf[to]+=amount; return true; }
    function transferFrom(address from,address to,uint256 amount) external returns (bool){
        allowance[from][msg.sender]-=amount; balanceOf[from]-=amount; balanceOf[to]+=amount; return true;
    }
}

contract MockAavePool is IAavePool {
    MockERC20 public aToken;
    mapping(address => uint256) public supplied;

    constructor(address _aToken){ aToken = MockERC20(_aToken); }

    function supply(address asset,uint256 amount,address onBehalf,uint16) external override {
        MockERC20(asset).transferFrom(msg.sender, address(this), amount);
        supplied[onBehalf] += amount;
        aToken.mint(onBehalf, amount); // mint 1:1 aTokens
    }

    function withdraw(address asset,uint256 amount,address to) external override returns(uint256){
        uint256 bal = aToken.balanceOf(msg.sender);
        uint256 out = amount > bal ? bal : amount;
        aToken.transferFrom(msg.sender, address(this), out);
        MockERC20(asset).mint(to, out);
        return out;
    }

    // unused mocks
    function getReserveNormalizedIncome(address) external pure returns(uint256){ return 1e27; }
    function getUserAccountData(address) external pure returns(uint256,uint256,uint256,uint256,uint256,uint256){ return (0,0,0,0,0,0); }
}

contract MockRewardsController is IRewardsController {
    address[] public rewards;
    mapping(address => uint256) public rewardBalance;

    constructor(address rewardToken){ rewards.push(rewardToken); }

    function fundReward(address to,uint256 amount) external { rewardBalance[to]+=amount; }

    function getRewardsList() external view returns(address[] memory){ return rewards; }

    function claimAllRewardsToSelf(address[] calldata) external returns(address[] memory,uint256[] memory){
        uint256 ;
        claimed[0]=rewardBalance[msg.sender];
        rewardBalance[msg.sender]=0;
        return (rewards, claimed);
    }
}

contract MockUniswapHook is IUniswapV4Hook {
    IERC20 public rewardToken; IERC20 public stable;
    constructor(address r,address s){ rewardToken = IERC20(r); stable = IERC20(s); }
    function swapRewardsToStable(address, uint256 amount, address to, address) external returns(uint256){
        // 1:1 mock conversion
        MockERC20(address(stable)).mint(to, amount);
        return amount;
    }
}

contract MockImpactNFT is IImpactNFT {
    mapping(address=>uint256) public donated;
    event TierUpdated(address user,uint256 total);
    function updateTier(address user,uint256 totalDonated) external { donated[user]=totalDonated; emit TierUpdated(user,totalDonated); }
}

// ------------------------------------------------------------
// Main Test
// ------------------------------------------------------------
contract AaveAdapterTest is Test {
    AaveAdapter adapter;
    MockERC20 usdc;
    MockERC20 aToken;
    MockERC20 rewardToken;
    MockAavePool pool;
    MockRewardsController rewards;
    MockUniswapHook hook;
    MockImpactNFT nft;
    address octantAlloc = address(0xA11C);

    address owner = address(this);

    function setUp() public {
        usdc = new MockERC20("USD Coin","USDC");
        aToken = new MockERC20("aUSDC","aUSDC");
        rewardToken = new MockERC20("AAVE","AAVE");
        pool = new MockAavePool(address(aToken));
        rewards = new MockRewardsController(address(rewardToken));
        hook = new MockUniswapHook(address(rewardToken), address(usdc));
        nft = new MockImpactNFT();

        adapter = new AaveAdapter(
            address(pool),
            address(rewards),
            address(usdc),
            address(aToken),
            address(hook),
            octantAlloc,
            address(nft)
        );
        adapter.transferOwnership(owner);

        // Mint initial user funds
        usdc.mint(owner, 1_000_000e6);
        usdc.approve(address(adapter), type(uint256).max);
    }

    function testDepositAndHarvestDonation() public {
        // deposit
        adapter.depositToAave(100_000e6);
        uint256 before = adapter.totalAssets();
        assertEq(before, 100_000e6);

        // simulate interest: mint extra aTokens
        aToken.mint(address(adapter), 5_000e6); // +5% gain

        // simulate reward funding
        rewards.fundReward(address(adapter), 1_000e6);
        rewardToken.mint(address(adapter), 1_000e6);

        // harvest: should donate 5% of gain (≈250 USDC)
        adapter.harvest();

        uint256 afterAssets = adapter.totalAssets();
        assertGt(afterAssets, before); // compounding works

        // check donation
        uint256 donated = adapter.totalDonated();
        assertEq(donated, (5_000e6 * 500 / 10000)); // 5% of realized

        // verify NFT updated
        assertEq(nft.donated(owner), donated);
    }

    function testPauseAndEmergencyWithdraw() public {
        adapter.depositToAave(10_000e6);
        adapter.pauseAdapter();
        vm.expectRevert();
        adapter.depositToAave(1_000e6); // should fail when paused
        adapter.emergencyWithdrawAll(owner);
    }
}
