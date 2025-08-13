# Integration Guide

This guide provides practical patterns and best practices for integrating Reef oracle into your applications.

## Integration Overview

### When to Use Reef

Reef works best for scenarios where:

**Data is generally accurate**: Most submissions should be correct, making challenges rare

**Economic incentives work**: The cost of posting bonds creates meaningful deterrent against false data

**Speed matters more than immediate finality**: Optimistic assumption allows faster data flow than always-verified systems

**Data can be objectively verified**: Disputes need clear resolution criteria

### Common Use Cases

**DeFi Price Feeds**
```move
// Request current market prices for liquidation checks
create_price_query("BTC/USD", 4_hours_liveness, 1_SUI_bond)
```

**Cross-chain Verification**
```move  
// Verify events happened on other blockchains
create_verification_query("ETH_BLOCK_12345_HASH", 24_hours_liveness, 5_SUI_bond)
```

**Sports and Events**
```move
// Get results for prediction markets
create_event_query("WORLD_CUP_FINAL_WINNER", 48_hours_liveness, 10_SUI_bond)
```

**Web API Data**
```move
// Bring external API data on-chain
create_api_query("WEATHER_NYC_TEMP", 2_hours_liveness, 0.5_SUI_bond)
```

## Basic Integration Pattern

### 1. Setup Phase

First, establish your integration infrastructure:

```move
module my_app {
    use reef::reef;
    use reef::protocol::Protocol;
    use reef::resolver::Resolver;
    
    // Your application witness
    struct MyAppWitness has drop {}
    
    // Application state
    struct AppState has key {
        id: UID,
        protocol_id: ID,
        resolver_id: ID,
        active_queries: VecMap<vector<u8>, ID>, // topic -> query_id
        cached_data: Table<vector<u8>, CachedData>,
    }
    
    struct CachedData has store {
        value: vector<u8>,
        timestamp: u64,
        confidence: u8, // 0-100
    }
}
```

### 2. Query Creation

Create queries when you need fresh data:

```move
public fun request_data(
    app: &mut AppState,
    protocol: &mut Protocol,
    resolver: &Resolver,
    topic: vector<u8>,
    bond_amount: u64,
    liveness_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Check if we already have recent data
    if (has_recent_data(&app.cached_data, &topic, clock)) {
        return // Use cached data
    };
    
    // Check for active query
    if (app.active_queries.contains(&topic)) {
        return // Query already in progress
    };
    
    // Create new query
    let fee = coin::mint_for_testing<SUI>(protocol.fee_amount(type_name::get<SUI>()), ctx);
    let config = reef::create_query_config(
        bond_amount,
        option::some(liveness_ms),
        clock.timestamp_ms() + (liveness_ms * 4), // 4x liveness for expiry
        option::some(ctx.sender()) // Send rewards to caller
    );
    
    let query = reef::create_query<SUI, MyAppWitness>(
        protocol,
        resolver,
        MyAppWitness {},
        fee,
        config,
        topic,
        b"Automated query from MyApp",
        option::none(),
        clock,
        ctx
    );
    
    // Track active query
    app.active_queries.insert(topic, query.id.to_inner());
    query.share();
}
```

### 3. Data Consumption

Handle oracle results when queries complete:

```move
public fun consume_oracle_result(
    app: &mut AppState,
    query: &Query,
    clock: &Clock,
) {
    // Verify query is settled
    assert!(query.is_settled(), EQueryNotSettled);
    
    let topic = query.topic();
    let resolved_claim = query.resolved_claim();
    
    if (resolved_claim.is_some()) {
        // Update cached data
        let cached = CachedData {
            value: resolved_claim.destroy_some(),
            timestamp: clock.timestamp_ms(),
            confidence: if (query.challenger().is_none()) { 95 } else { 85 }
        };
        
        if (app.cached_data.contains(topic)) {
            app.cached_data.remove(topic);
        };
        app.cached_data.add(topic, cached);
    };
    
    // Remove from active queries
    app.active_queries.remove(&topic);
}
```

## Advanced Integration Patterns

### Event-Driven Architecture

Build reactive applications using callbacks:

```move
module reactive_app {
    use reef::callback;
    
    struct ReactiveApp has key {
        id: UID,
        pending_actions: Table<ID, PendingAction>,
    }
    
    struct PendingAction has store {
        action_type: u8,
        parameters: vector<u8>,
        created_at: u64,
    }
    
    // React to claim submissions
    public fun on_claim_submitted(
        app: &mut ReactiveApp,
        callback: callback::ClaimSubmitted,
        clock: &Clock,
    ) {
        callback.verify_claim_submitted(MyAppWitness {});
        
        let callback::ClaimSubmitted { query_id, claim, .. } = callback;
        
        // Start preparing for potential challenge period
        prepare_for_liveness_period(app, query_id, claim, clock);
    }
    
    // React to final settlement
    public fun on_query_settled(
        app: &mut ReactiveApp,
        callback: callback::QuerySettled,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        callback.verify_query_settled(MyAppWitness {});
        
        let callback::QuerySettled { query_id, claim, .. } = callback;
        
        // Execute pending action based on oracle result
        if (app.pending_actions.contains(query_id)) {
            let action = app.pending_actions.remove(query_id);
            execute_action(action, claim, clock, ctx);
        }
    }
}
```

### Price Feed Integration

Specialized pattern for financial data feeds:

```move
module price_feed {
    struct PriceFeed has key {
        id: UID,
        pair: vector<u8>,              // e.g., "BTC/USD"
        current_price: Option<u64>,    // Current price with decimals
        last_update: u64,              // Timestamp of last update
        update_frequency: u64,         // How often to refresh (ms)
        confidence_threshold: u64,     // Min time before trusting price
    }
    
    // Request price update if data is stale
    public fun ensure_fresh_price(
        feed: &mut PriceFeed,
        protocol: &mut Protocol,
        resolver: &Resolver,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let current_time = clock.timestamp_ms();
        
        // Check if we need fresh data
        let needs_update = if (feed.current_price.is_none()) {
            true
        } else {
            current_time - feed.last_update > feed.update_frequency
        };
        
        if (needs_update) {
            create_price_query(feed, protocol, resolver, clock, ctx);
        }
    }
    
    // Get price with confidence check
    public fun get_price_with_confidence(
        feed: &PriceFeed,
        clock: &Clock,
    ): Option<u64> {
        if (feed.current_price.is_none()) {
            return option::none()
        };
        
        let age = clock.timestamp_ms() - feed.last_update;
        if (age < feed.confidence_threshold) {
            feed.current_price
        } else {
            option::none() // Data too old to trust
        }
    }
}
```

### Multi-Oracle Strategy

Combine multiple oracle sources for higher reliability:

```move
module multi_oracle {
    struct OracleAggregator has key {
        id: UID,
        sources: VecMap<vector<u8>, SourceConfig>, // source_name -> config
        consensus_threshold: u64, // Min sources needed for consensus
        max_deviation: u64,       // Max allowed price deviation (basis points)
    }
    
    struct SourceConfig has store {
        weight: u64,              // Voting weight for this source
        reliability_score: u64,   // Historical accuracy (0-100)
        last_update: u64,
    }
    
    // Create queries across multiple sources
    public fun request_consensus_data(
        aggregator: &mut OracleAggregator,
        topic: vector<u8>,
        protocol: &mut Protocol,
        resolvers: vector<&Resolver>, // Different resolver types
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let mut i = 0;
        while (i < resolvers.length()) {
            create_source_query(
                topic,
                *resolvers.borrow(i),
                protocol,
                clock,
                ctx
            );
            i = i + 1;
        };
    }
    
    // Aggregate results when multiple sources complete
    public fun compute_consensus(
        aggregator: &OracleAggregator,
        results: vector<(vector<u8>, u64, u64)>, // (source, value, timestamp)
    ): Option<u64> {
        if (results.length() < aggregator.consensus_threshold) {
            return option::none()
        };
        
        // Implement weighted median or other aggregation logic
        compute_weighted_median(results, &aggregator.sources)
    }
}
```

## Data Handling Patterns

### Data Encoding/Decoding

Standardize how you encode different data types:

```move
module data_formats {
    // Price data with decimals
    struct PriceData has drop {
        value: u64,     // Price with decimals
        decimals: u8,   // Number of decimal places
        timestamp: u64, // When price was observed
    }
    
    public fun encode_price(price: PriceData): vector<u8> {
        bcs::to_bytes(&price)
    }
    
    public fun decode_price(data: vector<u8>): PriceData {
        bcs::from_bytes<PriceData>(&data)
    }
    
    // Boolean data with confidence
    struct BooleanData has drop {
        value: bool,
        confidence: u8, // 0-100
        source: vector<u8>,
    }
    
    // Enumerated data (e.g., sports results)
    struct EnumData has drop {
        option_index: u64,
        options: vector<vector<u8>>,
        metadata: vector<u8>,
    }
}
```

### Error Handling

Robust error handling for oracle failures:

```move
module error_handling {
    // Oracle result types
    enum OracleResult has drop {
        Success(vector<u8>),
        Timeout,
        Disputed,
        Error(vector<u8>),
    }
    
    public fun safe_get_oracle_data(
        query: &Query,
        clock: &Clock,
        max_age_ms: u64,
    ): OracleResult {
        // Check if query is settled
        if (!query.is_settled()) {
            if (query.is_expired(clock)) {
                return OracleResult::Timeout
            } else {
                return OracleResult::Error(b"Query not yet settled")
            }
        };
        
        // Check if data was disputed
        if (query.challenger().is_some()) {
            return OracleResult::Disputed
        };
        
        // Check data age
        if (query.submitted_at_ms().is_some()) {
            let age = clock.timestamp_ms() - *query.submitted_at_ms().borrow();
            if (age > max_age_ms) {
                return OracleResult::Error(b"Data too old")
            }
        };
        
        // Return successful result
        match (query.resolved_claim()) {
            option::some(claim) => OracleResult::Success(claim),
            option::none() => OracleResult::Error(b"No resolved claim")
        }
    }
}
```

## Testing Integration

### Unit Testing

Test your oracle integration with mock data:

```move
#[test_only]
module integration_tests {
    use reef::test_utils::{
        setup_protocol,
        setup_dummy_resolver,
        create_test_query,
        submit_test_claim,
        advance_clock,
    };
    
    #[test]
    fun test_price_feed_integration() {
        let mut scenario = test_scenario::begin(admin!());
        let clock = setup_clock(&mut scenario);
        
        // Setup protocol and resolver
        setup_protocol(&mut scenario, vector[b"BTC/USD"]);
        setup_dummy_resolver(&mut scenario);
        
        scenario.next_tx(creator!());
        {
            let mut protocol = scenario.take_shared<Protocol>();
            let resolver = scenario.take_shared<Resolver>();
            let mut clock = scenario.take_shared<Clock>();
            
            // Create price feed
            let mut feed = create_price_feed(b"BTC/USD", &mut scenario.ctx());
            
            // Request price update
            ensure_fresh_price(
                &mut feed,
                &mut protocol,
                &resolver,
                &clock,
                &mut scenario.ctx()
            );
            
            // Verify query was created
            // ... test assertions
            
            transfer::public_transfer(feed, creator!());
            test_scenario::return_shared(protocol);
            test_scenario::return_shared(resolver);
            test_scenario::return_shared(clock);
        };
        
        scenario.end();
    }
}
```

### Integration Testing

Test complete workflows end-to-end:

```move
#[test]
fun test_complete_oracle_workflow() {
    let mut scenario = test_scenario::begin(admin!());
    
    // 1. Setup phase
    setup_test_environment(&mut scenario);
    
    // 2. Create query
    let query_id = create_test_query(&mut scenario, b"ETH/USD", 1_000_000);
    
    // 3. Submit claim
    submit_test_claim(&mut scenario, query_id, encode_price(3500_000000));
    
    // 4. Advance time past liveness period
    advance_clock(&mut scenario, 4 * 60 * 60 * 1000); // 4 hours
    
    // 5. Settle query
    settle_test_query(&mut scenario, query_id);
    
    // 6. Verify result
    scenario.next_tx(admin!());
    {
        let query = scenario.take_shared<Query>();
        assert!(query.is_settled(), 0);
        assert!(query.resolved_claim().is_some(), 1);
        test_scenario::return_shared(query);
    };
    
    scenario.end();
}
```

## Performance Considerations

### Gas Optimization

Minimize transaction costs:

```move
// Batch multiple operations
public fun batch_oracle_operations(
    queries: vector<ID>,
    protocol: &mut Protocol,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let mut i = 0;
    while (i < queries.length()) {
        let query_id = *queries.borrow(i);
        // Process query efficiently
        i = i + 1;
    };
}

// Use efficient data structures
struct OptimizedCache has key {
    id: UID,
    // Use VecMap for small datasets, Table for large ones
    small_cache: VecMap<vector<u8>, vector<u8>>,
    large_cache: Table<vector<u8>, vector<u8>>,
}
```

### Storage Optimization

Minimize on-chain storage costs:

```move
// Store only essential data on-chain
struct MinimalOracleData has store {
    value: u64,        // Core data value
    timestamp: u64,    // When data was created
    confidence: u8,    // 0-255 confidence level
}

// Use events for detailed logging instead of storage
public struct DetailedOracleEvent has copy, drop {
    query_id: ID,
    topic: vector<u8>,
    full_metadata: vector<u8>,
    processing_stats: ProcessingStats,
}
```

## Best Practices Summary

### Do's

**Validate inputs thoroughly**
- Check query status before operations
- Verify bond amounts match requirements
- Validate data formats and ranges

**Handle errors gracefully**
- Plan for query timeouts and failures
- Implement fallback data sources
- Use appropriate confidence thresholds

**Monitor oracle health**
- Track query success rates
- Monitor challenge frequencies
- Alert on unusual patterns

**Optimize for efficiency**
- Cache oracle results appropriately
- Batch operations when possible
- Use events for detailed logging

### Don'ts

**Don't assume immediate finality**
- Oracle data can be challenged
- Build in confidence periods
- Plan for dispute resolution delays

**Don't ignore economic incentives**
- Set appropriate bond amounts
- Consider challenge likelihood
- Monitor economic sustainability

**Don't over-engineer initially**
- Start with simple patterns
- Add complexity as needed
- Test thoroughly before production

**Don't forget security**
- Validate all oracle data
- Use witness patterns correctly
- Plan for malicious inputs

This integration guide provides the foundation for building robust applications with Reef oracle. The key is starting simple and adding sophistication as your understanding and requirements grow.