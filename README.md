## Policast Prediction Market

A decentralized prediction market built with Foundry, implementing the Logarithmic Market Scoring Rule (LMSR) for efficient price discovery.

## Contracts

- **PolicastMarketV3**: Main prediction market contract with trading and resolution functionality
- **PolicastViews**: Separated view functions to optimize contract size
- **LMSRMath**: Library for logarithmic market scoring rule calculations

## Features

- ⚡ LMSR-based pricing for efficient market making
- 🎯 Multiple market types (Free entry, Paid entry)
- 🛡️ Role-based access control
- 📊 Real-time price feeds and market analytics
- 🔄 Early resolution for event-based markets
- 💰 Platform fee collection and distribution

## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Deploy

#### Prerequisites

1. Install Foundry: https://book.getfoundry.sh/getting-started/installation
2. Set up your environment variables

#### Environment Variables

Create a `.env` file in the project root with:

```bash
PRIVATE_KEY=your_private_key_without_0x_prefix
BETTING_TOKEN=0x... # Address of the ERC20 token to use for betting
RESOLVER_ADDRESS=0x... # Optional: Address to grant resolver role
```

#### Run Deployment

```shell
# Deploy to mainnet/testnet
forge script script/DeployPolicast.s.sol --rpc-url <your_rpc_url> --broadcast --verify

# Example: Deploy to Sepolia testnet
forge script script/DeployPolicast.s.sol --rpc-url https://sepolia.infura.io/v3/YOUR_INFURA_KEY --broadcast --verify
```

### Anvil (Local Development)

```shell
$ anvil
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```

## Contract Sizes

Current contract sizes (optimized for EVM deployment limits):

- PolicastMarketV3: 27,282 bytes
- PolicastViews: 4,148 bytes

## Testing

```bash
# Run all tests
forge test

# Run specific test file
forge test --match-contract PolicastBasicTest

# Run with gas reporting
forge test --gas-report
```

## Architecture

The contracts are designed with gas optimization in mind:

- Core trading logic in PolicastMarketV3
- View functions separated into PolicastViews to reduce main contract size
- LMSR math library for efficient price calculations
- Role-based access control for security
