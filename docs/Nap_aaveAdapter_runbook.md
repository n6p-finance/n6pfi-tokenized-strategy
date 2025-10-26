Perfect ✅ — here’s your **one-page professional Runbook** for the **NapFi AaveAdapter Strategy**, written in the same style used by winning hackathon teams.
It includes **setup, deployment, testing, verification, and submission notes**, fully optimized for **Foundry + Octant V2 + Aave V3 + Uniswap V4 Hooks integration**.

---

# 🧩 **NapFi AaveAdapter – Operational Runbook (Hackathon Version)**

> **Goal:** Deploy and demonstrate a modular Aave-based strategy that donates yield to **Octant V2** and updates **Impact NFTs** for users, covering the *Aave v3*, *Uniswap v4 Hook*, and *Octant Public Goods* tracks.

---

## ⚙️ **1️⃣ Prerequisites & Environment Setup**

### 📦 Dependencies

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Clone NapFi repo
git clone https://github.com/<your-repo>/napfi-octant-v2.git
cd napfi-octant-v2

# Install dependencies
forge install OpenZeppelin/openzeppelin-contracts@v5.0.0
forge install aave/aave-v3-core
forge install uniswap/uniswap-v4-core
```

### 🧠 Optional Libraries (if you want off-chain bots)

* Chainlink Automation SDK (`@chainlink/contracts`)
* Ethers.js (for local harvest automation)
* Hardhat/Foundry interop if needed

---

## 🧱 **2️⃣ Contract Deployment Flow**

### Step 1 — Deploy Dependencies (testnet or fork)

Use **Sepolia** or **Mainnet Fork** for best judge verification.

| Contract                   | Action                                         | Example                             |
| -------------------------- | ---------------------------------------------- | ----------------------------------- |
| **Aave Pool**              | Use deployed Aave V3 Pool on Sepolia           | `0x...AAVE_POOL`                    |
| **Aave RewardsController** | Use Sepolia address                            | `0x...REWARDS_CTRL`                 |
| **Uniswap V4 Hook**        | Deploy your custom reward swap contract        | e.g., convert AAVE → USDC           |
| **Octant Allocation**      | Deploy a mock “Public Goods Receiver” contract | emits event for donation tracking   |
| **ImpactNFT**              | Deploy minimal ERC721                          | mints/updates tiers after donations |

### Step 2 — Deploy the **AaveAdapter**

```bash
forge create src/strategies/AaveAdapter.sol:AaveAdapter \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args \
  0xAAVE_POOL \
  0xREWARDS_CTRL \
  0xUSDC \
  0xaUSDC \
  0xUNISWAP_HOOK \
  0xOCTANT_ALLOC \
  0xIMPACT_NFT
```

✅ **Output:** Save deployment address as `AAVE_ADAPTER_ADDR`

### Step 3 — Initialize Donation Parameters

```bash
cast send $AAVE_ADAPTER_ADDR "setDonationBps(uint16)" 500 --private-key $PRIVATE_KEY
cast send $AAVE_ADAPTER_ADDR "setLiquidityBufferBps(uint256)" 200 --private-key $PRIVATE_KEY
```

---

## 💸 **3️⃣ Simulation & Testing Flow (Foundry)**

### Test Case: Deposit → Interest → Harvest → Donation → NFT Update

**Example: `test/AaveAdapter.t.sol`**

```solidity
function test_harvest_donates_to_octant() public {
    // 1. Deposit mock USDC
    vm.prank(owner);
    adapter.depositToAave(1000e6); // 1,000 USDC

    // 2. Simulate interest accrual
    deal(address(aToken), address(adapter), 1020e6); // +2% gain

    // 3. Run harvest
    vm.prank(owner);
    adapter.harvest();

    // 4. Check donation (5% of 20 = 1 USDC)
    assertEq(mockOctant.lastDonationAmount(), 1e6);

    // 5. Verify NFT tier updated
    assertEq(mockNFT.totalDonated(owner), 1e6);
}
```

✅ **Expected output:**

```
✓ DonationSent(octantAllocation=0x..., amount=1000000)
✓ ImpactNFT.updateTier(owner, totalDonated=1000000)
```

---

## 🔁 **4️⃣ Yield Conversion Logic Verification**

* Simulate multiple reward tokens:

  * Mock AAVE, stkAAVE, GHO rewards.
* Call `_claimAndConvertRewards()` → ensure each is swapped through Uniswap Hook.
* Verify `RewardsConverted` events emit correct input/output values.

**Quick check:**

```bash
cast call $AAVE_ADAPTER_ADDR "totalAssets()" --rpc-url $RPC_URL
```

---

## 🛡️ **5️⃣ Safety & Automation Validation**

| Feature               | Command/Test                                   | Purpose                 |
| --------------------- | ---------------------------------------------- | ----------------------- |
| **Pause Adapter**     | `pauseAdapter()`                               | Emergency shutdown      |
| **Oracle Check**      | `oracleSanityCheck(usdPrice, refPrice)`        | 10% deviation guard     |
| **Max Exposure**      | `maxExposureCheck(protocolTotal)`              | Risk control            |
| **Chainlink Keepers** | Call `shouldHarvest(100)` → `performHarvest()` | Auto-harvesting trigger |

✅ Judges can verify live automation simulation using:

```bash
cast send $KEEPER_ADDR "performHarvest()" --rpc-url $RPC_URL
```

---

## 🌈 **6️⃣ Showcase Dashboard Integration (Optional)**

Front-end should display:

| UI Element               | Description                              |
| ------------------------ | ---------------------------------------- |
| 💰 “Your Earned Yield”   | Realized gain from adapter               |
| ✨ “Your Donation Impact” | Cumulative total donated                 |
| 🧩 Proof-of-Impact NFT   | Live tier badge linked to wallet         |
| 📊 Leaderboard           | Rank by GlowScore (total donated)        |
| 🎛️ Donation Slider      | Adjust yield donation percentage (1–10%) |

> Judges love **visible feedback loops** — this UI proves the concept and supports the *Most Creative Use of Octant V2* track.

---

## 🧾 **7️⃣ Submission & Documentation**

**Include in submission repo:**

```
/src/strategies/AaveAdapter.sol
/test/AaveAdapter.t.sol
/docs/NapFi_AaveAdapter_Runbook.md  ✅
/docs/Architecture_Diagram.png
```

**README sections:**

1. Problem & Goal
2. Architecture Diagram (ASCII or Lucidchart)
3. Contract Addresses & Test Results
4. Innovation Highlights
5. Runbook (this file)

---

## 🧠 **8️⃣ Judge Talking Points**

When presenting:

* Emphasize **“yield donation → NFT proof → public goods loop.”**
* Mention **cross-track coverage**:

  * Aave v3 vault logic ✅
  * Uniswap v4 reward hook ✅
  * Octant yield donation ✅
  * NFT gamification ✅
  * Automation-ready harvest ✅

> “NapFi’s AaveAdapter transforms idle yield into sustainable funding for public goods — turning every DeFi user into an ongoing impact supporter.”

---

## ✅ **Final Quick Summary**

| Category          | Status | Feature                    |
| ----------------- | ------ | -------------------------- |
| Yield Integration | ✅      | Aave V3 ERC-4626 + Rewards |
| Reward Conversion | ✅      | Uniswap V4 Hook            |
| Donation Routing  | ✅      | Octant Allocation (5%)     |
| Gamification      | ✅      | ImpactNFT Proof System     |
| Safety            | ✅      | Oracle + Exposure Checks   |
| Automation        | ✅      | Chainlink-Compatible       |
| Documentation     | ✅      | Runbook + Architecture     |
| Test Coverage     | ✅      | Deposit → Harvest → Donate |

---

Would you like me to now generate the **mock contracts (OctantAllocation + ImpactNFT + UniswapHook)** in Foundry style, so you can test this end-to-end locally?
They’ll be <100 lines each and simulate the donation + NFT tier update perfectly for demo.
