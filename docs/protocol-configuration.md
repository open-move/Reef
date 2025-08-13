# Protocol Configuration

The Protocol module manages global settings that govern how the entire Reef oracle network operates. Understanding these parameters is essential for network governance and optimal oracle performance.

## Global Configuration Object

The Protocol struct serves as the central configuration repository:

```move
struct Protocol has key {
    id: UID,
    burn_rate_bps: u64,                    // Percentage of losing bonds to burn
    minimum_liveness_ms: u64,              // Minimum challenge window
    minimum_submission_delay_ms: u64,      // Delay before claims can be submitted  
    allowed_coin_types: VecSet<TypeName>,  // Whitelisted bond/fee tokens
    allowed_topics: Table<vector<u8>, bool>, // Approved query topics
    fee_amounts: VecMap<TypeName, u64>,    // Protocol fees by token type
    minimum_bond_map: VecMap<TypeName, u64>, // Minimum bonds by token type
}
```

## Governance Model

### Protocol Capability

All protocol modifications require the ProtocolCap:

```move
struct ProtocolCap has key {
    id: UID,
}
```

**Security properties:**
- Single capability object controls all protocol changes
- Can be held by individual, multisig, or DAO
- Transfer enables governance model changes
- Lost capability would freeze protocol parameters

### Administrative Functions

All configuration changes follow this pattern:

```move
public fun set_parameter(
    protocol: &mut Protocol,
    _: &ProtocolCap,        // Governance authorization required
    new_value: ParameterType,
) {
    protocol.parameter = new_value;
}
```

## Economic Parameters

### Burn Rate

Controls what percentage of losing bonds gets burned (destroyed) versus redistributed.

```move
// Default: 50% (5000 basis points)
burn_rate_bps: 5000,

// Configure burn rate (0-10000 basis points = 0-100%)
protocol::set_burn_rate(&mut protocol, &protocol_cap, 7500); // 75%
```

**Impact on behavior:**
- **Low burn rate (0-25%)**: Encourages participation, gentler punishment
- **Medium burn rate (25-75%)**: Balanced approach, moderate deterrent  
- **High burn rate (75-100%)**: Strong deterrent, may reduce participation

**Considerations:**
- Higher burn rates reduce circulating token supply
- Lower burn rates increase rewards for winners
- Changes affect pending queries immediately upon settlement

### Minimum Liveness Period

Enforces minimum time for challenge windows across all queries.

```move
// Default: 20 hours (72,000,000 milliseconds)
minimum_liveness_ms: 72000000,

// Increase minimum to 24 hours
protocol::set_minimum_liveness(&mut protocol, &protocol_cap, 86400000);
```

**Purpose:**
- Prevents queries with extremely short challenge windows
- Ensures reasonable time for community review
- Balances speed with security

**Guidelines:**
- **High-frequency data**: 30 minutes to 2 hours
- **Standard queries**: 4 to 24 hours
- **High-stakes decisions**: 24 hours to 1 week

### Submission Delay

Time that must pass after query creation before claims can be submitted.

```move
// Default: 5 minutes (300,000 milliseconds)  
minimum_submission_delay_ms: 300000,

// Extend to 10 minutes for additional security
protocol::set_min_submission_delay(&mut protocol, &protocol_cap, 600000);
```

**Security benefits:**
- Prevents front-running attacks on query creation
- Allows time for parameter review
- Enables fair access for all potential submitters

**Trade-offs:**
- Longer delays slow down oracle response time
- Shorter delays increase front-running risk

## Token Whitelisting

### Allowed Coin Types

Controls which tokens can be used for bonds and fees.

```move
// Add new token type
protocol::add_allowed_coin_type(
    &mut protocol, 
    &protocol_cap, 
    type_name::get<USDC>()
);

// Remove token type (affects only new queries)
protocol::remove_allowed_coin_type(
    &mut protocol,
    &protocol_cap, 
    type_name::get<DEPRECATED_TOKEN>()
);
```

**Whitelisting criteria:**
- **Liquidity**: Sufficient trading volume and market depth
- **Stability**: Low volatility or established stablecoin
- **Security**: Well-audited token contracts
- **Utility**: Actual demand from oracle users

**Common token types:**
- **SUI**: Native token, always recommended
- **USDC/USDT**: Stablecoins for predictable costs
- **Major tokens**: Well-established tokens with deep liquidity

### Fee Configuration

Set protocol fees for each allowed token type.

```move
// Configure fees per token
protocol::set_fee_amount(
    &mut protocol,
    &protocol_cap,
    type_name::get<SUI>(),
    1_000_000  // 0.001 SUI
);

protocol::set_fee_amount(
    &mut protocol,
    &protocol_cap,
    type_name::get<USDC>(),
    1000  // $0.001 USDC (assuming 6 decimals)
);
```

**Fee considerations:**
- Set high enough to prevent spam queries
- Keep low enough to encourage legitimate usage
- Adjust based on token volatility and gas costs
- Consider USD-equivalent across different tokens

### Minimum Bond Requirements

Establish minimum bond amounts for each token type.

```move
// Set minimum bonds per token
protocol::set_minimum_bond(
    &mut protocol,
    &protocol_cap,
    type_name::get<SUI>(),
    100_000_000  // 0.1 SUI minimum
);
```

**Setting guidelines:**
- **Low minimum**: Encourages participation, higher spam risk
- **High minimum**: Reduces spam, may limit participation
- **Token-specific**: Account for price differences between tokens
- **Use case alignment**: Match minimums to expected query values

## Topic Whitelisting

### Purpose

Topic whitelisting serves several important functions:
- **Content moderation**: Prevent inappropriate or illegal queries
- **Quality control**: Ensure queries are resolvable and meaningful  
- **Resource management**: Limit scope to manageable domains
- **Compliance**: Meet regulatory requirements in different jurisdictions

### Managing Topics

```move
// Add new approved topic
protocol::add_allowed_topic(
    &mut protocol,
    &protocol_cap,
    b"BTC/USD"
);

// Remove topic (affects only new queries)
protocol::remove_allowed_topic(
    &mut protocol,
    &protocol_cap,
    b"DEPRECATED_FEED"
);
```

### Topic Categories

**Financial Data:**
```move
protocol::add_allowed_topic(&mut protocol, &protocol_cap, b"ETH/USD");
protocol::add_allowed_topic(&mut protocol, &protocol_cap, b"BTC/EUR");  
protocol::add_allowed_topic(&mut protocol, &protocol_cap, b"SPY_PRICE");
```

**Sports Results:**
```move
protocol::add_allowed_topic(&mut protocol, &protocol_cap, b"NBA_FINALS_2024");
protocol::add_allowed_topic(&mut protocol, &protocol_cap, b"WORLD_CUP_WINNER");
protocol::add_allowed_topic(&mut protocol, &protocol_cap, b"SUPER_BOWL_SCORE");
```

**Weather and Environment:**
```move
protocol::add_allowed_topic(&mut protocol, &protocol_cap, b"NYC_TEMPERATURE");
protocol::add_allowed_topic(&mut protocol, &protocol_cap, b"HURRICANE_LANDFALL");
protocol::add_allowed_topic(&mut protocol, &protocol_cap, b"EARTHQUAKE_MAGNITUDE");
```

**Cross-chain Events:**
```move
protocol::add_allowed_topic(&mut protocol, &protocol_cap, b"ETH_BLOCK_HASH");
protocol::add_allowed_topic(&mut protocol, &protocol_cap, b"BITCOIN_DIFFICULTY");
protocol::add_allowed_topic(&mut protocol, &protocol_cap, b"POLYGON_TVL");
```

## Configuration Best Practices

### Initial Setup

When first deploying the protocol:

1. **Conservative parameters**: Start with higher fees and minimums
2. **Limited topics**: Begin with clear, unambiguous data types
3. **Proven tokens**: Only whitelist well-established tokens
4. **Reasonable timing**: Use standard liveness periods (4-24 hours)

### Parameter Evolution

As the network matures:

1. **Monitor usage**: Track query volume, challenge rates, success rates
2. **Adjust economics**: Lower barriers if participation is too low
3. **Expand topics**: Add new categories based on demand
4. **Optimize timing**: Reduce delays if security permits

### Governance Considerations

**Upgrade process:**
1. Propose parameter changes with rationale
2. Allow community discussion period  
3. Implement changes with advance notice
4. Monitor impact and adjust if needed

**Emergency controls:**
- Consider adding pause functionality for crisis situations
- Plan for governance key recovery scenarios
- Document emergency procedures clearly

## Configuration Monitoring

### Key Metrics to Track

**Usage metrics:**
- Query creation rate
- Topic distribution
- Token usage patterns
- Average bond sizes

**Security metrics:**
- Challenge rate
- Challenge success rate
- Burn amount totals
- Governance changes frequency

**Economic metrics:**
- Fee collection totals
- Minimum bond effectiveness
- Token price impacts
- Profitability for participants

### Alerting and Response

Set up monitoring for:
- Unusual parameter change patterns
- Governance key activity
- Economic parameter effectiveness
- Topic whitelist circumvention attempts

## Integration Impact

Configuration changes affect integrators:

**Breaking changes:**
- Removing allowed tokens (existing queries unaffected)
- Removing allowed topics (existing queries unaffected)
- Major parameter changes that affect query behavior

**Non-breaking changes:**
- Adding new allowed tokens or topics
- Minor adjustments to timing parameters
- Fee adjustments within reasonable ranges

**Communication:**
- Announce changes in advance
- Provide migration guides when needed
- Maintain backward compatibility where possible

Protocol configuration is the foundation of Reef's security and usability. Careful parameter management ensures the network remains secure, efficient, and accessible to legitimate users while deterring abuse and maintaining economic sustainability.