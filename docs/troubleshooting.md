# Troubleshooting

This guide helps you diagnose and resolve common issues when working with Reef oracle.

## Common Build and Setup Issues

### Build Failures

#### Issue: "Package not found" errors during build

```bash
error: package 'reef' not found
```

**Cause**: Move.toml configuration issues or missing dependencies.

**Solutions**:
1. Check Move.toml path configuration:
```toml
[package]
name = "YourProject"

[dependencies]
Reef = { local = "../packages/reef" }  # Verify this path exists
```

2. Ensure reef package builds independently:
```bash
cd packages/reef
sui move build
```

3. Check for circular dependencies in your project structure.

#### Issue: "Witness type not found" compilation errors

```bash
error: unbound type name 'MyWitness'
```

**Cause**: Witness type not properly defined or imported.

**Solutions**:
1. Define witness type in your module:
```move
module your_project::your_module {
    struct YourWitness has drop {}
}
```

2. Import witness from correct module:
```move
use your_project::your_module::YourWitness;
```

#### Issue: "Publisher verification failed" errors

```bash
error: EInvalidPublisher
```

**Cause**: Publisher doesn't match the expected module.

**Solutions**:
1. Ensure publisher comes from same package:
```move
fun init(otw: YOUR_MODULE, ctx: &mut TxContext) {
    let publisher = package::claim_and_keep(otw, ctx);
    // Use this publisher in resolver::create()
}
```

2. Check one-time witness type matches module name exactly.

## Runtime Errors

### Query Creation Issues

#### Issue: "Topic not allowed" (EUnauthorizedTopic)

**Cause**: Topic not in protocol whitelist.

**Diagnosis**:
```move
// Check if topic is allowed
let is_allowed = protocol.is_topic_allowed(&b"YOUR_TOPIC");
```

**Solutions**:
1. Use whitelisted topic:
```move
// Check current whitelisted topics in protocol
let allowed_topics = get_allowed_topics(&protocol);
```

2. Request topic to be added via governance:
```move
protocol::add_allowed_topic(&mut protocol, &protocol_cap, b"YOUR_TOPIC");
```

#### Issue: "Invalid coin type" (EInvalidCoinType)

**Cause**: Using non-whitelisted token for bonds/fees.

**Solutions**:
1. Check allowed coin types:
```move
let is_allowed = protocol.is_allowed_coin_type(type_name::get<YourCoin>());
```

2. Use whitelisted token type (usually SUI):
```move
reef::create_query<SUI, YourWitness>(/* ... */);
```

#### Issue: "Invalid fee amount" (EInvalidFeeAmount)

**Cause**: Fee amount doesn't match protocol requirement.

**Solutions**:
1. Check required fee amount:
```move
let required_fee = protocol.fee_amount(type_name::get<SUI>());
let fee_coin = coin::mint_for_testing<SUI>(required_fee, ctx);
```

2. Ensure exact amount is paid (no more, no less).

### Claim Submission Issues

#### Issue: "Invalid query status" for claim submission (EInvalidQueryStatus)

**Cause**: Query not in Created state or expired.

**Diagnosis**:
```move
let current_status = query.status(&clock);
// Should be QueryStatus::Created
```

**Solutions**:
1. Check query hasn't expired:
```move
if (query.is_expired(&clock)) {
    // Query expired, cannot submit claim
}
```

2. Ensure minimum submission delay has passed:
```move
let time_since_creation = clock.timestamp_ms() - query.created_at_ms();
let min_delay = protocol.minimum_submission_delay_ms();
assert!(time_since_creation >= min_delay, ESubmissionTooEarly);
```

#### Issue: "Insufficient bond" (EInsufficientBond)

**Cause**: Bond amount doesn't match query requirement.

**Solutions**:
1. Check required bond amount:
```move
// Get bond requirement from query config
let required_bond = query.config.bond;
let bond_coin = coin::mint_for_testing<SUI>(required_bond, ctx);
```

2. Ensure coin type matches:
```move
assert!(query.coin_type() == type_name::get<YourCoinType>(), EInvalidCoinType);
```

### Challenge Issues

#### Issue: "Cannot challenge self" (ECannotChallengeSelf)

**Cause**: Trying to challenge your own claim.

**Solutions**:
1. Use different address for challenging:
```move
// Check submitter before challenging
let submitter = query.submitter();
assert!(ctx.sender() != *submitter.borrow(), ECannotChallengeSelf);
```

#### Issue: "Liveness not expired" when challenging (ELivenessNotExpired)

**Cause**: Trying to challenge outside the liveness window.

**Solutions**:
1. Check if still within liveness period:
```move
let current_time = clock.timestamp_ms();
let submitted_time = *query.submitted_at_ms().borrow();
let liveness_end = submitted_time + query.config.liveness_ms;

if (current_time >= liveness_end) {
    // Liveness period expired, cannot challenge
}
```

### Settlement Issues

#### Issue: "Wrong query resolution" (EWrongQueryResolution)

**Cause**: Resolution object is for different query.

**Solutions**:
1. Ensure resolution query_id matches:
```move
assert!(resolution.query_id() == query.id.to_inner(), EWrongQueryResolution);
```

#### Issue: "Stale resolution" (EStaleResolution)

**Cause**: Resolution timestamp is before challenge timestamp.

**Solutions**:
1. Create resolution after challenge:
```move
let challenge_time = *query.challenged_at_ms().borrow();
// Resolution must be created after challenge_time
```

## Integration Issues

### Callback Problems

#### Issue: "Invalid callback type" (EInvalidCallbackType)

**Cause**: Callback witness doesn't match query creator.

**Solutions**:
1. Use correct witness type:
```move
// Must use same witness type as query creation
callback::verify_claim_submitted(callback, YourCorrectWitness {});
```

2. Check query was created with your witness:
```move
let creator_witness = query.creator_witness();
assert!(creator_witness == type_name::get<YourWitness>(), EWrongWitness);
```

#### Issue: Callbacks not being received

**Cause**: Using non-callback functions or incorrect integration.

**Solutions**:
1. Use callback-enabled functions:
```move
// Instead of submit_claim(), use:
let callback = reef::submit_claim_with_callback(/* ... */);
```

2. Handle callback in same transaction:
```move
let callback = reef::submit_claim_with_callback(/* ... */);
handle_claim_callback(callback);  // Must consume in same tx
```

### Data Handling Issues

#### Issue: BCS deserialization failures

**Cause**: Data format mismatch between encoding and decoding.

**Solutions**:
1. Use consistent data structures:
```move
// Encoder side
let data = MyDataStruct { value: 123, timestamp: 1234567 };
let encoded = bcs::to_bytes(&data);

// Decoder side - must use same struct
let decoded: MyDataStruct = bcs::from_bytes(&encoded);
```

2. Handle deserialization errors gracefully:
```move
public fun safe_decode(data: vector<u8>): Option<u64> {
    if (data.length() != 8) {  // u64 should be 8 bytes
        return option::none()
    };
    
    let value: u64 = bcs::from_bytes(&data);
    option::some(value)
}
```

### Performance Issues

#### Issue: High gas costs

**Causes and solutions**:

1. **Large metadata**: Keep query metadata minimal
```move
// Instead of storing large JSON
b"{'price': 'BTC/USD', 'exchange': 'Coinbase', 'methodology': '...'}"

// Use concise format
b"BTC/USD"
```

2. **Inefficient data structures**: Choose appropriate storage
```move
// For small datasets
let small_map: VecMap<K, V> = vec_map::empty();

// For large datasets  
let large_table: Table<K, V> = table::new(ctx);
```

3. **Unnecessary operations**: Minimize transaction complexity
```move
// Batch operations when possible
public fun batch_settle(queries: vector<&mut Query>, /* ... */) {
    // Handle multiple queries in single transaction
}
```

## Debugging Techniques

### Query State Inspection

Check query state at any time:

```move
public fun debug_query_state(query: &Query, clock: &Clock) {
    std::debug::print(&b"Query Debug Info:");
    std::debug::print(&query.topic());
    std::debug::print(&query.status(clock));
    std::debug::print(&query.created_at_ms());
    std::debug::print(&query.submitter());
    std::debug::print(&query.challenger());
    std::debug::print(&query.is_settled());
}
```

### Event Monitoring

Monitor events to track query progress:

```move
// Look for these events in transaction logs
QueryCreated { query_id, topic, coin_type, creator_witness }
ClaimSubmitted { query_id, submitter, submitted_at_ms }
ClaimChallenged { query_id, challenger, challenged_at_ms }
QueryResolved { query_id, resolved_claim }
```

### Testing Helpers

Use test utilities for debugging:

```move
#[test_only]
public fun test_query_lifecycle() {
    let mut scenario = test_scenario::begin(admin!());
    
    // Enable detailed logging
    test_scenario::print_gas_summary(&scenario);
    
    // Step through each state
    let query_id = create_test_query(&mut scenario);
    print_query_state(&scenario, query_id);
    
    submit_test_claim(&mut scenario, query_id);
    print_query_state(&scenario, query_id);
    
    // ... continue debugging each step
}
```

## Error Reference

### Error Code Meanings

**reef::reef module errors**:
- `0`: Insufficient bond amount
- `1`: Invalid query status for operation
- `2`: Still within liveness period
- `3`: Not authorized for this operation
- `4`: Invalid coin type
- `5`: Invalid liveness configuration
- `6`: Empty topic not allowed
- `7`: Empty metadata not allowed
- `8`: No claim submitted yet
- `9`: Fee amount incorrect
- `10`: Resolution for wrong query
- `11`: Wrong resolver type
- `12`: Cannot challenge own claim
- `13`: Resolution is stale
- `14`: Topic too long
- `15`: Metadata too long
- `16`: Topic not authorized
- `17`: Expiration in past
- `18`: Expiration too early
- `19`: Invalid witness

**reef::protocol module errors**:
- `0`: Invalid publisher
- `1`: Bond type not allowed
- `2`: Invalid burn rate

**reef::resolver module errors**:
- `0`: Invalid publisher
- `1`: Invalid witness type
- `2`: Resolver disabled

**reef::callback module errors**:
- `0`: Invalid callback type

## Getting Help

### Diagnostic Information

When reporting issues, include:

1. **Environment details**:
   - Sui version
   - Move package versions
   - Network (devnet/testnet/mainnet)

2. **Error details**:
   - Full error message
   - Transaction hash (if applicable)
   - Code that triggered the issue

3. **Query information**:
   - Query ID
   - Current query status
   - Timeline of operations

4. **Configuration**:
   - Protocol parameters
   - Query configuration
   - Token types used

### Community Resources

- GitHub Issues: Report bugs and feature requests
- Documentation: Check for updates and clarifications
- Discord/Forums: Community support and discussion
- Code Examples: Reference implementations and patterns

### Professional Support

For production deployments:
- Security auditing services
- Integration consulting
- Custom resolver development
- Monitoring and alerting setup

Most issues can be resolved by carefully checking the error codes, verifying configurations, and ensuring proper query lifecycle management. The key is understanding what each error means and systematically checking the conditions that trigger them.