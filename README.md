# Reef Oracle

An optimistic oracle system for Sui that allows smart contracts to request off-chain data and assume submitted claims are correct unless challenged.

## How It Works

The core flow involves four steps:

1. **Create Query**: A creator creates a query on-chain with its config (bond amount, liveness period, expiration)
2. **Submit Claim**: A submitter provides a claim along with the required bond
3. **Challenge Claim**: Anyone can challenge the submitted claim during the liveness window by posting an equal bond
4. **Settle Query**: If unchallenged, the claim is accepted after the liveness period. If challenged, a resolver determines the correct claim and distributes bonds to the winner.

### Flow Diagram

```
┌─────────────┐
│   Creator   │
│create_query │──┐
└─────────────┘  │
                 ▼
┌─────────────────────────────┐
│         Created             │
│   Query created with fee    │
│   paid and config    │
└─────────────────────────────┘
                 │
                 ▼
┌─────────────┐  │  ┌─────────────────────────────┐
│  Submitter  │  │  │        Submitted            │
│submit_claim │──┼─▶│  Claim + bond posted,       │
└─────────────┘  │  │   liveness period starts    │
                 │  └─────────────────────────────┘
                 │                 │
                 │                 ├── No Challenge ──┐
                 │                 │                  │
                 │                 ▼                  ▼
┌─────────────┐  │  ┌─────────────────────────────┐   │
│ Challenger  │  │  │        Challenged           │   │
│challenge_   │──┼─▶│   Dispute initiated,        │   │
│claim        │  │  │  equal bond required        │   │
└─────────────┘  │  └─────────────────────────────┘   │
                 │                 │                  │
                 │                 ▼                  │
                 │  ┌─────────────────────────────┐   │
                 │  │        Resolved             │◀──┘
                 │  │                             │
                 └─▶│ settle_query() determines   │
                    │ winner by comparing         │
                    │ resolved_claim to           │
                    │ submitted_claim             │
                    └─────────────────────────────┘
                                   │
                                   ▼
                    ┌─────────────────────────────┐
                    │        Settled              │
                    │                             │
                    │ Bonds distributed,          │
                    │ query finalized             │
                    └─────────────────────────────┘
```

### Economic Flows

**Unchallenged Settlement:**
```
Submitter Bond → Submitter (returned)
Additional Rewards (if any) → Submitter
(after liveness_ms expires or query expires)
```

**Challenged Settlement:**
```
If resolved_claim matches submitted_claim:
- Submitter Bond + Challenger Bond (minus burn) → Submitter
- Burned portion → Protocol treasury
- Rewards (if any) → Submitter

If resolved_claim differs from submitted_claim:  
- Submitter Bond + Challenger Bond (minus burn) → Challenger
- Burned portion → Protocol treasury
- Rewards (if any) → Creator's refund address (if specified)
```

**Burn Mechanism:**
- Default 50% burn rate (configurable)
- Applied to losing party's portion of bond pool
- Effective burn rate: ~25% of total bonds (50% of half the pool)

## Architecture

### Protocol Module
Manages global system settings including:
- Topic whitelisting (allowed_topics Table)
- Authorized resolver types and coin types  
- Economic parameters (burn rates, minimum bonds, fees)
- Treasury management (collecting fees and burned bonds)

### Query Lifecycle
Queries progress through defined states:
- `Created`: Query created, awaiting claim submission
- `Submitted`: Claim submitted, challenge period active
- `Challenged`: Challenge made, awaiting resolution
- `Resolved`: Resolution applied, ready for settlement
- `Settled`: Final state, bonds distributed
- `Expired`: Auto-settled due to time limits

### Data Handling
Claims are simple byte vectors (`vector<u8>`) allowing maximum flexibility. Clients handle their own data encoding/decoding - oracle only compares bytes for equality.

### Resolver Framework
Framework for pluggable dispute resolution mechanisms. Different resolver types can implement custom arbitration logic while the core oracle validates proofs and handles payouts.

### Callback System
Optional callback notifications for query creators:
- `ClaimSubmitted`: Notification when someone submits a claim
- `ClaimChallenged`: Notification when someone challenges a claim  
- `QuerySettled`: Notification when query reaches final state

Callbacks use witness pattern for verification to prevent spoofing.

## Key Features

### Topic Whitelisting
- Protocol maintains `allowed_topics` Table for content moderation
- Only whitelisted topics can be used for new queries
- Governance can add/remove allowed topics

### Auto-Expiration
- Queries have `expires_at_ms` deadline for automatic settlement
- Prevents queries from remaining open indefinitely
- Must allow sufficient time for challenge period

### Economic Security
- Bond requirements create strong incentives for honest behavior
- Configurable burn rates punish wrong parties
- Protocol fees for query creation prevent spam

### Witness Pattern Integration
- Query creators must provide witness for authorization
- Enables proper integration with other smart contracts
- Prevents unauthorized query creation

## Economic Model

### Bonds
- Submitters must post bonds when providing claims
- Challengers must post equal bonds when disputing claims  
- Winners receive bonds from losing parties (minus burn)
- No upfront creator bonds required

### Fees
- Protocol fees required for query creation (prevents spam)
- Fees go to protocol treasury
- Separate from bonds used for economic security

### Rewards
Optional rewards can be added to queries to incentivize participation:
- Go to submitters when their claims are accepted
- Returned to creator's refund address if claims are successfully challenged
- Completely separate from bond mechanism

### Burn Mechanism
- Configurable burn rate (default 50% in basis points)
- Applied to losing party's portion of total bond pool
- Burned funds go to protocol treasury
- Creates deadweight loss to punish dishonest behavior

## Technical Details

### State Machine
```
Created ──submit_claim──▶ Submitted ──challenge_claim──▶ Challenged
   │                         │                             │
   │                         │                             │
   ▼                         ▼                             ▼
Expired ◀────────── liveness expires              Resolved ──settle_query──▶ Settled
   │                                                        │
   │                                                        │
   └──────────── expires_at_ms timeout ──────────────────────┘
```

### Bond Management
Bonds stored in dynamic fields using `BondKey()` and `Balance<T>` for gas efficiency. System supports multiple token types with configurable minimum amounts per `TypeName`.

### Timing Mechanics
- **Liveness periods**: Time challengers have to dispute claims (`liveness_ms`)
- **Expiration deadlines**: Hard deadline for query auto-settlement (`expires_at_ms`)
- **Submission delays**: Minimum time after creation before claims accepted (`minimum_submission_delay_ms`)

### Resolver Framework
Resolvers validated by `TypeName` matching against authorized proof types. Each resolver provides:
- Custom proof object type for authorization
- Resolution logic determining correct claims
- Integration with core oracle for bond distribution

### Data Comparison
Claims compared as raw byte vectors:
```move
submitted_claim == resolved_claim  // Direct equality check
```

## Usage

The oracle is designed for use cases requiring periodic data updates where the cost of disputes is acceptable:

- Price feeds for DeFi protocols
- Sports and prediction market outcomes  
- Weather data and IoT sensor readings
- Cross-chain state verification
- Any scenario requiring trusted off-chain data

The optimistic model works best when:
1. Data source is generally reliable (disputes are rare)
2. Economic cost of challenging creates sufficient deterrent
3. Speed of settlement (when unchallenged) is more important than immediate finality

## Implementation Notes

### Gas Optimization
- Uses dynamic fields for bond storage to minimize gas costs
- Minimal state transitions and efficient data structures
- BCS serialization for claim data

### Security Features
- Witness pattern prevents unauthorized query creation
- Topic whitelisting prevents spam and inappropriate content
- Economic incentives align participant behavior
- Time-based safeguards prevent manipulation

### Extensibility
New resolver types can be added by:
1. Creating proof type within resolver implementation module
2. Getting resolver type authorized via protocol governance  
3. Implementing custom resolution logic
4. Using `make_resolution()` with proper proof

New features can be added while maintaining backward compatibility through the modular architecture.

## Getting Started

### Prerequisites
- [Sui CLI](https://docs.sui.io/guides/developer/getting-started/sui-install) installed

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

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.