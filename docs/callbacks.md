# Callbacks

The callback system allows query creators to receive notifications when important events happen to their queries. This enables reactive applications that respond to oracle data and dispute outcomes.

## Callback Overview

### Purpose

Callbacks solve several integration challenges:

**Asynchronous updates**: Oracle queries complete at unpredictable times
**Event-driven architecture**: Applications can react to oracle events
**State synchronization**: Keep application state in sync with oracle state
**Automated responses**: Trigger actions when queries reach certain states

### Security Model

Callbacks use witness verification to prevent spoofing:
- Each callback contains the creator's witness type
- Only the correct creator witness can verify and consume callbacks
- This prevents malicious actors from sending fake callbacks

## Callback Types

### ClaimSubmitted

Notification that someone has submitted a claim to your query.

```move
struct ClaimSubmitted {
    query_id: ID,
    submitter: address,
    claim: vector<u8>,
    creator_witness: TypeName,
}
```

**When triggered**: Someone calls `submit_claim_with_callback`

**Use cases**:
- Log claim submission in application database
- Start monitoring for potential challenges
- Begin preparing for settlement
- Update UI with submitted claim data

### ClaimChallenged

Notification that someone has challenged the submitted claim.

```move
struct ClaimChallenged {
    query_id: ID,
    challenger: address,
    creator_witness: TypeName,
}
```

**When triggered**: Someone calls `challenge_claim_with_callback`

**Use cases**:
- Alert administrators about disputed data
- Begin dispute monitoring process
- Update application state to reflect uncertainty
- Prepare alternative data sources

### QuerySettled

Notification that a query has reached its final state.

```move
struct QuerySettled {
    query_id: ID,
    claim: vector<u8>,
    creator_witness: TypeName,
}
```

**When triggered**: Someone calls `settle_query_with_callback`

**Use cases**:
- Use final oracle result in application logic
- Update cached data with oracle result
- Trigger dependent queries or processes
- Complete business logic workflows

## Using Callbacks

### Creating Queries with Callbacks

Use the standard query creation, but use callback-enabled functions for lifecycle events:

```move
// Create query normally
let query = reef::create_query<SUI, MyWitness>(
    &mut protocol,
    &resolver,
    MyWitness {},
    fee,
    config,
    b"ETH/USD",
    b"Current ETH price",
    option::none(),
    &clock,
    ctx
);

query.share();
```

### Submitting Claims with Callbacks

```move
let callback = reef::submit_claim_with_callback<SUI>(
    &protocol,
    &mut query,
    claim_data,
    bond_coin,
    &clock,
    ctx
);

// Handle the callback in your application logic
handle_claim_submitted(callback);
```

### Challenging Claims with Callbacks

```move
let (challenge_request, callback) = reef::challenge_claim_with_callback<SUI>(
    &mut query,
    challenge_bond,
    &clock,
    ctx
);

// Handle callback immediately
handle_claim_challenged(callback);

// Process challenge through resolver
// ... resolver logic ...
```

### Settling Queries with Callbacks

```move
let callback = reef::settle_query_with_callback<SUI>(
    &mut protocol,
    &mut query,
    resolution,
    &clock,
    ctx
);

// Handle final result
handle_query_settled(callback);
```

## Callback Verification

### Witness Verification

Always verify callbacks before processing:

```move
public fun handle_claim_submitted(callback: ClaimSubmitted) {
    // Verify this callback is for queries created with our witness
    callback::verify_claim_submitted(callback, MyWitness {});
    
    // Now safe to process the callback
    let ClaimSubmitted { query_id, submitter, claim, .. } = callback;
    
    // Your application logic here
}
```

**Security importance**:
- Prevents processing callbacks from other query creators
- Ensures callback authenticity
- Protects against malicious callback injection

### Example Verification Pattern

```move
module my_oracle_app {
    use reef::callback;
    
    struct MyAppWitness has drop {}
    
    public fun process_claim_callback(callback: callback::ClaimSubmitted) {
        // Verify and destructure in one step
        callback::verify_claim_submitted(callback, MyAppWitness {});
        
        let callback::ClaimSubmitted { 
            query_id, 
            submitter, 
            claim,
            creator_witness: _ 
        } = callback;
        
        // Process the verified callback
        update_claim_status(query_id, submitter, claim);
    }
}
```

## Integration Patterns

### Event-Driven Application

Build applications that react to oracle events:

```move
module price_feed_app {
    use reef::callback;
    
    struct PriceFeedWitness has drop {}
    
    // Application state
    struct PriceFeed has key {
        id: UID,
        current_price: Option<u64>,
        last_update: u64,
        query_id: Option<ID>,
    }
    
    // React to claim submission
    public fun on_claim_submitted(
        feed: &mut PriceFeed,
        callback: callback::ClaimSubmitted,
    ) {
        callback::verify_claim_submitted(callback, PriceFeedWitness {});
        
        let callback::ClaimSubmitted { query_id, claim, .. } = callback;
        
        // Update pending state
        feed.query_id = option::some(query_id);
        
        // Decode price from claim
        let price: u64 = bcs::from_bytes(&claim);
        // Don't update current_price yet - wait for settlement
    }
    
    // React to final settlement
    public fun on_query_settled(
        feed: &mut PriceFeed,
        callback: callback::QuerySettled,
        clock: &Clock,
    ) {
        callback::verify_query_settled(callback, PriceFeedWitness {});
        
        let callback::QuerySettled { query_id, claim, .. } = callback;
        
        // Verify this is our query
        assert!(feed.query_id == option::some(query_id), EWrongQuery);
        
        // Update with final price
        let price: u64 = bcs::from_bytes(&claim);
        feed.current_price = option::some(price);
        feed.last_update = clock.timestamp_ms();
        feed.query_id = option::none(); // Clear pending query
    }
}
```

### Automated Workflow

Chain multiple oracle queries based on results:

```move
module automated_workflow {
    use reef::callback;
    
    struct WorkflowWitness has drop {}
    
    public fun on_price_settled(
        callback: callback::QuerySettled,
        protocol: &mut Protocol,
        resolver: &Resolver,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        callback::verify_query_settled(callback, WorkflowWitness {});
        
        let callback::QuerySettled { claim, .. } = callback;
        let price: u64 = bcs::from_bytes(&claim);
        
        // If price is above threshold, trigger liquidation query
        if (price > LIQUIDATION_THRESHOLD) {
            create_liquidation_query(protocol, resolver, clock, ctx);
        }
    }
}
```

### Monitoring and Alerting

Track query status and alert on important events:

```move
module monitoring_system {
    use reef::callback;
    
    struct MonitorWitness has drop {}
    
    // Alert when queries are challenged
    public fun on_claim_challenged(callback: callback::ClaimChallenged) {
        callback::verify_claim_challenged(callback, MonitorWitness {});
        
        let callback::ClaimChallenged { query_id, challenger, .. } = callback;
        
        // Emit alert event for off-chain monitoring
        event::emit(QueryChallenged {
            query_id,
            challenger,
            timestamp: clock.timestamp_ms(),
            alert_level: HIGH_PRIORITY,
        });
    }
}
```

## Best Practices

### Always Verify Callbacks

```move
// ✅ Good - Always verify before processing
public fun handle_callback(callback: ClaimSubmitted) {
    callback::verify_claim_submitted(callback, MyWitness {});
    // ... process callback
}

// ❌ Bad - Processing unverified callback
public fun handle_callback_bad(callback: ClaimSubmitted) {
    let ClaimSubmitted { query_id, .. } = callback;
    // Vulnerable to callback spoofing!
}
```

### Handle All Callback Types

Complete integrations handle all relevant events:

```move
// Handle the full lifecycle
public fun handle_submission(callback: callback::ClaimSubmitted) { /* ... */ }
public fun handle_challenge(callback: callback::ClaimChallenged) { /* ... */ }
public fun handle_settlement(callback: callback::QuerySettled) { /* ... */ }
```

### Graceful Error Handling

Callbacks can fail - handle errors appropriately:

```move
public fun try_handle_callback(callback: callback::ClaimSubmitted) {
    if (should_process_callback()) {
        callback::verify_claim_submitted(callback, MyWitness {});
        process_callback_safely(callback);
    } else {
        // Drop callback if not ready to process
        callback::verify_claim_submitted(callback, MyWitness {});
        // Callback destructed, no further action
    }
}
```

### Store Relevant Data Only

Callbacks are temporary - extract needed data immediately:

```move
public fun extract_callback_data(callback: callback::QuerySettled) {
    callback::verify_query_settled(callback, MyWitness {});
    
    let callback::QuerySettled { query_id, claim, .. } = callback;
    
    // Store in permanent application state
    update_permanent_storage(query_id, claim);
    
    // Callback is automatically dropped here
}
```

## Callback vs Event Monitoring

### Callbacks (Pull Model)

**Pros**:
- Guaranteed delivery to query creator
- Type-safe verification
- Integrated with transaction flow
- No external infrastructure needed

**Cons**:
- Only available to query creator
- Must be processed in same transaction
- Limited to specific function calls

### Events (Push Model)

**Pros**:
- Available to anyone monitoring the network
- Can be processed asynchronously
- Complete historical record
- Flexible monitoring infrastructure

**Cons**:
- Requires external monitoring setup
- No built-in verification
- Can miss events if monitoring fails
- More complex infrastructure

### Choosing the Right Approach

**Use callbacks when**:
- You created the query
- You need guaranteed notification
- You want to react immediately
- You prefer simple integration

**Use events when**:
- You need to monitor all queries
- You want historical analysis
- You have external monitoring infrastructure
- You need flexible notification rules

Many applications use both approaches - callbacks for immediate reactions and events for broader monitoring and analysis.

The callback system provides a secure, efficient way to build reactive oracle applications while maintaining the economic security that makes optimistic oracles effective.