# Resolvers

When someone challenges a claim in Reef, the dispute must be resolved by an authorized resolver. This system provides flexibility in how disputes are handled while maintaining security through economic incentives and witness-based authorization.

## Resolver Framework

### Core Concept

Resolvers are separate modules that implement custom dispute resolution logic. The core Reef oracle simply validates that a resolution came from an authorized resolver and applies the economic consequences.

This separation allows for:
- **Pluggable resolution methods**: Different query types can use different resolvers
- **Specialized expertise**: Resolvers can focus on specific domains
- **Governance flexibility**: New resolver types can be added without changing core oracle
- **Security through diversity**: Multiple resolver options reduce single points of failure

### Resolver Structure

```move
struct Resolver has key {
    id: UID,
    is_enabled: bool,           // Can be disabled by protocol governance
    witness_type: TypeName,     // Authorization witness for this resolver
}
```

Each resolver is tied to a specific witness type that acts as its authorization key.

## Resolution Process

### Challenge Creation

When someone challenges a claim, they create a `ChallengeRequest` hot potato:

```move
let challenge_request = reef::challenge_claim<SUI>(
    &mut query,
    challenge_bond,
    &clock,
    ctx
);
// challenge_request must be consumed by a compatible resolver
```

The hot potato pattern ensures challenges can't be ignored - they must be handled by some resolver.

### Resolution Creation

Authorized resolvers can create resolution decisions:

```move
let resolution = resolver::make_resolution<AdminWitness>(
    &resolver,
    AdminWitness {},          // Witness proves authorization
    query_id,
    correct_claim,            // What the resolver determines is correct
    &clock
);
```

### Resolution Application

The resolution is applied to the original query:

```move
reef::settle_query<SUI>(
    &mut query,
    &mut protocol,
    option::some(resolution),  // Apply this resolution
    &clock,
    ctx
);
```

The core oracle validates the resolution and distributes bonds accordingly.

## Types of Resolvers

### Admin Resolver

**Use case**: Fast resolution by trusted administrator

**Characteristics**:
- Single authority makes decisions
- Fastest resolution time (minutes)
- Suitable for clear-cut cases
- Requires high trust in administrator

**Implementation pattern**:
```move
module resolver_admin {
    struct AdminWitness has drop {}
    
    public fun resolve_challenge<CoinType>(
        resolver: &Resolver,
        query_id: ID,
        correct_claim: vector<u8>,
        challenge_request: ChallengeRequest<CoinType>,
        clock: &Clock,
    ): Resolution {
        // Verify authorization
        let (_, _, _, _, _) = resolver::unpack_challenge_request(
            challenge_request, 
            AdminWitness {}
        );
        
        // Create resolution
        resolver::make_resolution(
            resolver,
            AdminWitness {},
            query_id,
            correct_claim,
            clock
        )
    }
}
```

### Committee Resolver

**Use case**: Multi-party decision making with voting

**Characteristics**:
- Multiple participants vote on resolution
- Medium resolution time (hours)
- More decentralized than admin
- Good balance of speed and decentralization

**Implementation approach**:
```move
module resolver_committee {
    struct CommitteeWitness has drop {}
    
    struct Committee has key {
        members: vector<address>,
        votes_required: u64,
        pending_votes: Table<ID, VoteState>,
    }
    
    public fun submit_vote(
        committee: &mut Committee,
        query_id: ID,
        vote: vector<u8>,
        ctx: &TxContext
    ) {
        // Verify committee member
        // Record vote
        // Check if threshold reached
        // Create resolution if complete
    }
}
```

### DAO Resolver

**Use case**: Token-weighted governance resolution

**Characteristics**:
- Token holders vote on resolution
- Slow resolution time (days)
- Most decentralized option
- Suitable for high-value or controversial queries

**Implementation considerations**:
- Voting power based on token holdings
- Quorum requirements for validity
- Time-locked voting periods
- Reward distribution to voters

### Oracle Resolver

**Use case**: Integration with existing oracle networks

**Characteristics**:
- Leverages external data sources
- Resolution time depends on external oracle
- Useful for price feeds and standard data
- Reduces dispute resolution burden

**Example integration**:
```move
module resolver_chainlink {
    struct ChainlinkWitness has drop {}
    
    public fun resolve_with_chainlink_data<CoinType>(
        resolver: &Resolver,
        query_id: ID,
        chainlink_feed: &PriceFeed,  // External oracle object
        challenge_request: ChallengeRequest<CoinType>,
        clock: &Clock,
    ): Resolution {
        let price_data = chainlink_feed.latest_answer();
        let claim_bytes = bcs::to_bytes(&price_data);
        
        resolver::make_resolution(
            resolver,
            ChainlinkWitness {},
            query_id,
            claim_bytes,
            clock
        )
    }
}
```

## Creating Custom Resolvers

### Step 1: Define Witness Type

Create a unique witness type for your resolver:

```move
module my_resolver {
    struct MyResolverWitness has drop {}
    
    // Your resolver logic here
}
```

### Step 2: Create Resolver Object

Deploy the resolver with proper authorization:

```move
public fun create_my_resolver(publisher: Publisher, ctx: &mut TxContext): Resolver {
    let resolver = resolver::create<MyResolverWitness>(
        MyResolverWitness {},
        publisher,  // Must be from same module as witness
        ctx
    );
    resolver
}
```

### Step 3: Implement Resolution Logic

Create functions that consume challenge requests and produce resolutions:

```move
public fun resolve_my_way<CoinType>(
    resolver: &Resolver,
    query_id: ID,
    my_resolution_data: MyData,
    challenge_request: ChallengeRequest<CoinType>,
    clock: &Clock,
) -> Resolution {
    // Unpack and validate challenge request
    let (id, fee, challenger, timestamp, witness_type) = 
        resolver::unpack_challenge_request(challenge_request, MyResolverWitness {});
    
    // Implement your resolution logic
    let correct_claim = determine_correct_answer(my_resolution_data);
    
    // Create resolution
    resolver::make_resolution<MyResolverWitness>(
        resolver,
        MyResolverWitness {},
        query_id,
        correct_claim,
        clock
    )
}
```

### Step 4: Enable Resolver

Get your resolver enabled by protocol governance:

```move
// Protocol admin enables your resolver
resolver::enable(&mut my_resolver, &protocol_cap);
```

### Step 5: Register for Queries

Queries specify which resolver type they want to use:

```move
// Query creator specifies your resolver when creating query
let query = reef::create_query<SUI, CreatorWitness>(
    &mut protocol,
    &my_resolver,  // Uses your resolver for disputes
    creator_witness,
    fee,
    config,
    topic,
    metadata,
    timestamp,
    &clock,
    ctx
);
```

## Resolution Validation

The core oracle performs several validation checks on resolutions:

### Authorization Checks
```move
// Resolver must be enabled
assert!(resolver.is_enabled, EResolverDisabled);

// Witness type must match resolver
assert!(resolver.witness_type == resolution.witness_type, EWrongResolverType);
```

### Timing Checks
```move
// Resolution must be after challenge
assert!(resolution.resolved_at_ms > query.challenged_at_ms, EStaleResolution);
```

### Identity Checks
```move
// Resolution must be for correct query
assert!(resolution.query_id == query.id, EWrongQueryResolution);
```

## Resolver Economics

### Resolver Incentives

Resolvers can earn fees through various mechanisms:

**Direct fees**: Charge participants for resolution services
```move
public fun resolve_with_fee<CoinType>(
    resolver_fee: Coin<CoinType>,  // Fee paid to resolver
    // ... other parameters
) {
    // Transfer fee to resolver operator
    transfer::public_transfer(resolver_fee, resolver_operator_address);
}
```

**Protocol revenue sharing**: Receive portion of burned bonds
```move
// Protocol could share burned bond revenue with active resolvers
// Implementation would be in protocol governance functions
```

**Token rewards**: Governance tokens or other incentives
```move
// Ecosystem incentives for resolver operators
// Could be implemented through separate reward programs
```

### Cost Considerations

Resolvers incur costs through:
- **Development**: Building and maintaining resolver logic
- **Operations**: Running infrastructure for resolution
- **Security**: Ensuring resolution integrity
- **Governance**: Participating in resolver governance

### Economic Balance

Successful resolvers balance:
- **Speed**: Faster resolution attracts more queries
- **Accuracy**: Wrong resolutions damage reputation
- **Cost**: Competitive pricing versus quality
- **Availability**: High uptime and reliability

## Best Practices

### For Resolver Developers

**Security first**:
- Carefully validate all inputs
- Use witness pattern correctly
- Test edge cases thoroughly
- Plan for malicious inputs

**Clear interfaces**:
- Document expected data formats
- Provide examples and guides
- Make integration straightforward
- Handle errors gracefully

**Economic sustainability**:
- Price services competitively
- Consider operational costs
- Plan for scaling challenges
- Build reputation gradually

### For Query Creators

**Choose appropriate resolvers**:
- Match resolver type to query complexity
- Consider resolution time requirements
- Factor in resolution costs
- Understand resolver reputation

**Provide clear context**:
- Include sufficient metadata for resolution
- Use standard data formats when possible
- Document expected answer formats
- Consider resolver expertise areas

### For Protocol Governance

**Resolver oversight**:
- Monitor resolver performance and accuracy
- Disable problematic resolvers quickly
- Encourage resolver diversity
- Support resolver ecosystem development

**Parameter tuning**:
- Adjust burn rates based on resolver costs
- Set appropriate fees for different resolver types
- Balance speed versus decentralization needs
- Monitor economic sustainability

The resolver system provides the flexibility needed to handle diverse dispute types while maintaining the economic security that makes optimistic oracles work effectively.