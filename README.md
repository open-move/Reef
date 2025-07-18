# Reef Oracle

An optimistic oracle system for the Sui blockchain that allows smart contracts to request off-chain data and assume submitted claims are correct unless challenged.

## How It Works

The core flow involves four steps:

1. **Submit Query**: A creator submits a query on-chain with a bond amount and liveness period
2. **Submit Claim**: A submitter provides a claim along with a matching bond
3. **Challenge Claim**: Anyone can challenge the submitted claim during the liveness window by posting an equal bond
4. **Resolve Query**: If unchallenged, the claim is accepted after the liveness period. If challenged, a resolver determines the correct claim and distributes bonds to the winner.

### Flow Diagram

```
┌─────────────┐
│   Creator   │
│submit_query │──┐
└─────────────┘  │
                 ▼
┌─────────────────────────────┐
│        Requested            │
│   Query created with bond   │
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
                 │                 ▼                   ▼
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
                 └─▶│ resolve_query() determines  │
                    │ winner by comparing         │
                    │ resolver_claim to           │
                    │ submitted_claim             │
                    └─────────────────────────────┘
```

### Economic Flows

**Unchallenged Resolution:**
```
Creator Bond + Submitter Bond + Rewards → Submitter
(after liveness_ms expires)
```

**Challenged Resolution:**
```
If resolver_claim matches submitted_claim:
Creator Bond + Submitter Bond + Challenger Bond + Rewards → Submitter

If resolver_claim differs from submitted_claim:
Creator Bond + Submitter Bond + Challenger Bond → Challenger
Rewards → Creator (refunded)
```

## Architecture

### Config Module
Manages global system settings including whitelisted resolver types, allowed bond/reward tokens, and minimum bond amounts per token type.

### Claim Module  
Provides type-safe data representation with support for Boolean, Integer, String, Enum, and Bytes claim types. Uses BCS serialization for efficiency.

### Query Module
Handles the complete query lifecycle from creation through resolution. Manages bonds, rewards, and state transitions.

### Resolver Module
Framework for pluggable dispute resolution mechanisms. Different resolver types can implement custom arbitration logic while the core oracle validates proofs and handles payouts.

## Economic Model

### Bonds
- Creators post bonds when creating queries
- Submitters must post equal bonds when providing answers  
- Challengers must post equal bonds when disputing answers
- Winners receive all bonds from losing parties

### Rewards
Optional rewards can be added to queries to incentivize participation. Rewards go to submitters when their answers are accepted, or back to creators if answers are successfully challenged.

### Resolution
- **Unchallenged queries**: Submitter automatically wins after liveness period expires
- **Challenged queries**: Resolver provides the correct claim
  - If resolver claim matches submitted claim: submitter wins all bonds + rewards
  - If resolver claim differs: challenger wins all bonds, creator gets rewards back

## Key Features

- **Optimistic**: Assumes answers are valid unless disputed, minimizing on-chain activity
- **Type-safe**: Strongly typed claims eliminate ambiguity 
- **Flexible**: Configurable liveness periods, bond amounts, and resolver types
- **Economic security**: Bond requirements create strong incentives for honest behavior
- **Modular**: Easy to add new resolver types and token support

## Technical Details

### State Machine
Queries progress through defined states:
- `QueryStatus::Requested`: Query created, awaiting claim submission
- `QueryStatus::Submitted`: Claim submitted, liveness period active
- `QueryStatus::Challenged`: Dispute initiated, awaiting resolution
- `QueryStatus::Resolved`: Final state with determined outcome

### Bond Management
Bonds are stored in dynamic fields using `BondKey()` and `Balance<T>` objects for gas efficiency. The system supports multiple token types with configurable minimum amounts per `TypeName`.

### Claim Validation
Claims are BCS-encoded with type validation at submission. The resolver comparison uses exact data and type matching:
```
submitted_claim.data() == resolver_claim.data() && 
submitted_claim.type_() == resolver_claim.type_()
```

### Timing Mechanics
- Liveness periods are specified in `liveness_ms` (milliseconds)
- Challenges must occur before `liveness_ms` expires via `challenge_claim()`
- Resolution can happen immediately after `liveness_ms` expires for unchallenged queries

### Resolver Framework
Resolvers are validated by `TypeName` matching against whitelisted proof types. Each resolver implementation provides:
- Custom proof object type
- Resolution logic for determining correct claims
- Integration with core oracle for bond distribution

## Usage

The oracle is designed for use cases requiring periodic data updates where the cost of disputes is acceptable, such as:

- Price feeds for DeFi protocols
- Sports and prediction market outcomes  
- Weather data and IoT sensor readings
- Cross-chain state verification

The optimistic model works best when the data source is generally reliable and disputes are rare, as the economic cost of challenging false data provides the security guarantee.

## Implementation Notes

### Gas Optimization
- Uses BCS serialization for claim data
- Dynamic fields for bond storage
- Minimal state transitions
- Batch operations where possible

### Extensibility
New resolver types can be added by:
1. Creating a unique proof type
2. Getting it whitelisted via governance
3. Implementing resolution logic
4. Calling `resolve_query()` with the proof