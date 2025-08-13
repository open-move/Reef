# Reef Oracle Architecture

Reef is designed as a modular system where different components handle specific responsibilities while working together to create a secure, efficient oracle network.

## Design Principles

**Optimistic by Default**: The system assumes most data is correct and only investigates when someone stakes money on a disagreement.

**Economic Security**: Security comes from economic incentives rather than cryptographic proofs or trusted parties.

**Modular Design**: Components can be upgraded or replaced without affecting the entire system.

**Witness-based Authorization**: Type safety ensures only authorized entities can perform sensitive operations.

**Flexible Data Encoding**: Raw byte vectors support any data type while keeping gas costs low.

## System Overview

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Protocol      │    │      Reef       │    │    Resolver     │
│   (Config)      │◄───┤   (Core Logic)  ├───►│   (Disputes)    │
└─────────────────┘    └─────────────────┘    └─────────────────┘
                                │
                                ▼
                       ┌─────────────────┐
                       │    Callback     │
                       │ (Notifications) │
                       └─────────────────┘
```

## Core Modules

### Protocol Module (`protocol.move`)

The protocol module acts as the global configuration center and treasury for the oracle system.

**Key Responsibilities:**
- Economic parameters (burn rates, minimum bonds, fees)
- Topic and coin type whitelists
- Treasury management (collecting fees and burned bonds)
- Governance through ProtocolCap

**Key Structures:**
```move
struct Protocol has key {
    burn_rate_bps: u64,           // Percentage of losing bonds to burn
    minimum_liveness_ms: u64,     // Minimum challenge window
    allowed_coin_types: VecSet<TypeName>,
    allowed_topics: Table<vector<u8>, bool>,
    fee_amounts: VecMap<TypeName, u64>,
    // ...
}
```

**Design Patterns:**
- Shared object for global access
- Capability-based governance
- Dynamic field storage for collected fees

### Reef Module (`reef.move`)

The reef module contains the core oracle logic and manages the complete query lifecycle.

**Key Responsibilities:**
- Query creation and lifecycle management
- Bond collection and distribution
- State transitions and validation
- Integration with resolvers and callbacks

**Key Structures:**
```move
struct Query has key {
    id: UID,
    topic: vector<u8>,
    config: QueryConfig,
    // State fields
    submitter: Option<address>,
    challenger: Option<address>,
    resolved_claim: Option<vector<u8>>,
    // ...
}

enum QueryStatus {
    Created,
    Submitted,
    Challenged,
    Resolved,
    Settled,
    Expired,
}
```

**Design Patterns:**
- State machine with clear transitions
- Dynamic fields for storing bonds and rewards
- Witness-based authorization for query creation
- Event emission for external monitoring

### Resolver Module (`resolver.move`)

The resolver module provides the framework for handling disputed queries through pluggable resolution mechanisms.

**Key Responsibilities:**
- Authorizing resolver types
- Creating and managing resolution decisions
- Validating resolution authenticity

**Key Structures:**
```move
struct Resolver has key {
    id: UID,
    is_enabled: bool,
    witness_type: TypeName,
}

struct Resolution has drop {
    query_id: ID,
    claim: vector<u8>,
    resolved_at_ms: u64,
    witness_type: TypeName,
}

struct ChallengeRequest<CoinType> {
    query_id: ID,
    challenger: address,
    // Hot potato pattern forces handling
}
```

**Design Patterns:**
- Hot potato pattern for challenge requests
- Witness-based resolver authorization
- Publisher verification for resolver creation

### Callback Module (`callback.move`)

The callback module enables query creators to receive notifications about important events.

**Key Responsibilities:**
- Event notification delivery
- Callback authenticity verification
- Creator witness validation

**Key Structures:**
```move
struct ClaimSubmitted {
    query_id: ID,
    submitter: address,
    claim: vector<u8>,
    creator_witness: TypeName,
}

struct ClaimChallenged {
    query_id: ID,
    challenger: address,
    creator_witness: TypeName,
}

struct QuerySettled {
    query_id: ID,
    claim: vector<u8>,
    creator_witness: TypeName,
}
```

**Design Patterns:**
- Witness verification prevents callback spoofing
- Lightweight notification structs
- Optional callback system

## Data Flow Architecture

### Query Creation Flow

1. Creator pays protocol fee upfront
2. Query object created with creator's witness type
3. Query shared as global object
4. Protocol validates topic and coin type whitelists
5. QueryCreated event emitted

### Claim Submission Flow

1. Submitter posts required bond
2. Bond stored in dynamic field on query
3. Query state updated to "Submitted"
4. Liveness period begins
5. ClaimSubmitted event emitted

### Challenge Flow

1. Challenger posts equal bond during liveness window
2. ChallengeRequest hot potato created
3. Challenge must be resolved by compatible resolver
4. Query state updated to "Challenged"
5. ClaimChallenged event emitted

### Resolution Flow

1. Authorized resolver creates Resolution object
2. Resolution applied to query with validation
3. Query state updated to "Resolved"
4. Settlement can proceed

### Settlement Flow

1. Bonds distributed based on outcome
2. Losing party's portion partially burned
3. Rewards distributed to winners
4. Query marked as settled
5. QueryResolved event emitted

## Security Architecture

### Authorization Layers

**Protocol Level**: ProtocolCap controls global parameters

**Resolver Level**: Publisher verification ensures resolver authenticity  

**Query Level**: Creator witness controls query modifications

**Challenge Level**: Hot potato pattern forces proper handling

### Economic Security

**Bond Symmetry**: Challengers must post equal bonds to submitters

**Burn Mechanism**: Losing parties have portions of their bonds burned

**Fee Structure**: Upfront fees prevent spam attacks

**Reward Alignment**: Winners receive both bonds plus any rewards

### Type Safety

**Witness Pattern**: Ensures only authorized code can perform sensitive operations

**Generic Constraints**: Type system prevents coin/reward type confusion

**Publisher Verification**: Resolvers must be published by correct modules

## Scalability Design

### Storage Efficiency

**Dynamic Fields**: Bonds and rewards stored off the main query object

**Raw Bytes**: Flexible encoding without type overhead

**Event-based Monitoring**: External systems can track activity without expensive queries

### Gas Optimization

**Minimal State**: Query objects contain only essential data

**Batch Operations**: Multiple rewards can be added in single transaction

**Optional Components**: Callbacks and rewards are opt-in features

## Extension Points

### Custom Resolvers

Create resolvers with custom logic by:
1. Defining unique witness type
2. Implementing resolution algorithm
3. Publishing resolver module
4. Getting witness type whitelisted

### Custom Data Types

Support new data formats by:
1. Implementing encoding/decoding functions
2. Using consistent byte representation
3. Documenting format for participants

### Custom Economic Models

Adjust incentives through:
1. Bond amount configuration
2. Liveness period tuning
3. Reward structure design
4. Burn rate adjustment

## Monitoring and Observability

### Event System

All major state changes emit events for external monitoring:
- Query lifecycle events
- Economic events (bond collection, distribution)
- Resolution events

### Query State Inspection

Real-time query state can be inspected:
- Current status and participants
- Bond and reward amounts
- Timing information
- Resolution history

### Protocol Metrics

Global protocol health monitoring:
- Total value locked in active queries
- Challenge rates and outcomes
- Fee collection and burn amounts
- Topic and resolver usage patterns

This architecture balances security, efficiency, and flexibility while maintaining the economic incentives that make optimistic oracles effective.