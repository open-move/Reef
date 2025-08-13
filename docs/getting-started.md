# Getting Started with Reef Oracle

This guide walks you through setting up and using Reef Oracle for the first time.

## Prerequisites

Before you begin, make sure you have:

- [Sui CLI](https://docs.sui.io/guides/developer/getting-started/sui-install) installed and configured
- Basic understanding of Move programming language
- A Sui wallet with some SUI tokens for gas fees

## Installation

### Option 1: Clone the Repository

```bash
git clone <repository-url>
cd reef
```

### Option 2: Add as Dependency

Add Reef to your `Move.toml` file:

```toml
[dependencies]
Reef = { git = "https://github.com/your-org/reef.git", subdir = "packages/reef", rev = "main" }
```

## Building the Project

Navigate to the reef package directory and build:

```bash
cd packages/reef
sui move build
```

If the build succeeds, you're ready to use Reef!

## Running Tests

Verify everything works by running the test suite:

```bash
sui move test
```

You should see output indicating all tests pass.

## Basic Concepts

Before diving into code, understand these key concepts:

**Query**: A request for specific data with defined parameters

**Bond**: Money put at risk to participate in the oracle process

**Liveness Period**: Time window during which claims can be challenged

**Resolver**: System that determines truth when claims are disputed

## Your First Query

Let's create a simple price feed query. This example shows the basic pattern:

### 1. Initialize the Protocol

First, set up the global protocol configuration:

```move
use reef::protocol;

// Initialize protocol with default settings
let (protocol, protocol_cap) = protocol::initialize_for_testing(ctx);

// Configure allowed topics and coin types
protocol::add_allowed_topic(&mut protocol, &protocol_cap, b"ETH/USD");
protocol::add_allowed_coin_type(&mut protocol, &protocol_cap, type_name::get<SUI>());
protocol::set_fee_amount(&mut protocol, &protocol_cap, type_name::get<SUI>(), 1_000_000); // 0.001 SUI
```

### 2. Create a Resolver

Set up a resolver that can handle disputes:

```move
use reef::resolver;

// Create a simple admin resolver
let resolver = resolver::create(AdminWitness {}, publisher, ctx);
resolver::enable(&mut resolver, &protocol_cap);
resolver.share();
```

### 3. Create Your Query

Now create a query asking for ETH price data:

```move
use reef::reef;

// Configure the query parameters
let config = reef::create_query_config(
    1_000_000_000,        // 1 SUI bond required
    option::some(3600000), // 1 hour challenge window
    clock.timestamp_ms() + 86400000, // Expires in 24 hours
    option::none()         // No specific refund address
);

// Pay the protocol fee
let fee = coin::mint_for_testing<SUI>(1_000_000, ctx);

// Create the query
let query = reef::create_query<SUI, YourWitness>(
    &mut protocol,
    &resolver,
    YourWitness {},
    fee,
    config,
    b"ETH/USD",
    b"Current ETH price in USD with 6 decimal precision",
    option::none(), // Not a historical query
    &clock,
    ctx
);

query.share();
```

### 4. Submit a Claim

Someone (typically an oracle operator) submits data:

```move
// Create bond payment
let bond = coin::mint_for_testing<SUI>(1_000_000_000, ctx);

// Submit price claim: $3,500.50 with 6 decimals
let price_bytes = bcs::to_bytes(&3500500000u64);

reef::submit_claim<SUI>(
    &mut query,
    &protocol,
    price_bytes,
    bond,
    &clock,
    ctx
);
```

### 5. Challenge (Optional)

If someone disagrees with the claim, they can challenge it:

```move
// Challenger must post equal bond
let challenge_bond = coin::mint_for_testing<SUI>(1_000_000_000, ctx);

let challenge_request = reef::challenge_claim<SUI>(
    &mut query,
    challenge_bond,
    &clock,
    ctx
);

// Challenge request must be handled by the resolver...
```

### 6. Settle the Query

After the liveness period, settle the query:

```move
// If unchallenged, pass none for resolution
reef::settle_query<SUI>(
    &mut query,
    &mut protocol,
    option::none(), // No resolution needed if unchallenged
    &clock,
    ctx
);
```

## Reading Query Results

Once settled, other contracts can read the final answer:

```move
// Get the resolved claim data
let resolved_claim = query.resolved_claim();

if (resolved_claim.is_some()) {
    let price_bytes = resolved_claim.destroy_some();
    let price: u64 = bcs::from_bytes(&price_bytes);
    // price now contains 3500500000 (representing $3,500.50)
}
```

## Next Steps

This basic example shows the core workflow. For production use, you'll want to:

1. **Set up proper governance** for protocol parameters
2. **Implement robust resolvers** for handling disputes
3. **Add reward mechanisms** to incentivize participation
4. **Monitor query activity** and adjust economic parameters

Continue reading:

- [Architecture](architecture.md) - Understand how the system fits together
- [Query Lifecycle](query-lifecycle.md) - Deep dive into query states and transitions
- [Integration Guide](integration-guide.md) - Best practices for using Reef in your project

## Common Patterns

### Price Feeds

```move
// Configure for high-frequency price updates
let config = reef::create_query_config(
    100_000_000,           // Lower bond for frequent updates
    option::some(1800000), // 30 minute challenge window
    clock.timestamp_ms() + 3600000, // 1 hour expiry
    option::some(treasury_address)   // Send rewards to treasury
);
```

### Event Results

```move
// Configure for one-time event resolution
let config = reef::create_query_config(
    5_000_000_000,         // Higher bond for important events
    option::some(86400000), // 24 hour challenge window
    clock.timestamp_ms() + 604800000, // 1 week expiry
    option::none()          // Creator gets rewards
);
```

### Cross-chain Verification

```move
// Configure for cross-chain data with longer settlement
let config = reef::create_query_config(
    1_000_000_000,          // Standard bond
    option::some(7200000),  // 2 hour challenge window
    clock.timestamp_ms() + 172800000, // 2 day expiry
    option::none()
);
```

Remember: the key to successful oracle usage is balancing speed, security, and cost through appropriate parameter choices.