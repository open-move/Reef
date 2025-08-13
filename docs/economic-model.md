# Economic Model

Reef's security comes from economic incentives that make honest behavior profitable and dishonest behavior costly. Understanding these mechanics is crucial for effective participation in the oracle network.

## Core Economic Principles

### Optimistic Assumption

The system assumes most claims are correct, so it only requires expensive verification when someone stakes money to dispute a claim. This creates an efficient system where:

- Correct data flows quickly and cheaply
- Incorrect data gets expensive scrutiny
- Participants self-select based on confidence

### Symmetric Risk

Challengers must post the same bond amount as claim submitters. This prevents cheap griefing attacks while ensuring serious challenges get proper attention.

### Economic Finality

Once economic incentives have been resolved and bonds distributed, the result is final. There's no further appeal process - the economics ARE the security.

## Bond Mechanics

### Bond Requirements

Every claim must be backed by a bond in an approved token:

```move
// Bond amount set per query
bond: 1_000_000_000,  // 1 SUI

// Challenger must match exactly
challenge_bond: 1_000_000_000,  // Also 1 SUI
```

**Purpose of Bonds:**
- Prevent spam submissions
- Align incentives with truth-telling
- Create skin-in-the-game for participants
- Fund dispute resolution costs

### Bond Collection

Bonds are collected when claims are submitted and challenges are made:

```move
// Submitter provides bond
reef::submit_claim<SUI>(query, claim, bond_coin, clock, ctx);

// Challenger provides equal bond  
reef::challenge_claim<SUI>(query, challenge_bond_coin, clock, ctx);
```

Both bonds are held in the query object until settlement.

### Bond Distribution

The outcome determines how bonds are distributed:

#### Unchallenged Claims

- **Submitter**: Gets their bond back + any rewards
- **Creator**: Gets their creation fee back (if applicable)
- **Protocol**: Keeps protocol fees

#### Challenged Claims - Submitter Wins

- **Submitter**: Gets both bonds (minus burn) + rewards
- **Challenger**: Loses their bond
- **Protocol**: Burns portion of challenger's bond

#### Challenged Claims - Challenger Wins

- **Challenger**: Gets both bonds (minus burn)  
- **Submitter**: Loses their bond
- **Creator**: Gets rewards if refund address is set
- **Protocol**: Burns portion of submitter's bond

## Burn Mechanism

### Purpose of Burning

Burning serves several important functions:
- Punishes dishonest behavior beyond just losing the bond
- Creates deflationary pressure on bond tokens
- Funds protocol development and security
- Ensures disputes are costly for the losing party

### Burn Rate Calculation

```move
// Default burn rate: 50% of losing party's share
burn_rate_bps: 5000,  // 5000 basis points = 50%

// Applied to losing party's portion of total bond pool
let total_bonds = submitter_bond + challenger_bond;
let losing_party_share = total_bonds / 2;
let burn_amount = (losing_party_share * burn_rate_bps) / 10000;
```

### Example Calculations

With 1 SUI submitter bond, 1 SUI challenger bond, and 50% burn rate:

**If submitter loses:**
- Total bond pool: 2 SUI
- Submitter's share: 1 SUI  
- Burn amount: 0.5 SUI (50% of 1 SUI)
- Challenger receives: 1.5 SUI (2 SUI - 0.5 SUI burned)

**If challenger loses:**
- Total bond pool: 2 SUI
- Challenger's share: 1 SUI
- Burn amount: 0.5 SUI (50% of 1 SUI)
- Submitter receives: 1.5 SUI (2 SUI - 0.5 SUI burned)

## Reward System

### Optional Rewards

Query creators can add extra rewards to incentivize participation:

```move
// Add 0.1 SUI reward for successful claim
let reward_coin = coin::mint_for_testing<SUI>(100_000_000, ctx);
reef::add_reward<SUI, CreatorWitness>(query, witness, reward_coin, clock);
```

### Reward Distribution

Rewards go to the party that ends up being correct:

- **Unchallenged**: Submitter gets rewards
- **Challenged, submitter wins**: Submitter gets rewards  
- **Challenged, challenger wins**: Rewards go to refund address or remain locked

### Reward Strategy

Rewards create several strategic opportunities:

**For Creators:**
- Attract quality data providers
- Speed up claim submission
- Reduce challenge likelihood through higher accuracy

**For Participants:**
- Higher potential returns for accurate claims
- Risk/reward calculation includes both bonds and rewards

## Fee Structure

### Protocol Fees

Creators pay upfront fees when creating queries:

```move
// Set via protocol governance
fee_amounts: VecMap<TypeName, u64>,

// Example: 0.001 SUI fee for SUI-denominated queries
SUI: 1_000_000,  // 0.001 SUI in microSUI
```

**Fee Purposes:**
- Prevent query spam
- Fund protocol development
- Cover infrastructure costs
- Create sustainable economics

### Fee Collection

Fees are collected immediately upon query creation:

```move
// Creator must provide exact fee amount
let fee = coin::mint_for_testing<SUI>(protocol_fee_amount, ctx);
reef::create_query<SUI, Witness>(protocol, resolver, witness, fee, config, ...);
```

No refunds are provided regardless of query outcome.

## Economic Attack Scenarios

### Griefing Attacks

**Attack**: Submit false challenges to waste submitters' time and money.

**Prevention**: 
- Symmetric bond requirements make griefing expensive
- Burn mechanism punishes unsuccessful challenges
- Challenge must be resolved, creating resolver costs

**Economics**: Griefing costs attacker their entire bond plus burn amount.

### Bribery Attacks

**Attack**: Bribe resolver to make incorrect decisions.

**Prevention**:
- Multiple resolver options reduce single points of failure
- Reputation and governance mechanisms for resolver selection
- Bond burning creates ongoing costs even with bribery

**Economics**: Successful bribery must exceed bond values plus resolver reputation costs.

### Collusion Attacks

**Attack**: Submitter and challenger collude to extract rewards unfairly.

**Prevention**:
- Burn mechanism reduces available profits from collusion
- Resolver involvement adds third party to collusion
- Multiple queries dilute collusion impact

**Economics**: Collusion profits reduced by burn mechanism and resolver fees.

### Front-running Attacks

**Attack**: See pending queries and submit claims immediately.

**Prevention**:
- Minimum submission delay after query creation
- Creator can set parameters knowing this delay exists
- Equal opportunity for all participants during delay period

**Economics**: Delay creates level playing field for claim submission.

## Economic Parameter Tuning

### Bond Size Guidelines

Choose bond amounts based on:

**Data Value**: Higher stakes require higher bonds
```move
// Small price feeds
bond: 100_000_000,    // 0.1 SUI

// Major DeFi liquidations  
bond: 10_000_000_000, // 10 SUI
```

**Challenge Likelihood**: More controversial topics need higher bonds
```move
// Clear sports results
bond: 500_000_000,    // 0.5 SUI

// Subjective content moderation
bond: 5_000_000_000,  // 5 SUI
```

**Participation Incentives**: Balance accessibility with security
```move
// Encourage broad participation
bond: 50_000_000,     // 0.05 SUI

// Limit to serious participants
bond: 1_000_000_000,  // 1 SUI
```

### Liveness Period Guidelines

Balance speed vs security:

**Fast Data**: Short liveness for time-sensitive applications
```move
liveness_ms: 1800000,  // 30 minutes - price feeds
```

**Important Events**: Longer liveness for high-stakes decisions
```move
liveness_ms: 86400000, // 24 hours - major settlements
```

**Complex Verification**: Extended time for difficult questions
```move
liveness_ms: 604800000, // 1 week - complex analysis
```

### Burn Rate Guidelines

Consider ecosystem effects:

**Low Burn (25%)**: Encourage participation, gentler punishment
```move
burn_rate_bps: 2500,
```

**Medium Burn (50%)**: Default balanced approach
```move
burn_rate_bps: 5000,
```

**High Burn (75%)**: Discourage speculation, harsh punishment
```move
burn_rate_bps: 7500,
```

## Economic Sustainability

### Revenue Sources

The protocol generates revenue through:
- Query creation fees
- Burned bond portions
- Potential governance token fees (future)

### Cost Centers

The protocol incurs costs for:
- Infrastructure and development
- Security audits and monitoring
- Governance and administration
- Resolver incentives and subsidies

### Long-term Viability

Economic sustainability requires:
- Fee levels that cover operational costs
- Burn rates that discourage bad behavior without preventing participation
- Reward levels that attract quality data providers
- Growth in query volume to support fixed costs

The economic model is designed to be self-sustaining through careful balance of these parameters, adjusted based on real-world usage patterns and community governance.