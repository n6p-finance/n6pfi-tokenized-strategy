## aaveAdapter.sol:

User
 │
 ▼
NapFiVault (ERC-4626)
 │   - Accepts user deposits (e.g. USDC)
 │   - Mints vault shares
 │   - Calls AaveAdapter to invest funds
 │
 ▼
AaveAdapter (NapFi Meta-Donation Strategy)
 │
 ├─ depositToAave() → supplies 98% to Aave
 │      └─ Keeps 2% liquidity buffer in adapter for instant donations
 │
 ├─ Earns yield through:
 │      - aToken interest accrual
 │      - Aave reward tokens (emission incentives)
 │
 ├─ harvest()
 │      1️⃣ Claim all Aave rewards
 │      2️⃣ Convert each reward token → stable via Uniswap V4 Hook
 │      3️⃣ Measure totalAssets() vs lastAccountedAssets
 │      4️⃣ Compute realized yield (Δ assets)
 │      5️⃣ Slice 5% of realized yield as donation
 │      6️⃣ Transfer donation → OctantAllocation (public goods)
 │      7️⃣ Update user’s ImpactNFT tier (Proof-of-Impact)
 │
 ├─ Safety & Automation
 │      - oracleSanityCheck(): price deviation guard
 │      - maxExposureCheck(): portfolio exposure limit
 │      - Chainlink-compatible shouldHarvest() + performHarvest()
 │      - pauseAdapter() / emergencyWithdrawAll() for failsafe
 │
 └─ Accounting
        - lastAccountedAssets updated every harvest
        - totalDonated tracked cumulatively for Proof-of-Impact
