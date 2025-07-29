# SealProtocol CLMM on Sui

This repository contains the on-chain implementation of a Centralized Liquidity Automated Market Maker (CLMM) for the [SealProtocol](https://github.com/sealprotocol). It is written in [Sui Move](https://docs.sui.io/), a smart contract language designed for the Sui blockchain.

## 🔍 Overview

The CLMM supports the following features:

- Creation of liquidity pools for any two fungible tokens
- Adding and removing liquidity
- Token swaps with configurable fee tiers
- Platform and LP fee tracking
- 24h trading volume and fee metrics
- APR estimation and TVL tracking

It ensures fairness and transparency with strict mathematical invariants such as maintaining price ratios and fair distribution of fees.

## 📁 Repository

GitHub: [https://github.com/sealprotocol/CLMM-CORE](https://github.com/sealprotocol/CLMM-CORE)

```bash
git clone https://github.com/sealprotocol/CLMM-CORE.git
cd CLMM-CORE
```
## 🚀 Deploying to Sui
Make sure you have installed the Sui CLI and configured a local wallet.

1. Build the Move Package
```bash
sui move build
```
This command compiles the Move.toml package and ensures there are no syntax or logic errors.

2. Publish the Contract
You can publish the contract to a local network or testnet:
```bash
sui client publish --gas-budget 100000000
```
Once published, the Sui CLI will return the package ID of your deployed contract. You can then start interacting with the CLMM module using this package ID.

### ✍️ License
MIT License © SealProtocol