const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);

  // Read environment variables or set defaults
  const subscriptionId = process.env.VRF_SUBSCRIPTION_ID || "0";
  const keyHash = process.env.VRF_KEY_HASH || "0x787d74d553800ca6176522773e2868806ed77e070d64c575487b20463e08c16b";
  const vrfCoordinator = process.env.VRF_COORDINATOR || "0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B";
  const teamWallet = process.env.TEAM_WALLET_ADDRESS || deployer.address;

  console.log("Deploying AdvancedLotteryNFT...");
  const LotteryFactory = await hre.ethers.getContractFactory("AdvancedLotteryNFT");
  const lottery = await LotteryFactory.deploy(
    subscriptionId,
    keyHash,
    vrfCoordinator,
    teamWallet
  );

  await lottery.waitForDeployment();
  const lotteryAddress = await lottery.getAddress();

  console.log("✅ AdvancedLotteryNFT deployed to:", lotteryAddress);

  // Fetch the automatically deployed EpicCoin address
  const epicCoinAddress = await lottery.epicCoin();
  console.log("🪙 EpicCoin deployed to:", epicCoinAddress);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
