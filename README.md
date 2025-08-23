# Reef Oracle

An optimistic oracle system for Sui that allows smart contracts to request off-chain data and assume submitted claims are correct unless challenged.

## Key Features

- **Topic Whitelisting**: Only approved topics can be used for queries
- **Auto-Expiration**: Queries have hard deadlines
- **Economic Security**: Bond requirements and winner-takes-all settlement punish dishonest behavior
- **Modular Resolvers**: Pluggable dispute resolution systems
- **Callback System**: Optional notifications for query lifecycle events

## How It Works

1. **Create Query**: A creator creates a query on-chain with bond amount, liveness period, and expiration
2. **Submit Claim**: A submitter provides a claim along with the required bond
3. **Challenge Claim**: Anyone can challenge the submitted claim during the liveness period by posting an equal bond. This deducts a resolution fee from the bond pool and may trigger immediate reward transfers
4. **Settle Query**: If unchallenged, the claim is accepted after the liveness period. If challenged, a resolver determines the correct claim and distributes bonds to the winner.

### Flow Diagram

```
Creator ──create_query──▶ Created ──submit_claim──▶ Submitted
                            │                         │
                            │                         ├── No Challenge
                            ▼                         │
                         Expired ◀─── liveness ────────┤
                            │        expires          │
                            │                         ▼
                            └──── expires_at_ms ──▶ Challenged ──▶ Resolved ──▶ Settled
```

### Economic Model

**Unchallenged**: Submitter gets their bond back + any rewards

**Challenged**: Winner gets both bonds (minus resolution fee) + rewards. Loser loses their bond. The resolution fee goes to the resolver for arbitration.

## Architecture

- **Protocol Module**: Global config, topic whitelist, fee structure and resolution parameters
- **Query Lifecycle**: Created → Submitted → Challenged → Resolved → Settled → Expired
- **Resolver Framework**: Custom dispute resolution with witness-based authorization
- **Data Format**: Raw byte vectors (`vector<u8>`) for maximum flexibility

## Usage

Designed for use cases where:

- Data is generally reliable (disputes are rare)
- Economic cost of challenging creates sufficient deterrent
- Speed matters more than immediate finality

Examples: price feeds, sports outcomes, weather data, cross-chain verification.

## Getting Started

### Building

```bash
cd packages/reef
sui move build
```

### Testing

```bash
sui move test
```

## License

MIT License - see [LICENSE](LICENSE) file for details.
