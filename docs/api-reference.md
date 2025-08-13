# API Reference

This document provides comprehensive reference documentation for all public functions in the Reef oracle system.

## reef::reef Module

The core module containing query lifecycle management.

### create_query

Creates a new query asking for specific data.

```move
public fun create_query<CoinType, Witness: drop>(
    protocol: &mut Protocol,
    resolver: &Resolver,
    _witness: Witness,
    fee: Coin<CoinType>,
    config: QueryConfig,
    topic: vector<u8>,
    metadata: vector<u8>,
    timestamp_ms: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): Query
```

**Type Parameters**:
- `CoinType`: Token type for fees and bonds
- `Witness`: Authorization witness for the creator

**Parameters**:
- `protocol`: Global protocol configuration
- `resolver`: Resolver that can handle disputes for this query
- `_witness`: Witness proving authorization to create queries
- `fee`: Payment for protocol fee (exact amount required)
- `config`: Query-specific configuration
- `topic`: Short identifier for the data being requested
- `metadata`: Detailed description and resolution criteria
- `timestamp_ms`: Historical timestamp for historical queries (none for real-time)
- `clock`: Sui clock object for timing
- `ctx`: Transaction context

**Returns**: New `Query` object (caller should share it)

**Constraints**:
- Topic must be in protocol whitelist
- CoinType must be in protocol whitelist  
- Fee amount must match protocol requirement
- Expiration must be after current time + liveness period
- Topic and metadata must not exceed size limits

### share_query

Shares a query as a global object.

```move
public fun share_query(query: Query)
```

**Parameters**:
- `query`: Query object to share

### submit_claim

Submits a claim to an existing query.

```move
public fun submit_claim<CoinType>(
    query: &mut Query,
    protocol: &Protocol,
    claim: vector<u8>,
    bond: Coin<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
)
```

**Parameters**:
- `query`: Target query object
- `protocol`: Global protocol configuration
- `claim`: The submitted answer/claim data
- `bond`: Bond payment (must match query's required amount)
- `clock`: Sui clock for timing
- `ctx`: Transaction context

**Constraints**:
- Query must be in Created status
- Must wait for minimum submission delay
- Bond amount must match query configuration
- CoinType must match query configuration

### challenge_claim

Challenges a submitted claim during the liveness period.

```move
public fun challenge_claim<CoinType>(
    query: &mut Query,
    bond: Coin<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
): ChallengeRequest<CoinType>
```

**Parameters**:
- `query`: Query with claim to challenge
- `bond`: Challenge bond (must equal original bond)
- `clock`: Sui clock for timing
- `ctx`: Transaction context

**Returns**: `ChallengeRequest` hot potato that must be consumed by resolver

**Constraints**:
- Query must be in Submitted status
- Cannot challenge your own claim
- Must challenge before liveness period expires
- Bond amount must match original submitter's bond

### settle_query

Settles a query and distributes bonds/rewards.

```move
public fun settle_query<CoinType>(
    query: &mut Query,
    protocol: &mut Protocol,
    resolution: Option<Resolution>,
    clock: &Clock,
    ctx: &mut TxContext,
)
```

**Parameters**:
- `query`: Query to settle
- `protocol`: Global protocol configuration
- `resolution`: Resolution decision (none for unchallenged queries)
- `clock`: Sui clock for timing
- `ctx`: Transaction context

**Constraints**:
- Query must be in Resolved or Expired status
- If resolution provided, query must have been challenged
- Resolution must be for the correct query

### Callback Variants

#### submit_claim_with_callback

```move
public fun submit_claim_with_callback<CoinType>(
    protocol: &Protocol,
    query: &mut Query,
    claim: vector<u8>,
    bond: Coin<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
): callback::ClaimSubmitted
```

Same as `submit_claim` but returns a callback notification.

#### challenge_claim_with_callback

```move
public fun challenge_claim_with_callback<CoinType>(
    query: &mut Query,
    bond: Coin<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
): (ChallengeRequest<CoinType>, callback::ClaimChallenged)
```

Same as `challenge_claim` but also returns a callback notification.

#### settle_query_with_callback

```move
public fun settle_query_with_callback<CoinType>(
    protocol: &mut Protocol,
    query: &mut Query,
    resolution: Option<Resolution>,
    clock: &Clock,
    ctx: &mut TxContext,
): callback::QuerySettled
```

Same as `settle_query` but returns a callback notification.

### Query Configuration

#### create_query_config

Creates a query configuration object.

```move
public fun create_query_config(
    bond: u64,
    liveness_ms_maybe: Option<u64>,
    expires_at_ms: u64,
    refund_address: Option<address>,
): QueryConfig
```

**Parameters**:
- `bond`: Required bond amount for claims
- `liveness_ms_maybe`: Challenge window duration (none for default)
- `expires_at_ms`: Hard expiration deadline
- `refund_address`: Where to send rewards if query is challenged

### Query Management

#### add_reward

Adds optional rewards to incentivize query participation.

```move
public fun add_reward<RewardType, Witness: drop>(
    query: &mut Query,
    _: &Witness,
    reward: Coin<RewardType>,
    clock: &Clock,
)
```

**Parameters**:
- `query`: Query to add reward to
- `_`: Creator witness (must match query creator)
- `reward`: Reward coin to add
- `clock`: Sui clock for timing

**Constraints**:
- Query must be in Created status
- Only query creator can add rewards

#### set_refund_address

Updates the refund address for query rewards.

```move
public fun set_refund_address<Witness: drop>(
    query: &mut Query,
    _: &Witness,
    refund_address: Option<address>,
    clock: &Clock,
)
```

**Parameters**:
- `query`: Query to modify
- `_`: Creator witness (must match query creator)
- `refund_address`: New refund address (none to remove)
- `clock`: Sui clock for timing

**Constraints**:
- Query must be in Created status
- Only query creator can modify refund address

### Query Status and Information

#### status

Returns the current status of a query.

```move
public fun status(query: &Query, clock: &Clock): QueryStatus
```

**Returns**: Current query status based on time and state

#### Getter Functions

```move
public fun topic(query: &Query): vector<u8>
public fun metadata(query: &Query): vector<u8>
public fun created_at_ms(query: &Query): u64
public fun coin_type(query: &Query): TypeName
public fun submitter(query: &Query): Option<address>
public fun submitted_claim(query: &Query): Option<vector<u8>>
public fun submitted_at_ms(query: &Query): Option<u64>
public fun challenger(query: &Query): Option<address>
public fun challenged_at_ms(query: &Query): Option<u64>
public fun resolved_claim(query: &Query): Option<vector<u8>>
public fun resolver_witness(query: &Query): TypeName
public fun expires_at_ms(query: &Query): u64
public fun is_expired(query: &Query, clock: &Clock): bool
public fun is_settled(query: &Query): bool
```

#### Bond and Reward Amounts

```move
public fun bond_amount<CoinType>(query: &Query): u64
public fun reward_amount<RewardType>(query: &Query): u64
```

Returns current amounts stored in dynamic fields.

#### Status Constants

```move
public fun query_status_created(): QueryStatus
public fun query_status_submitted(): QueryStatus
public fun query_status_challenged(): QueryStatus
public fun query_status_resolved(): QueryStatus
public fun query_status_settled(): QueryStatus
public fun query_status_expired(): QueryStatus
```

## reef::protocol Module

Global protocol configuration and governance.

### initialize

Initializes the protocol with default settings.

```move
public fun initialize(publisher: Publisher, ctx: &mut TxContext): (Protocol, ProtocolCap)
```

**Parameters**:
- `publisher`: Publisher object from module initialization
- `ctx`: Transaction context

**Returns**: Protocol object and governance capability

**Constraints**:
- Publisher must be from PROTOCOL module
- Can only be called once (publisher is consumed)

### share_protocol

Shares protocol as global object.

```move
public fun share_protocol(protocol: Protocol)
```

### Economic Configuration

#### set_burn_rate

```move
public fun set_burn_rate(protocol: &mut Protocol, _: &ProtocolCap, burn_rate_bps: u64)
```

Sets percentage of losing bonds to burn (0-10000 basis points).

#### set_minimum_liveness

```move
public fun set_minimum_liveness(
    protocol: &mut Protocol,
    _: &ProtocolCap,
    minimum_liveness_ms: u64,
)
```

Sets minimum challenge window duration.

#### set_min_submission_delay

```move
public fun set_min_submission_delay(
    protocol: &mut Protocol,
    _: &ProtocolCap,
    min_submission_delay_ms: u64,
)
```

Sets delay before claims can be submitted after query creation.

#### set_fee_amount

```move
public fun set_fee_amount(
    protocol: &mut Protocol,
    _: &ProtocolCap,
    fee_type: TypeName,
    fee_amount: u64,
)
```

Sets protocol fee for specific token type.

#### set_minimum_bond

```move
public fun set_minimum_bond(
    protocol: &mut Protocol,
    _: &ProtocolCap,
    coin_type: TypeName,
    minimum_bond: u64,
)
```

Sets minimum bond requirement for specific token type.

### Whitelist Management

#### add_allowed_coin_type

```move
public fun add_allowed_coin_type(protocol: &mut Protocol, _: &ProtocolCap, reward_type: TypeName)
```

Adds token type to whitelist for bonds/fees.

#### remove_allowed_coin_type

```move
public fun remove_allowed_coin_type(
    protocol: &mut Protocol,
    _: &ProtocolCap,
    reward_type: TypeName,
)
```

Removes token type from whitelist.

#### add_allowed_topic

```move
public fun add_allowed_topic(protocol: &mut Protocol, _: &ProtocolCap, topic: vector<u8>)
```

Adds topic to approved list.

#### remove_allowed_topic

```move
public fun remove_allowed_topic(protocol: &mut Protocol, _: &ProtocolCap, topic: vector<u8>)
```

Removes topic from approved list.

### Protocol Information

```move
public fun is_allowed_coin_type(protocol: &Protocol, reward_type: TypeName): bool
public fun is_topic_allowed(protocol: &Protocol, topic: &vector<u8>): bool
public fun minimum_bond(protocol: &Protocol, coin_type: TypeName): u64
public fun fee_amount(protocol: &Protocol, coin_type: TypeName): u64
public fun minimum_liveness_ms(protocol: &Protocol): u64
public fun burn_rate_bps(protocol: &Protocol): u64
public fun minimum_submission_delay_ms(protocol: &Protocol): u64
```

### Treasury Functions

These functions are package-private and called internally:

```move
public(package) fun collect_fee<CoinType>(protocol: &mut Protocol, fee: Coin<CoinType>)
public(package) fun collect_burned_bond<CoinType>(protocol: &mut Protocol, bond: Coin<CoinType>)
```

## reef::resolver Module

Dispute resolution framework.

### create

Creates a new resolver.

```move
public fun create<Witness: drop>(_witness: Witness, publisher: Publisher, ctx: &mut TxContext): Resolver
```

**Parameters**:
- `_witness`: Authorization witness for this resolver
- `publisher`: Publisher from resolver module
- `ctx`: Transaction context

**Returns**: New resolver object (starts disabled)

**Constraints**:
- Publisher must be from same module as witness type
- Resolver must be enabled by protocol governance before use

### share_resolver

Shares resolver as global object.

```move
public fun share_resolver(resolver: Resolver)
```

### Resolver Management

#### enable

```move
public fun enable(resolver: &mut Resolver, _: &ProtocolCap)
```

Enables resolver for use in queries.

#### disable

```move
public fun disable(resolver: &mut Resolver, _: &ProtocolCap)
```

Disables resolver (prevents new resolutions).

### Resolution Creation

#### make_resolution

```move
public fun make_resolution<Witness: drop>(
    resolver: &Resolver,
    _witness: Witness,
    query_id: ID,
    claim: vector<u8>,
    clock: &Clock,
): Resolution
```

**Parameters**:
- `resolver`: Resolver object
- `_witness`: Authorization witness (must match resolver)
- `query_id`: ID of query being resolved
- `claim`: Correct claim as determined by resolver
- `clock`: Sui clock for timestamp

**Returns**: Resolution object to apply to query

**Constraints**:
- Resolver must be enabled
- Witness must match resolver's expected type

### Challenge Request Handling

#### unpack_challenge_request

```move
public fun unpack_challenge_request<CoinType, Witness: drop>(
    request: ChallengeRequest<CoinType>,
    _witness: Witness,
): (ID, Balance<CoinType>, address, u64, TypeName)
```

Unpacks a challenge request for processing by resolver.

**Returns**: (query_id, fee_balance, challenger, timestamp, witness_type)

**Constraints**:
- Witness must match the resolver type expected by the challenge

### Resolver Information

```move
public fun is_enabled(resolver: &Resolver): bool
public fun witness_type(resolver: &Resolver): TypeName
```

### Resolution Information

```move
public fun resolution_query_id(resolution: &Resolution): ID
public fun resolution_claim(resolution: &Resolution): vector<u8>
public fun resolution_resolved_at_ms(resolution: &Resolution): u64
public fun resolution_witness_type(resolution: &Resolution): TypeName
```

## reef::callback Module

Event notification system for query creators.

### Callback Verification

#### verify_claim_submitted

```move
public fun verify_claim_submitted<T: drop>(callback: ClaimSubmitted, _: T)
```

Verifies and consumes a claim submission callback.

**Constraints**:
- Callback must have been created for queries using witness type T

#### verify_claim_challenged

```move
public fun verify_claim_challenged<T: drop>(callback: ClaimChallenged, _: T)
```

Verifies and consumes a claim challenge callback.

#### verify_query_settled

```move
public fun verify_query_settled<T: drop>(callback: QuerySettled, _: T)
```

Verifies and consumes a query settlement callback.

## Error Codes

### reef::reef Errors

- `EInsufficientBond` (0): Bond amount doesn't match requirement
- `EInvalidQueryStatus` (1): Query not in correct status for operation
- `ELivenessNotExpired` (2): Still within challenge period
- `ENotAuthorized` (3): Caller lacks required permissions
- `EInvalidCoinType` (4): Coin type not allowed or doesn't match
- `EInvalidLiveness` (5): Liveness period doesn't meet requirements
- `EEmptyTopic` (6): Topic cannot be empty
- `EEmptyMetadata` (7): Metadata cannot be empty
- `EClaimNotSubmitted` (8): No claim exists to challenge
- `EInvalidFeeAmount` (9): Fee doesn't match protocol requirement
- `EWrongQueryResolution` (10): Resolution for different query
- `EWrongResolverType` (11): Resolution from wrong resolver type
- `ECannotChallengeSelf` (12): Cannot challenge own claim
- `EStaleResolution` (13): Resolution older than challenge
- `ETooLongTopic` (14): Topic exceeds maximum length
- `ETooLongMetadata` (15): Metadata exceeds maximum length
- `EUnauthorizedTopic` (16): Topic not in whitelist
- `EInvalidExpiration` (17): Expiration time in the past
- `EExpirationTooEarly` (18): Expiration doesn't allow liveness period
- `EInvalidWitness` (19): Witness type doesn't match expected

### reef::protocol Errors

- `EInvalidPublisher` (0): Publisher doesn't match module
- `EBondTypeNotAllowed` (1): Coin type not whitelisted
- `EInvalidBurnRate` (2): Burn rate exceeds maximum (100%)

### reef::resolver Errors

- `EInvalidPublisher` (0): Publisher doesn't match witness module
- `EInvalidWitnessType` (1): Witness type mismatch
- `EResolverDisabled` (2): Resolver not enabled for use

### reef::callback Errors

- `EInvalidCallbackType` (0): Callback creator witness mismatch

## Usage Examples

### Basic Query Creation

```move
let config = reef::create_query_config(
    1_000_000_000,        // 1 SUI bond
    option::none(),       // Default liveness
    clock.timestamp_ms() + 86400000, // 24h expiry
    option::none()        // No refund address
);

let fee = coin::mint_for_testing<SUI>(1_000_000, ctx);
let query = reef::create_query<SUI, MyWitness>(
    &mut protocol,
    &resolver,
    MyWitness {},
    fee,
    config,
    b"BTC/USD",
    b"Bitcoin price in USD",
    option::none(),
    &clock,
    ctx
);
query.share();
```

### Complete Workflow

```move
// 1. Submit claim
let bond = coin::mint_for_testing<SUI>(1_000_000_000, ctx);
reef::submit_claim<SUI>(&mut query, &protocol, claim_data, bond, &clock, ctx);

// 2. Challenge (optional)
let challenge_bond = coin::mint_for_testing<SUI>(1_000_000_000, ctx);
let challenge = reef::challenge_claim<SUI>(&mut query, challenge_bond, &clock, ctx);

// 3. Resolve challenge (by resolver)
let resolution = resolver::make_resolution<ResolverWitness>(
    &resolver, ResolverWitness {}, query.id.to_inner(), correct_claim, &clock
);

// 4. Settle query
reef::settle_query<SUI>(&mut query, &mut protocol, option::some(resolution), &clock, ctx);
```

This API reference provides the foundation for integrating with Reef oracle system. For implementation patterns and best practices, see the [Integration Guide](integration-guide.md).