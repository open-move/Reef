# Reef Oracle Documentation

Reef is an optimistic oracle system built for Sui blockchain that enables smart contracts to access real-world data through economic incentives rather than trusted intermediaries.

## What is an Optimistic Oracle?

Unlike traditional oracles that push data continuously, optimistic oracles work on a different principle: they assume proposed data is correct unless someone disputes it. This creates a system where accurate data flows efficiently while economic incentives prevent manipulation.

Think of it like Wikipedia - most edits are correct, so the system assumes they are unless someone challenges them. The key difference is that challenging requires putting money on the line, making false challenges expensive.

## How Reef Works

The process follows a simple four-step cycle:

1. **Query Creation**: Someone needs data and creates a query with specific parameters
2. **Claim Submission**: Data providers submit their answer along with a bond
3. **Challenge Window**: Others can dispute the claim by posting an equal bond
4. **Settlement**: If unchallenged, the claim is accepted. If challenged, a resolver determines the truth

This design means most queries resolve quickly and cheaply, while disputed queries get careful review through economic mechanisms.

## Key Benefits

**Economic Security**: Wrong answers cost money, creating strong incentives for accuracy

**Efficiency**: Most data flows without expensive verification processes  

**Flexibility**: Support any data type through raw byte encoding

**Composability**: Integrate with any Sui smart contract seamlessly

**Customizable**: Configure bonds, timeouts, and resolution methods per query

## Core Components

The system consists of four main modules:

- **Protocol**: Global configuration and economic parameters
- **Reef**: Query lifecycle and core oracle logic  
- **Resolver**: Pluggable dispute resolution framework
- **Callback**: Event notifications for query creators

## Quick Start

```bash
# Build the project
cd packages/reef
sui move build

# Run tests
sui move test
```

## Documentation Overview

- [Getting Started](getting-started.md) - Setup and first steps
- [Architecture](architecture.md) - System design and components
- [Query Lifecycle](query-lifecycle.md) - How queries flow through the system
- [Economic Model](economic-model.md) - Bonds, rewards, and incentives
- [Protocol Configuration](protocol-configuration.md) - Global settings and governance
- [Resolvers](resolvers.md) - Dispute resolution system
- [Callbacks](callbacks.md) - Event notification system
- [API Reference](api-reference.md) - Function documentation
- [Integration Guide](integration-guide.md) - How to use Reef in your project
- [Security Considerations](security-considerations.md) - Important safety information
- [Troubleshooting](troubleshooting.md) - Common issues and solutions

## Example Use Cases

**Price Feeds**: Get current market prices for DeFi protocols

**Sports Results**: Settle prediction markets based on game outcomes

**Weather Data**: Insurance contracts triggered by weather conditions

**Cross-chain Verification**: Confirm events that happened on other blockchains

**Web API Data**: Bring any REST API data on-chain with proper incentives

## Community

Reef is designed to be a public good for the Sui ecosystem. The protocol is governed through economic parameters that can be adjusted based on real-world usage patterns.

For questions, issues, or contributions, please check the main project repository.