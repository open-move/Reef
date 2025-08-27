# Reef Oracle: Optimistic Oracle Infrastructure for Real-World Data

**A Litepaper by the OpenMove Labs Team**

_Version 1.0 - August 2025_

---

## Abstract

Reef is an optimistic oracle system designed for Sui, which works based on the assumption that submitted data is correct unless challenged.

This model, first demonstrated by UMA, transforms the oracle problem from one of immediate verification to one of credible deterrence. By making false claims economically costly and truthful challenges profitable, Reef creates a self-regulating system that delivers fast, accurate data at a fraction of the cost of traditional oracle solutions.

Reef features a modular dispute resolution system, supporting everything from human committee voting to AI-powered resolution through secure enclaves leveraging Sui's Nautilus framework. With built-in economic incentives, topic whitelisting, and flexible settlement mechanisms, Reef provides a solid foundation for bringing any verifiable real-world data to Sui.

---

## Introduction

The oracle problem has persisted since the early days of smart contracts: how do you get reliable external data into a trustless, decentralized system? Traditional approaches have fallen into predictable patterns, each with their own tradeoffs.

Traditional oracles like Chainlink require continuous data updates and intensive operational overhead to maintain always-on feeds. Publisher-based oracles like Pyth provide on-demand access through curated data publishers, but still rely on predetermined feeds with immediate aggregation. UMA pioneered optimistic oracles, demonstrating that assuming data correctness unless challenged can be more efficient than immediate consensus.

Yet most real-world data requests don't actually need immediate dispute resolution. A smart contract asking "What was SUI's price at 12pm UTC on July 25th, 2025?" isn't looking for a philosophical debate about truth, it wants a value that everyone agrees is obviously correct. The key insight is that for most queries, the mere _possibility_ of being challenged and losing money is sufficient to ensure honest behavior.

This is the foundation of optimistic oracles, a concept pioneered by UMA Protocol. They demonstrated that economic deterrence can be more effective than immediate consensus for many oracle use cases. Reef builds on this foundation, bringing optimistic oracle infrastructure to Sui with new architectural choices and capabilities.

---

## The Oracle Problem

### Current State of Oracle Solutions

The oracle landscape today includes several established approaches, each with different tradeoffs:

**Traditional Oracles** like Chainlink operate through networks of nodes that aggregate data from multiple sources and push updates on-chain. While highly reliable for frequently-used data feeds, they require significant infrastructure and ongoing operational costs, making them expensive for one-off or infrequent queries.

**Publisher-Based Oracles** like Pyth Network allow data publishers to submit prices that are aggregated on demand. While efficient for financial data from known sources, they're limited to pre-established publisher sets and data types.

**Optimistic Oracles** introduced by UMA have demonstrated an alternative model where data is assumed correct unless challenged. This approach has proven effective on Ethereum and other chains, but hasn't yet been adapted to leverage Sui's unique architecture.

### The Need for Optimistic Systems on Sui

While optimistic oracles have proven successful on other chains, Sui's object-centric architecture and parallel execution model present unique opportunities for optimization. What's particularly compelling for Sui is handling the common case: requests for data that is objectively verifiable and rarely disputed. Consider these scenarios:

- "Who won the Newcastle vs Liverpool game on August 25th?"
- "What was the temperature in Lagos at 3PM UTC yesterday?"

These aren't matters of opinion requiring extensive deliberation. They're factual questions with clear, verifiable answers. The optimal system should:

1. Enable fast settlement through economic guarantees rather than immediate consensus
2. Create economic disincentives for false submissions
3. Offer credible dispute resolution for the rare disagreements
4. Incentivize honest participants by rewarding honest behavior

This is exactly what optimistic oracles deliver.

---

## Reef's Design Philosophy

### Optimism as a Feature, Not a Bug

Reef embraces optimism as its core design principle. Rather than treating every data submission as potentially false, the system assumes submissions are correct unless proven otherwise. This seemingly simple shift, first demonstrated by UMA's Optimistic Oracle, has profound implications:

**Speed**: Data becomes available on-chain upon submission, though most applications wait for the liveness period to expire before acting on it. Settlement occurs much faster than traditional verification methods, typically within minutes to hours rather than days.

**Cost**: Oracle usage has minimal costs beyond gas fees when query creators don't attach rewards. Resolution fees are only paid when disputes go to resolvers, typically by the losing party (submitter or challenger). This eliminates the continuous operational overhead of traditional oracle systems.

**Scalability**: The system can handle any number of queries without degradation. Sui's object-centric architecture enables parallel processing of independent queries, with each query existing as its own on-chain object that can be processed without global coordination until a dispute arises.

**Flexibility**: Any verifiable data can be requested, rather than being limited to pre-established feeds or markets. The bytes-first data architecture means any data type can be represented and verified through the oracle system.

### Economic Security Through Game Theory

The security of optimistic systems relies not on cryptographic guarantees or trusted hardware, but on economic incentives. Reef implements a carefully designed mechanism that makes honesty profitable and dishonesty costly:

**Bonding Requirements**: All participants must stake valuable tokens to participate, creating skin in the game.

**Winner-Takes-Most Settlement**: The winner takes most of both bonds. The loser loses their entire stake. Resolution fees are taken from the bond pool to pay resolvers.

**Resolution Fees**: Dispute resolution has a real cost. This prevents frivolous challenges while ensuring resolvers are compensated.

**Time Limits**: Queries have bounded challenge periods. This provides finality while allowing sufficient time for disputes.

### Modularity and Extensibility

Reef is built as a modular system where dispute resolution mechanisms can be plugged in and upgraded over time. The core protocol handles the economic logic—bonding, challenging, settling—while delegating the actual resolution of disputed facts to specialized resolver contracts.

This design enables the system to evolve with the ecosystem. Early deployments might rely on human committees for dispute resolution, while later versions could incorporate AI-powered resolvers, cross-chain verification systems, or even more sophisticated consensus mechanisms as they become available.

---

## Technical Architecture

### Core Components

Reef's architecture centers around four main components that work together to provide optimistic oracle functionality:

**Protocol Module**: The heart of the system, managing global configuration, economic parameters, and allowed data categories. This includes fee structures, minimum bonding requirements, topic whitelisting, and supported token types. The protocol module ensures consistency across all queries while providing governance mechanisms for parameter updates.

**Query Lifecycle Manager**: Handles the state transitions from query creation through final settlement. Queries progress through well-defined states (Created → Submitted → Challenged → Resolved → Settled), with strict rules about valid transitions and time-based expiration. This component also manages the economic flows, ensuring bonds are collected, fees are distributed, and settlements are executed correctly.

**Resolver Framework**: A pluggable system for dispute resolution that uses Sui's witness pattern for type-safe authorization. Resolvers can be anything from human committees to AI systems to cross-chain verification protocols. The framework ensures only authorized resolvers can create valid dispute resolutions while maintaining clear separation between the economic layer and the resolution mechanism.

**Event System**: Event emission for query lifecycle tracking, enabling external systems to monitor oracle activity, build analytics dashboards, and integrate oracle data into other applications.

### Data Flow

The typical data flow through Reef follows a predictable pattern optimized for the common case of undisputed claims:

1. **Query Creation**: A smart contract or external user creates a query specifying the question, required bond amount, challenge period duration, and expiration time. The query enters the "Created" state and awaits a claim submission.

2. **Claim Submission**: Someone submits a claim along with the required bond. The claim data becomes available on-chain, though most applications wait for the liveness period to expire before acting on it. The query enters the "Submitted" state and a challenge timer begins counting down.

3. **Challenge Period**: During the specified liveness period, anyone can challenge the claim by posting an equal bond and providing their own answer. If no challenge occurs before the timer expires, the query transitions to "Expired" state and can be settled in favor of the original submitter.

4. **Dispute Resolution**: If challenged, the query moves to "Challenged" state and a resolution fee is immediately deducted from the combined bond pool. The dispute is passed to the appropriate resolver, which determines the correct answer through whatever mechanism it implements (voting, computation, external verification, etc.).

5. **Settlement**: Once resolved (or if unchallenged), the query moves to "Settled" state and bond distributions occur. Winners receive their bond back plus the loser's bond (minus any resolution fees), while losers forfeit their stake entirely.

### Economic Model

Reef's economic model creates proper incentive alignment through several key mechanisms:

**Dynamic Bond Calculation**: Rather than fixed bond amounts, Reef calculates minimum bonds based on resolution fees and a configurable fee factor.

**Winner-Takes-Remaining-Bonds Settlement**: Unlike winner-takes-all mechanisms, Reef deducts resolution fees before distributing bonds to winners. This creates sustainable revenue for dispute resolution infrastructure while maintaining strong incentives for honest behavior.

**Multi-Asset Support**: The system supports any approved token type for bonds and fees, reducing dependence on any single asset and enabling queries to be denominated in the most appropriate token for their use case.

**Configurable Parameters**: Fee factors, minimum liveness periods, and other economic parameters can be adjusted through governance, allowing the system to evolve and optimize based on real-world usage patterns.

---

## Key Features

### Optimistic Data Delivery

The core value proposition of Reef is fast, cost-effective data settlement through optimistic assumptions. Rather than requiring expensive upfront verification, the system assumes data is correct unless challenged, dramatically reducing costs and settlement times compared to committee-based oracles.

When a claim is submitted to Reef, applications have two options: accept the data immediately with dispute risk, or wait for the liveness period to end for guaranteed settlement. Most production applications will wait for liveness to expire, but the optimistic model means this wait is typically much shorter and cheaper than traditional oracle verification.

This approach provides significant advantages:

- **Speed**: Settlement in minutes to hours (depending on configured liveness periods) rather than days or weeks
- **Cost**: No verification fees unless disputes actually occur
- **Flexibility**: Any verifiable data can be requested on-demand
- **Scalability**: No coordination overhead between multiple validators

Reef excels for applications where fast, economical settlement matters more than real-time data access, such as insurance claims, sports betting resolution, and cross-chain bridge finalization.

### Economic Security

Reef's security model is fundamentally economic rather than cryptographic. The system creates a game where honest behavior is profitable and dishonest behavior is costly, relying on rational economic actors to maintain data integrity.

**Staking Requirements**: All participants must post bonds to submit claims or challenge existing claims. These bonds are substantial enough to make false submissions economically unattractive while being reasonable for legitimate participants.

**Asymmetric Payoffs**: Winners take most of both bonds after resolution fees are deducted. Losers forfeit their entire stake. This creates strong incentives to monitor and correct false data while ensuring honest participants are rewarded.

**Resolution Costs**: Disputes incur real costs in the form of resolution fees paid to resolvers. This prevents frivolous challenges while ensuring that dispute resolution infrastructure remains sustainable.

**Reputation Effects**: While not explicitly tracked in the protocol, repeated dishonest behavior becomes economically unsustainable, creating implicit reputation systems and long-term incentive alignment.

### Modular Dispute Resolution

One of Reef's most powerful features is its modular approach to dispute resolution. Rather than hard-coding a single mechanism for resolving disputed claims, the system provides a framework that can accommodate different resolution strategies for different types of queries.

**Committee Resolution**: Human experts can be organized into committees that vote on disputed claims. This approach works well for subjective judgments or complex factual disputes that require domain expertise.

**Automated Resolution**: Disputes can be resolved through automated systems that verify claims against external APIs, databases, or other authoritative sources. This is ideal for objective factual queries with clear verification methods.

**AI-Powered Resolution**: Large language models and other AI systems can be used to resolve disputes, particularly when combined with secure execution environments to ensure the integrity of AI responses.

**Hybrid Systems**: Different resolution mechanisms can be combined or used as fallbacks. This can create sophisticated dispute resolution workflows tailored to specific use cases.

### Flexible Data Types

Unlike oracles that are optimized for specific data types (like price feeds), Reef is designed to handle arbitrary data represented as byte vectors. This flexibility enables a wide range of use cases:

**Structured Data**: JSON objects, protobuf messages, or custom binary formats can be submitted and verified.

**Simple Values**: Numbers, strings, booleans, and other primitive types can be easily encoded and decoded.

**Complex Objects**: Multi-part data like sports statistics, weather measurements, or financial reports can be encoded and submitted as single claims.

**Binary Data**: Hashes, signatures, images, or other binary content can be included directly.

This flexibility is enabled by treating all claims as opaque byte vectors at the protocol level while allowing resolvers and consuming applications to interpret the data according to their specific needs.

### Cross-Chain Compatibility

Reef's resolver system can verify data from external sources, including other blockchains. Resolvers can validate claims using data from Ethereum contracts, Bitcoin transactions, or any other blockchain by having off-chain components submit the relevant information for on-chain verification.

The bytes format ensures that data from different chains can be encoded consistently. A resolver handling cross-chain bridge deposits could verify transaction data from Ethereum, encode it as bytes, and submit the resolution to settle the Sui query.

---

## Use Cases

### Financial Data

The most obvious application for Reef is financial data, where speed and accuracy are both critical:

**Price Feeds**: Rather than maintaining expensive continuous price feeds, applications can request specific price points as needed.

**Cross-Chain Bridge Data**: Bridges can use Reef to verify the state of assets on other chains. Instead of running their own validator networks, they can request proof of specific transactions or account balances and rely on economic incentives to ensure accuracy.

**Interest Rate Data**: DeFi protocols can request interest rates from traditional financial markets, enabling more sophisticated yield strategies and risk management.

**Market Events**: Corporate actions, earnings announcements, regulatory changes, and other market-moving events can be reported through Reef with economic guarantees about their accuracy.

### Sports and Entertainment

Sports betting and fantasy applications are natural fits for optimistic oracles:

**Game Results**: "Who won the Lakers vs Celtics game on December 1st?" is a factual question with an obvious answer. Reef can settle these results within minutes to hours depending on the liveness period.

**Player Statistics**: Individual performance metrics, injury reports, and roster changes can be reported and verified through the oracle system.

**Tournament Outcomes**: Brackets, eliminations, and championship results can be settled quickly and fairly.

**Entertainment Events**: Awards shows, reality TV outcomes, and other entertainment events can be decided through the oracle system.

### Real-World Events

Reef can handle any verifiable real-world event:

**Weather Data**: Temperature, precipitation, storm tracking, and other weather information can be requested for specific times and locations.

**Election Results**: Voting outcomes, candidate selections, and ballot measure results can be reported and verified.

**News Events**: The occurrence of specific news events, policy changes, or public announcements can be confirmed through the oracle system.

**Supply Chain**: Shipment tracking, delivery confirmation, and quality certifications can be verified and reported.

### Technical Integration

Beyond human-readable data, Reef can verify technical information:

**API Responses**: The content of specific API calls can be verified, enabling smart contracts to react to off-chain system states.

**Computational Results**: Complex calculations or simulations can be performed off-chain and verified through the oracle system.

---

## Resolver Systems

### Committee Resolver

The committee resolver implements human-based dispute resolution through a staking and voting system. Committee members stake tokens to participate and vote on disputed claims, with economic penalties for incorrect votes and non-participation.

**Membership Management**: Users can join committees by staking a minimum amount of tokens. The stake serves both as a qualification mechanism and as collateral for honest behavior. Members can withdraw their stake after a cooling-off period, provided they have no pending disputes.

**Dispute Creation**: When a challenge occurs, a dispute is created and assigned to all eligible committee members. Members have a fixed time window to submit votes, with both commitment and reveal phases to prevent coordination attacks.

**Voting Process**: Committee members submit encrypted vote commitments during the commitment phase, then reveal their actual votes during the reveal phase. This prevents vote buying and reduces coordination attacks while ensuring transparency in the final results.

**Economic Incentives**: Committee members who vote with the majority earn a portion of the resolution fee, while those who vote incorrectly or fail to participate have their stakes slashed. This creates strong incentives for active participation and honest voting.

**Scalability**: Multiple committees can be created for different topic areas, allowing specialization and parallel processing of disputes. Committee membership can be automatically managed based on performance and stake levels.

### LLM Resolver

The LLM resolver represents an innovative approach to automated dispute resolution, using large language models to evaluate disputed claims while providing guarantees about the integrity of AI responses.

**Secure Execution**: LLM API calls are made from AWS Nitro Enclaves with responses cryptographically signed by the enclave and verified through Sui's Nautilus framework. AWS Nitro Enclaves provide attestation documents that are verified through Nautilus to prove the enclave is running unmodified code, significantly reducing trust assumptions by shifting trust from human operators to cryptographic attestation.

**Multi-Provider Support**: The resolver can integrate with multiple LLM providers (OpenAI, Anthropic, Google, etc.), enabling competition among AI systems and reducing dependence on any single provider.

**Response Verification**: LLM responses come with attestation proofs that are verified on-chain through Nautilus, proving the responses originated from the verified enclave running trusted code. This ensures that responses cannot be modified or falsified by human operators.

**API Key Security**: LLM provider API keys are stored securely within enclaves via AWS Secrets Manager, with minimal human exposure limited to initial provisioning, significantly reducing the risk of key compromise during operation.

### Custom Resolvers

The resolver framework is designed to be extensible. This enables developers to create custom resolution mechanisms for specialized use cases:

**Cross-Chain Verification**: Resolvers can verify data from other blockchains by having off-chain components fetch and submit the data for on-chain verification, enabling cross-chain oracle functionality.

**External API Integration**: Off-chain components can fetch data from external APIs and submit it to resolvers for on-chain verification of disputed claims.

**Computational Verification**: Complex calculations can be performed and verified by custom resolvers, enabling oracle-based access to computationally intensive results.

**Reputation-Based Systems**: While the core protocol doesn't track reputation, custom resolvers can incorporate reputation scores, historical accuracy, and other trust metrics to weight different sources of information.

---

## Economic Incentives

### Stakeholder Alignment

Reef's economic model creates positive-sum games where all honest participants benefit:

**Query Creators** get access to accurate data at predictable costs. They can add rewards to incentivize rapid response and can be confident that economic guarantees protect them from false information.

**Data Providers** earn returns on their bonds when submitting accurate information, and can earn additional rewards from query creators. The more accurate and responsive they are, the more profitable their operations become.

**Challengers** earn significant returns by identifying and correcting false information. This creates a distributed monitoring system where anyone can profit by maintaining data quality.

**Resolvers** earn fees for settling disputes, creating sustainable revenue streams for dispute resolution infrastructure. Better, faster resolution mechanisms can charge higher fees and attract more usage.

### Attack Resistance

The economic model provides strong resistance to various attack vectors:

**Spam Attacks**: All interactions require economic stakes, making spam expensive and unsustainable. Even if attackers are willing to lose money, the protocol earns fees from their attempts.

**False Information**: Submitting false claims requires staking bonds that will be lost when the false information is challenged. The potential losses outweigh any benefits from temporarily misleading smart contracts.

**Griefing Challenges**: Frivolous challenges require challengers to stake their own bonds and pay resolution fees. Unsuccessful challenges result in the loss of the challenger's entire stake, making griefing expensive.

**Collusion Attacks**: Collusion between submitters and challengers is economically difficult because resolution fees must still be paid, and honest third parties can always intervene to claim the economic rewards from correcting false information.

**Sybil Attacks**: The bonding requirements make creating multiple identities expensive, and the winner-takes-most settlement mechanism means that honest participants can always outcompete dishonest ones by being more accurate.

### Fee Structure Optimization

Reef's fee structure is designed to be self-optimizing through market mechanisms:

**Dynamic Bonding**: Bond requirements scale with resolution costs, ensuring that economic security matches the expense of dispute resolution.

**Competitive Resolution**: Multiple resolvers can compete for disputes, with query creators able to specify preferred resolution mechanisms. This creates market pressure for efficient, accurate resolution services.

**Usage-Based Parameters**: Fee factors and other economic parameters can be adjusted based on empirical data about dispute rates, resolution costs, and user behavior.

**Revenue Sustainability**: Resolution fees ensure that dispute resolution infrastructure remains economically viable even if dispute rates are low, preventing tragedy-of-the-commons scenarios.

---

## Security Model

### Economic Security

Reef's primary security mechanism is economic rather than cryptographic. The system relies on the assumption that participants are rational economic actors who respond predictably to incentives and penalties.

**Bonding Requirements**: The minimum bond calculation ensures that submitting false information is always more expensive than the potential benefit. Bonds are calculated based on resolution fees and configurable multipliers (typically 2-10x the resolution fee), creating predictable economic guarantees proportional to the dispute resolution cost rather than the query value itself.

**Challenge Economics**: Challengers must stake equal amounts to dispute claims, ensuring that challenges are economically meaningful while preventing unlimited griefing. Successful challenges are highly profitable, creating strong incentives for monitoring.

**Resolution Costs**: Dispute resolution has real costs that must be paid regardless of the outcome, preventing frivolous disputes while ensuring sustainable revenue for resolution infrastructure.

**Time Bounds**: All queries have expiration dates, preventing indefinite commitment of capital and ensuring finality within reasonable time frames.

### Technical Security

While economic incentives provide the primary security mechanism, several technical measures reinforce the system:

**Witness Pattern Authorization**: Sui's witness pattern ensures that only authorized resolvers can create valid dispute resolutions, preventing unauthorized access to the resolution system while maintaining type safety.

**Cryptographic Verification**: For resolvers using secure enclaves or other cryptographic systems, on-chain verification ensures that responses are authentic and unmodified.

**Event Transparency**: All protocol interactions emit detailed events, enabling external monitoring and analysis of system behavior.

**Governance Controls**: Protocol parameters can be updated through governance mechanisms, enabling response to changing conditions while maintaining decentralized control.

### Attack Vectors and Mitigations

**Long-Range Attacks**: Attackers might attempt to submit false information for queries with long challenge periods, hoping that monitoring decreases over time. Reef mitigates this through economic incentives that remain constant throughout the challenge period and through community monitoring tools.

**Eclipse Attacks**: Attackers might attempt to prevent honest challengers from seeing false submissions. Reef's open, permissionless design and event transparency make such attacks difficult to execute and expensive to maintain.

**Coordination Attacks**: Groups of attackers might coordinate to submit false information and avoid challenging each other. Reef mitigates this through open participation that allows honest actors to join at any time and profit from exposing coordination.

**Resolution Attacks**: Attackers might attempt to compromise resolution mechanisms. Reef's modular resolver design enables multiple resolution mechanisms and upgrades over time, reducing single points of failure.

**Governance Attacks**: Attackers might attempt to modify protocol parameters maliciously. Reef's governance mechanisms include time delays, community oversight, and emergency pause functionality to prevent such attacks.

---

## Conclusion

Reef brings the proven optimistic oracle model pioneered by UMA to Sui's unique architecture. Instead of trying to solve the hard problem of immediate verification, we embrace optimism and let economics handle the rest. This approach unlocks significant advantages in speed, cost, and flexibility while maintaining strong security guarantees through carefully designed incentive mechanisms.

The protocol's modular architecture enables continuous evolution, from simple human committees to sophisticated AI-powered resolution systems. As the blockchain ecosystem matures, Reef can grow with it, incorporating new verification methods and resolution mechanisms while maintaining backward compatibility and economic security.

---

## References

### Core Technologies

- **UMA Protocol**: [https://uma.xyz](https://uma.xyz) - Pioneer of optimistic oracle design
- **Sui Documentation**: [https://docs.sui.io](https://docs.sui.io) - Sui blockchain and Move language
- **Sui Nautilus**: [https://docs.sui.io/concepts/cryptography/nautilus](https://docs.sui.io/concepts/cryptography/nautilus) - Secure off-chain computation framework
- **AWS Nitro Enclaves**: [https://aws.amazon.com/ec2/nitro/nitro-enclaves/](https://aws.amazon.com/ec2/nitro/nitro-enclaves/) - Trusted execution environment

### Oracle Comparisons

- **Chainlink**: [https://chain.link](https://chain.link) - Decentralized oracle networks
- **Pyth Network**: [https://pyth.network](https://pyth.network) - Publisher-based price oracles

### Project Information

- **GitHub Repository**: [https://github.com/open-move/reef](https://github.com/open-move/reef)

---

_Copyright © 2025 OpenMove Labs. Released under the MIT License._
