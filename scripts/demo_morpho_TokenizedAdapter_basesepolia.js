/**
 * 💎 NapFi x MorphoAdapter — Base Sepolia Testnet Demo
 * ----------------------------------------------------
 * Reads live RPC data, uses real wallet + on-chain deployment.
 *
 * Run:
 *   npx hardhat run scripts/demo_morpho_adapter_basesepolia.js --network baseSepolia
 */

import "dotenv/config";
import chalk from "chalk";
import ora from "ora";
import { ethers } from "hardhat";

async function delay(ms) { return new Promise((r) => setTimeout(r, ms)); }

function renderDonationBar(current, total, width = 28) {
  const ratio = Math.min(current / total, 1);
  const filled = Math.floor(width * ratio);
  const bar = chalk.magenta("█".repeat(filled)) + chalk.gray("░".repeat(width - filled));
  return `${chalk.white("Donation Flow:")} [${bar}] ${chalk.cyan(Math.floor(ratio * 100) + "%")}`;
}

function renderChart(points, maxPoints = 30, maxHeight = 10) {
  const normalized = points.slice(-maxPoints);
  const maxValue = Math.max(...normalized, 1);
  const scale = maxHeight / maxValue;
  let lines = [];
  for (let h = maxHeight; h >= 0; h--) {
    let line = "";
    for (const v of normalized) {
      line += v * scale >= h ? chalk.green("█") : " ";
    }
    lines.push(line);
  }
  return lines.join("\n") + "\n" + chalk.gray("‾".repeat(normalized.length)) + " yield →";
}

async function main() {
  console.clear();
  console.log(chalk.bold.cyan("\n💎 NAPFI x MORPHO ADAPTER — BASE SEPOLIA DEMO"));
  console.log(chalk.gray("──────────────────────────────────────────────\n"));

  const spinner = ora("🚀 Deploying contracts on Base Sepolia...").start();
  const [deployer] = await ethers.getSigners();
  const octantWallet = process.env.OCTANT_TEST_WALLET;

  // --- Deploy minimal test mocks ---
  const MockERC20 = await ethers.getContractFactory("MockERC20");
  const usdc = await MockERC20.deploy("Test USDC", "USDC");
  const reward = await MockERC20.deploy("RewardToken", "RWD");

  const MockMorpho = await ethers.getContractFactory("MockMorpho");
  const morpho = await MockMorpho.deploy();

  const MockRewardsController = await ethers.getContractFactory("MockRewardsController");
  const rewards = await MockRewardsController.deploy(await reward.getAddress());

  const MockUniswapHook = await ethers.getContractFactory("MockUniswapHook");
  const hook = await MockUniswapHook.deploy();

  const MockImpactNFT = await ethers.getContractFactory("MockImpactNFT");
  const nft = await MockImpactNFT.deploy();

  const MorphoAdapter = await ethers.getContractFactory("MorphoAdapter");
  const adapter = await MorphoAdapter.deploy(
    await morpho.getAddress(),
    await rewards.getAddress(),
    await usdc.getAddress(),
    await hook.getAddress(),
    octantWallet,
    await nft.getAddress()
  );
  spinner.succeed(chalk.green(`✅ Deployed MorphoAdapter: ${await adapter.getAddress()}\n`));

  // --- Mint & approve ---
  const mintAmount = ethers.parseUnits("5000", 6);
  await usdc.mint(deployer.address, mintAmount);
  await usdc.approve(await adapter.getAddress(), mintAmount);

  console.log(chalk.bold("💰 Step 1: Deposit 5,000 USDC"));
  await (await adapter.depositToMorpho(mintAmount)).wait();
  console.log(chalk.green("✅ Deposit complete!\n"));

  // --- Simulate yield accrual ---
  const yieldSpinner = ora("📈 Simulating yield growth...").start();
  await delay(2000);
  await (await morpho.simulateYield(await usdc.getAddress(), 2e24)).wait();
  yieldSpinner.succeed(chalk.green("Yield simulated.\n"));

  console.log(chalk.bold("🌿 Step 2: Tracking live yield..."));
  const yieldPoints = [];
  const totalDonationTarget = 300;
  let donationSoFar = 0;

  for (let i = 0; i < 25; i++) {
    const totalAssets = await adapter.totalAssets();
    const assetsValue = Number(ethers.formatUnits(totalAssets, 6));
    yieldPoints.push(assetsValue / 1000);
    if (yieldPoints.length > 30) yieldPoints.shift();

    const octBal = Number(ethers.formatUnits(await usdc.balanceOf(octantWallet), 6));
    donationSoFar = Math.min(octBal, totalDonationTarget);

    console.clear();
    console.log(chalk.bold.cyan("\n💎 NAPFI x MORPHO ADAPTER — BASE SEPOLIA DEMO\n"));
    console.log(renderChart(yieldPoints, 30, 10));
    console.log("\n" + renderDonationBar(donationSoFar, totalDonationTarget));
    console.log(chalk.gray(`\n🌐 RPC: ${process.env.BASE_RPC.slice(8, 28)}...`));
    console.log(chalk.gray(`💼 Assets: ${chalk.yellow(assetsValue.toFixed(2))} USDC`));
    console.log(chalk.gray(`💖 Donated: ${chalk.magenta(donationSoFar.toFixed(2))} USDC`));

    await delay(1200);
    await (await morpho.simulateYield(await usdc.getAddress(), 1e24)).wait();
  }

  console.log(chalk.bold("\n🌈 Executing final on-chain harvest..."));
  const tx = await adapter.harvest();
  await tx.wait();

  const finalDonation = await usdc.balanceOf(octantWallet);
  console.log(chalk.green(`\n✅ Harvest done — donation sent: ${ethers.formatUnits(finalDonation, 6)} USDC`));
  console.log(chalk.bold.cyan("\n🏆 Octant V2 x NapFi Live Testnet Demo Complete!\n"));
}

// --- Mint Proof of Impact NFT ---
console.log(chalk.bold("\n🪩 Step 3: Minting Proof of Impact NFT..."));

const donationAmount = finalDonation;
const MockImpactNFT = await ethers.getContractFactory("MockImpactNFT");
const impactNFT = await MockImpactNFT.attach(await nft.getAddress());

// Tier logic for demo
let tierLabel = "Supporter 💚";
if (donationAmount > ethers.parseUnits("250", 6)) tierLabel = "Community Builder 💎";
if (donationAmount > ethers.parseUnits("500", 6)) tierLabel = "Public Goods Champion 🔥";

// Mint NFT
const mintTx = await impactNFT.mint(deployer.address, donationAmount);
await mintTx.wait();

console.log(chalk.green(`✅ NFT Minted to ${deployer.address}`));
console.log(chalk.bold(`🏷️ Tier: ${chalk.cyan(tierLabel)}`));
console.log(chalk.gray(`💖 Donation Proof: ${ethers.formatUnits(donationAmount, 6)} USDC`));
console.log(chalk.gray(`🕓 Timestamp: ${new Date().toLocaleTimeString()}\n`));

console.log(chalk.bold.cyan("🏆 Octant V2 x NapFi Full Cycle Complete — Proof of Impact Recorded! 🌍"));

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
