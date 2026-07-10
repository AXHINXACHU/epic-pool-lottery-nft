# 🏆 Epic Pool Lottery NFT (`EPL`)

An advanced, gas-optimized ERC721 smart contract that combines a hyper-exclusive **10 NFT collection hard-cap**, automated **on-chain metadata generation**, an **internal secondary marketplace**, and **dual-raffle mechanics** powered securely by Chainlink VRF v2.5.

## ✨ Core Architecture Features

* **Strict 10 NFT Total Supply:** The contract enforces a global maximum supply of exactly 10 tokens. Once token #10 is minted, the primary minting engine shuts down forever.
* **100% On-Chain Metadata:** Token names (`EPIC NUMBER #1` to `EPIC NUMBER #10`) and metadata JSON payloads are dynamically generated and Base64 encoded entirely on-chain. **Zero IPFS paths or API arguments are required from the frontend client.**
* **Dual Chainlink VRF Lotteries:** Uses the modern Chainlink VRF v2.5 standard to execute mathematically un-gameable random selections.

---

## 📊 Financial Logic & Pool Mechanics

### 1. Primary Mint Lottery
* **Ticket Price:** Exactly `1.0 ETH` per mint.
* **Trigger:** Instantly fires when the 10th and final NFT is successfully purchased.
* **The Split:** The total accumulated **10 ETH pool** is mathematically divided **50/50**:
  * **5 ETH** goes directly to one randomly selected NFT holder.
  * **5 ETH** goes directly to the contract owner.

### 2. Secondary Marketplace & Fee Raffle
The contract features a self-contained, peer-to-peer trading floor with automated fee accumulation routing:
* **Dynamic Fee Structure:** 
  * If an NFT is sold for **greater than 1 ETH**, a **10% marketplace fee** is retained.
  * If an NFT is sold for **1 ETH or less**, a flat **0.1 ETH marketplace fee** is retained.
* **The Secondary Payout:** Every time **10 total secondary transactions** occur, a secondary raffle draws a winner from that round's buyers:
  * **75%** of the accumulated fee pool goes to one random secondary buyer.
  * **25%** of the accumulated fee pool goes to the contract owner.

---

## 🛠️ Deployment Configuration (Sepolia Testnet)

Deploy this contract using the following official Chainlink parameters:

* **VRF Coordinator Address:** `0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B`
* **Gas Key Hash (30 gwei Lane):** `0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae`

*Note: Remember to add your newly deployed contract address as an authorized "Consumer" inside your Chainlink VRF Subscription Manager dashboard.*
