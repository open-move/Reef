# Query Lifecycle

A query in Reef follows a well-defined lifecycle with clear state transitions and timing constraints. Understanding this flow is crucial for integrating with the oracle system effectively.

## State Machine Overview

```
Created ──submit_claim──▶ Submitted ──challenge_claim──▶ Challenged
   │                         │                              │
   │                         │                              │
   ▼                         ▼                              ▼
Expired                   Expired                        Resolved
   │                         │                              │
   │                         │                              │
   ▼                         ▼                              ▼
Settled                   Settled                        Settled
```

## Detailed State Descriptions

### Created

**What it means**: Query has been created but no claim has been submitted yet.

**Duration**: Until someone submits a claim or the query expires.

**Available actions**:
- Submit claim (by anyone meeting bond requirements)
- Add rewards (by creator only)
- Modify refund address (by creator only)
- Wait for expiration

**Key constraints**:
- Must wait for minimum submission delay before claims can be submitted
- Query creator can still modify certain parameters

**Example scenario**:
```
10:00 AM - Query created asking "What was BTC price at 9:00 AM?"
10:05 AM - Minimum submission delay passes
10:30 AM - Oracle submits claim: "$67,500"
```

### Submitted

**What it means**: Someone has submitted a claim and posted the required bond.

**Duration**: From claim submission until liveness period expires or someone challenges.

**Available actions**:
- Challenge claim (by anyone except the submitter)
- Wait for liveness period to expire
- Query expires if global expiration is reached

**Key constraints**:
- Cannot challenge your own claim
- Must challenge before liveness period expires
- Challengers must post equal bond amount

**Example scenario**:
```
10:30 AM - Oracle submits "$67,500" with 1 SUI bond
         - 1-hour liveness period begins
11:15 AM - Another party could challenge (but doesn't)
11:30 AM - Liveness period expires, ready for settlement
```

### Challenged

**What it means**: Someone has disputed the original claim and posted a challenge bond.

**Duration**: Until a resolver provides a resolution decision.

**Available actions**:
- Resolver provides resolution
- Query can still expire if global deadline is reached

**Key constraints**:
- Only compatible resolvers can provide resolutions
- Resolution must be after challenge timestamp
- Resolution determines winner and loser

**Example scenario**:
```
10:30 AM - Oracle submits "$67,500"
10:45 AM - Challenger disputes with "$67,200" and 1 SUI bond
         - Now waiting for resolver decision
11:00 AM - Resolver determines correct price was "$67,200"
         - Challenger wins, gets both bonds
```

### Resolved

**What it means**: A resolver has determined the correct claim for a challenged query.

**Duration**: Immediately transitions to Settled during settlement call.

**Available actions**:
- Settle query to distribute bonds based on resolution

**Key constraints**:
- Resolution cannot be changed once applied
- Settlement must happen to complete the process

### Settled

**What it means**: Final state where all bonds and rewards have been distributed.

**Duration**: Permanent state.

**Available actions**:
- Read final resolved claim
- No further state changes possible

**Key constraints**:
- This is a terminal state
- All economic transfers are complete

### Expired

**What it means**: Query reached its expiration deadline without completion.

**Duration**: Until settlement (then becomes Settled).

**Available actions**:
- Settle expired query to return bonds

**Key constraints**:
- No new claims or challenges can be made
- Settlement rules differ from resolved queries

## Timing Rules

### Global Expiration

Every query has a hard deadline after which no further activity is possible.

```move
// Query expires 24 hours after creation
expires_at_ms: clock.timestamp_ms() + 86400000
```

**Rules**:
- Must be after current time plus liveness period
- Takes precedence over all other timing rules
- Queries automatically expire when deadline is reached

### Submission Delay

Minimum time that must pass after query creation before claims can be submitted.

```move
// Default: 5 minutes (300,000 ms)
minimum_submission_delay_ms: 300000
```

**Purpose**:
- Prevents front-running attacks
- Gives everyone fair chance to see the query
- Allows time for parameter review

### Liveness Period

Time window during which submitted claims can be challenged.

```move
// Default: 20 hours (72,000,000 ms)
liveness_ms: 72000000
```

**Rules**:
- Starts when claim is submitted
- Challenges must occur before liveness expires
- If no challenge, query can be settled after liveness

## Example Timeline

Here's a complete timeline showing how timing constraints work together:

```
Day 1, 09:00 - Query created (expires: Day 2, 09:00)
Day 1, 09:05 - Submission delay ends
Day 1, 10:30 - Claim submitted (liveness ends: Day 2, 06:30)
Day 1, 11:00 - Someone could challenge here ✓
Day 2, 06:00  - Someone could still challenge here ✓
Day 2, 06:30  - Liveness period ends, no more challenges ✗
Day 2, 07:00  - Query can be settled ✓
Day 2, 09:00  - Query expires if not settled ✓
```

## State Transition Triggers

### Automatic Transitions

Some transitions happen automatically based on time:

- **Created → Expired**: When `expires_at_ms` is reached
- **Submitted → Expired**: When `expires_at_ms` is reached OR when liveness expires without challenge

### Manual Transitions

Other transitions require explicit function calls:

- **Created → Submitted**: Call `submit_claim()`
- **Submitted → Challenged**: Call `challenge_claim()`
- **Challenged → Resolved**: Call resolver's resolution function
- **Resolved → Settled**: Call `settle_query()`
- **Expired → Settled**: Call `settle_query()`

## Status Determination Logic

The query status is calculated dynamically based on the current time and query state:

```move
public fun status(query: &Query, clock: &Clock): QueryStatus {
    let current_time = clock.timestamp_ms();
    
    // Check expiration first
    if (current_time >= query.config.expires_at_ms) return QueryStatus::Expired;
    
    // Check if settled
    if (query.is_settled) return QueryStatus::Settled;
    
    // Check submission status
    if (query.submitter.is_none()) return QueryStatus::Created;
    
    // Check challenge status
    if (query.challenger.is_none()) {
        // Determine if liveness has expired
        let submitted_time = *query.submitted_at_ms.borrow();
        if (current_time - submitted_time >= query.config.liveness_ms) {
            return QueryStatus::Expired
        }
        return QueryStatus::Submitted
    }
    
    // Has resolution?
    if (query.resolved_claim.is_some()) {
        QueryStatus::Resolved
    } else {
        QueryStatus::Challenged
    }
}
```

## Common Patterns

### Fast Settlement (Unchallenged)

Most queries follow this path:
1. Created (brief)
2. Submitted (liveness period)  
3. Expired (automatic)
4. Settled (manual trigger)

Timeline: ~1-24 hours depending on liveness period

### Disputed Settlement

Controversial queries follow this path:
1. Created (brief)
2. Submitted (brief, until challenged)
3. Challenged (until resolved)
4. Resolved (immediate)
5. Settled (manual trigger)

Timeline: Variable based on resolver speed

### Query Abandonment

Unused queries follow this path:
1. Created (until expiration)
2. Expired (automatic)
3. Settled (manual trigger to clean up)

Timeline: Whatever the expiration period was set to

## Error Conditions

### Invalid Transitions

The system prevents invalid state transitions:

```move
// Can't challenge in Created state
assert!(query.status(clock) == QueryStatus::Submitted, EInvalidQueryStatus);

// Can't submit claim twice
assert!(query.submitter.is_none(), EClaimAlreadySubmitted);

// Can't challenge your own claim
assert!(ctx.sender() != *query.submitter.borrow(), ECannotChallengeSelf);
```

### Timing Violations

Common timing errors and their prevention:

```move
// Submission too early
assert!(
    current_time - query.created_at_ms >= protocol.minimum_submission_delay_ms(),
    ESubmissionTooEarly
);

// Challenge too late
assert!(
    current_time - *query.submitted_at_ms.borrow() < query.config.liveness_ms,
    ELivenessExpired
);

// Expiration in past
assert!(config.expires_at_ms > current_time, EInvalidExpiration);
```

## Best Practices

### For Query Creators

- Set expiration time generously to allow for full lifecycle
- Choose liveness period based on data urgency and controversy risk
- Monitor queries and settle promptly when ready

### For Claim Submitters

- Submit accurate claims to avoid challenges
- Factor in challenge risk when deciding participation
- Monitor for challenges during liveness period

### For Challengers

- Challenge quickly to maximize resolution time
- Ensure you have strong evidence before challenging
- Understand the resolver's decision criteria

### For Integrators

- Always check query status before acting
- Handle all possible states in your integration
- Set up monitoring for queries you care about
- Plan for both fast and slow resolution paths

Understanding the query lifecycle helps you build robust integrations that handle all possible states and timing scenarios effectively.