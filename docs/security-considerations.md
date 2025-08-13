# Security Considerations

Security in Reef comes from economic incentives rather than cryptographic proofs. Understanding potential attack vectors and mitigation strategies is crucial for safe oracle usage.

## Threat Model

### Assumptions

Reef operates under these security assumptions:

**Economic rationality**: Participants act in their economic self-interest
**Market efficiency**: Bond and reward amounts reflect the value of accurate data  
**Resolution integrity**: Authorized resolvers make honest decisions
**Network security**: Underlying Sui blockchain provides transaction integrity

### Trust Boundaries

**Protocol Level**: Governance through ProtocolCap
**Resolver Level**: Authorization through witness types and publisher verification
**Query Level**: Economic incentives align behavior
**Application Level**: Proper integration patterns and validation

## Attack Vectors and Mitigations

### Economic Attacks

#### Griefing Attacks

**Attack**: Submit false challenges to waste submitters' time and money.

**Mechanism**: 
1. Attacker posts challenge bond
2. Forces expensive dispute resolution
3. Even if attacker loses, they've imposed costs on honest participants

**Mitigations**:
- Symmetric bond requirements make griefing expensive
- Burn mechanism punishes losing challengers
- Resolver fees add additional costs for unsuccessful challenges

**Economic analysis**:
```
Griefing cost = Challenge bond + Burn amount + Resolver fees
Minimum cost ≈ 1.5x bond amount (with 50% burn rate)
```

#### Sybil Attacks

**Attack**: Create multiple identities to manipulate oracle outcomes.

**Mechanism**:
1. Attacker creates many addresses  
2. Uses them to submit coordinated claims/challenges
3. Attempts to overwhelm honest participants

**Mitigations**:
- Bond requirements create per-identity costs
- Economic incentives favor accuracy over coordination
- Resolver diversity prevents single points of failure

**Note**: Sybil resistance comes from economic costs, not identity verification.

#### Bribery Attacks

**Attack**: Bribe resolver to make incorrect decisions.

**Mechanism**:
1. Attacker identifies upcoming high-value dispute
2. Offers resolver payment exceeding their expected honest earnings
3. Resolver makes incorrect decision in attacker's favor

**Mitigations**:
- Multiple resolver types reduce single points of failure
- Resolver reputation and governance mechanisms
- Burn mechanism reduces available profits from incorrect decisions
- Bond amounts should reflect bribery resistance requirements

**Economic analysis**:
```
Bribery cost > Resolver honest earnings + Reputation damage
Minimum resistance = Bond pool + Resolver fees + Reputation value
```

### Technical Attacks

#### Front-running Attacks

**Attack**: Monitor pending queries and submit claims before intended submitters.

**Mechanism**:
1. Attacker monitors mempool for query creation transactions
2. Submits claim transaction with higher gas fee
3. Gets claim submitted first, potentially with incorrect data

**Mitigations**:
- Minimum submission delay after query creation
- All participants can see query parameters during delay period
- Economic incentives still favor correct claims over speed

#### Oracle Manipulation

**Attack**: Manipulate external data sources that resolvers depend on.

**Mechanism**:
1. Identify data sources used by resolvers
2. Manipulate those sources during dispute resolution
3. Resolver makes decision based on manipulated data

**Mitigations**:
- Use resolvers with diverse data sources
- Implement time delays between data observation and resolution
- Choose resolvers with robust verification processes
- Consider commit-reveal schemes for sensitive data

#### Smart Contract Vulnerabilities

**Attack**: Exploit bugs in Reef contracts or resolver implementations.

**Mechanism**:
1. Find vulnerability in contract logic
2. Exploit to drain funds or manipulate outcomes
3. May affect multiple queries simultaneously

**Mitigations**:
- Thorough security auditing
- Formal verification where possible
- Bug bounty programs
- Gradual deployment with limits
- Circuit breaker mechanisms

### Social Engineering Attacks

#### Resolver Compromise

**Attack**: Compromise resolver operators through social engineering.

**Mechanism**:
1. Target resolver operators with phishing or social engineering
2. Gain access to resolver private keys
3. Make incorrect resolution decisions

**Mitigations**:
- Multi-signature resolver requirements
- Hardware security modules for key storage
- Operational security training
- Monitoring for unusual resolver behavior

#### Governance Attacks

**Attack**: Manipulate protocol governance to change parameters maliciously.

**Mechanism**:
1. Acquire large governance token holdings or ProtocolCap
2. Change protocol parameters to favor attacker
3. Exploit changed parameters in subsequent queries

**Mitigations**:
- Time delays on parameter changes
- Multi-signature governance requirements
- Community oversight and transparency
- Parameter change limits and safeguards

## Security Best Practices

### For Protocol Operators

#### Parameter Management

**Conservative defaults**:
```move
// Start with higher security parameters
burn_rate_bps: 7500,              // 75% burn rate
minimum_liveness_ms: 86400000,    // 24 hour minimum
minimum_submission_delay_ms: 600000, // 10 minute delay
```

**Regular monitoring**:
- Track challenge rates and outcomes
- Monitor for unusual query patterns  
- Alert on large bond amounts or suspicious activity
- Review resolver performance and behavior

**Upgrade procedures**:
- Test parameter changes on testnet first
- Announce changes with advance notice
- Implement gradually with monitoring
- Have rollback procedures ready

#### Resolver Management

**Due diligence**:
- Verify resolver publisher and witness types
- Audit resolver implementation code
- Test resolver behavior in various scenarios
- Monitor resolver performance over time

**Diversification**:
- Enable multiple resolver types
- Avoid dependency on single resolver
- Balance speed vs security in resolver choices
- Plan for resolver failure scenarios

### For Query Creators

#### Parameter Selection

**Bond sizing**:
```move
// Bond should reflect data value and manipulation risk
price_feed_bond: 1_000_000_000,      // 1 SUI for $100K position
liquidation_bond: 10_000_000_000,    // 10 SUI for $1M liquidation  
sport_result_bond: 5_000_000_000,    // 5 SUI for major event
```

**Timing parameters**:
```move
// Balance speed vs security
high_frequency: 1800000,    // 30 min for frequent updates
standard: 14400000,         // 4 hours for normal queries  
high_stakes: 86400000,      // 24 hours for critical data
```

#### Data Quality

**Clear specifications**:
- Provide unambiguous resolution criteria
- Include data sources and formatting requirements
- Specify edge case handling
- Document expected data ranges

**Validation logic**:
```move
public fun validate_price_data(claim: vector<u8>): bool {
    let price: u64 = bcs::from_bytes(&claim);
    
    // Sanity check price range
    price > 1_000_000 &&      // > $1 (6 decimals)
    price < 1_000_000_000_000  // < $1M (6 decimals)
}
```

### For Oracle Operators

#### Operational Security

**Data source diversity**:
- Use multiple independent data sources
- Cross-validate data before submission  
- Implement outlier detection
- Have backup data sources ready

**Security practices**:
- Use hardware wallets for high-value operations
- Implement monitoring and alerting
- Regular security audits of infrastructure
- Incident response procedures

**Economic management**:
- Size bond amounts appropriately for risk tolerance
- Monitor profitability and adjust strategies
- Maintain emergency reserves for unexpected challenges
- Track performance metrics and improve over time

#### Reputation Management

**Accuracy focus**:
- Prioritize correctness over speed
- Document decision-making processes
- Maintain transparent operations
- Build long-term reputation value

**Community engagement**:
- Participate in governance discussions
- Share expertise and insights
- Support ecosystem development
- Report suspicious activity

### For Application Developers

#### Integration Security

**Input validation**:
```move
public fun validate_oracle_data(
    query: &Query,
    expected_format: u8,
    max_age_ms: u64,
    clock: &Clock,
) {
    // Check query is settled
    assert!(query.is_settled(), EQueryNotSettled);
    
    // Check data age
    let age = clock.timestamp_ms() - *query.submitted_at_ms().borrow();
    assert!(age <= max_age_ms, EDataTooOld);
    
    // Validate data format
    let claim = query.resolved_claim().borrow();
    validate_data_format(claim, expected_format);
}
```

**Error handling**:
```move
public fun safe_oracle_consumption(
    query: &Query,
    fallback_value: u64,
    confidence_threshold: u8,
) -> u64 {
    if (!query.is_settled()) {
        return fallback_value
    };
    
    // Check if data was challenged (lower confidence)
    let confidence = if (query.challenger().is_some()) { 70 } else { 95 };
    
    if (confidence < confidence_threshold) {
        return fallback_value
    };
    
    // Extract and validate data
    match (query.resolved_claim()) {
        option::some(claim) => {
            let value: u64 = bcs::from_bytes(&claim);
            if (is_reasonable_value(value)) {
                value
            } else {
                fallback_value
            }
        },
        option::none() => fallback_value
    }
}
```

#### Circuit Breakers

**Anomaly detection**:
```move
public fun check_price_anomaly(
    new_price: u64,
    last_price: u64,
    max_change_bps: u64,
) -> bool {
    let change = if (new_price > last_price) {
        ((new_price - last_price) * 10000) / last_price
    } else {
        ((last_price - new_price) * 10000) / last_price
    };
    
    change <= max_change_bps
}
```

**Emergency procedures**:
- Plan for oracle failure scenarios
- Implement manual override mechanisms
- Have alternative data sources ready
- Document incident response procedures

## Security Monitoring

### Key Metrics

**Economic health**:
- Challenge rate trends
- Bond amount distributions
- Burn amount totals
- Resolver fee collections

**Operational health**:
- Query creation rates
- Settlement success rates
- Average resolution times
- Resolver uptime and performance

**Security indicators**:
- Unusual query patterns
- Large bond amounts
- Rapid parameter changes
- Resolver behavior anomalies

### Alerting Systems

**Automated alerts**:
```move
// Example alert conditions
if (challenge_rate > 10%) { alert("High challenge rate") }
if (bond_amount > 100_SUI) { alert("Large bond detected") }
if (resolution_time > 48_hours) { alert("Slow resolution") }
if (burn_amount > daily_average * 3) { alert("High burn rate") }
```

**Response procedures**:
- Escalation paths for different alert types
- Investigation procedures for suspicious activity
- Communication plans for security incidents
- Recovery procedures for various attack scenarios

## Conclusion

Security in optimistic oracles requires constant vigilance and appropriate economic parameters. The key principles are:

1. **Economic incentives must align with honest behavior**
2. **Parameters must reflect real-world attack costs**  
3. **Diversification reduces single points of failure**
4. **Monitoring enables rapid response to threats**
5. **Conservative approaches are safer than optimistic ones**

Regular review and adjustment of security practices ensures the oracle network remains resilient against evolving threats while maintaining the efficiency that makes optimistic oracles valuable.