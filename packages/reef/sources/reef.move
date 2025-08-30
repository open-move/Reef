/// This module implements the core logic for Reef, an optimistic oracle system that lets anyone
/// ask questions about real-world data and get claims secured by economic incentives.
///
/// How it works:
/// 1. Someone creates a Query asking a question (like "What was ETH price at noon?")
/// 2. Anyone can submit a claim by posting a bond
/// 3. Others can challenge that claim by posting their own bond
/// 4. If challenged, the dispute goes to a Resolver that determines the truth
/// 5. Whoever was right keeps their bond plus some of the loser's bond as reward
///
/// The key insight is that most claims won't be challenged because challenging costs money,
/// so you only challenge if you're confident the original claim is wrong. This means the
/// system is "optimistic" about claims being correct, but has teeth when they're not.
module reef::reef;

use reef::callback;
use reef::epoch::{Self, EpochManager};
use reef::protocol::{Self, Protocol};
use reef::resolver::{Self, Resolution, Challenge, Resolver};
use std::type_name::{Self, TypeName};
use sui::balance::Balance;
use sui::clock::Clock;
use sui::coin::Coin;
use sui::dynamic_field;
use sui::event;

/// ===== Error Codes =====

/// Insufficient bond amount
const EInsufficientBond: u64 = 0;
/// Query isn't in the right status for this operation
const EInvalidQueryStatus: u64 = 1;
/// Still within the challenge period
const ELivenessNotExpired: u64 = 2;
/// Caller doesn't have permission for this action
const ENotAuthorized: u64 = 3;
/// Using a coin type that's not allowed
const EInvalidCoinType: u64 = 4;
/// Liveness period doesn't meet requirements
const EInvalidLiveness: u64 = 5;
/// Query topic can't be empty
const EEmptyTopic: u64 = 6;
/// Query metadata can't be empty
const EEmptyMetadata: u64 = 7;
/// Trying to challenge a query with no claim
const EClaimNotSubmitted: u64 = 8;
/// Resolution is for a different query
const EWrongQueryResolution: u64 = 10;
/// Resolution came from wrong resolver type
const EWrongResolverType: u64 = 11;
/// Can't challenge your own claim
const ECannotChallengeSelf: u64 = 12;
/// Resolution is older than the challenge
const EStaleResolution: u64 = 13;
/// Topic exceeds maximum length
const ETooLongTopic: u64 = 14;
/// Metadata exceeds maximum length
const ETooLongMetadata: u64 = 15;
/// Topic not in whitelist
const EUnauthorizedTopic: u64 = 16;
/// Expiration time is in the past
const EInvalidExpiration: u64 = 17;
/// Expiration doesn't allow enough time for challenges
const EExpirationTooEarly: u64 = 18;
///
const EInvalidWitness: u64 = 19;

/// Size limits to prevent spam and storage bloat
const MAX_TOPIC_LENGTH: u64 = 256;
const MAX_METADATA_LENGTH: u64 = 12 * 1024;

const DEFAULT_LIVENESS_MS: u64 = 72_000_00;

/// Query represents a request for offchain data.
///
/// The lifecycle goes: Created -> Submitted -> (optionally) Challenged -> Resolved -> Settled
///
/// Most fields start as `none` and get filled in as the query progresses.
public struct Query has key {
    id: UID,
    /// Short topic like "ETH/USD"
    topic: vector<u8>,
    /// Detailed question and resolution criteria (Should we put this on Walrus??)
    metadata: vector<u8>,
    /// Historical timestamp, or `none` for event-based queries
    timestamp_ms: Option<u64>,
    /// Query config
    config: QueryConfig,
    /// Time when this query was created
    created_at_ms: u64,
    /// The epoch this query was created in
    epoch_id: u64,
    /// Which type of resolver can resolve disputes
    resolver_witness: TypeName,
    /// Type that created this query (useful for callbacks)
    creator_witness: TypeName,
    /// What token type is used for bonds/fees
    coin_type: TypeName,
    /// Whether settlement is complete (can't change after this)
    is_settled: bool,
    /// Address of the claim submitter (`none` = no claim yet)
    submitter: Option<address>,
    /// Amount of bond that must be posted to submit or challenge a claim
    bond_amount: u64,
    /// The claim that was originally submitted
    submitted_claim: Option<vector<u8>>,
    /// When claim was submitted
    submitted_at_ms: Option<u64>,
    /// Address of the challenger (`none` = no challenge)
    challenger: Option<address>,
    /// When the challenge was made
    challenged_at_ms: Option<u64>,
    /// The resolved claim after any challenge has been handled
    resolved_claim: Option<vector<u8>>,
}

/// Query specific config
public struct QueryConfig has copy, drop, store {
    /// How long challengers have to challenge a claim
    liveness_ms: u64,
    /// Hard deadline when query auto-expires
    expires_at_ms: u64,
    /// Where to send rewards if query gets challenged
    refund_address: Option<address>,
}

/// The possible statuses a query can be in at any given time.
///
/// This is determined dynamically based on the query's fields and current time,
/// rather than being stored directly.
public enum QueryStatus has copy, drop, store {
    Created,
    Submitted,
    Challenged,
    Resolved,
    Settled,
    Expired,
}

/// Keys for storing bonds and rewards in dynamic fields.

/// Key for storing & accessing bond
public struct BondKey() has copy, drop, store;
/// Key for storing & accessing reward
public struct RewardKey() has copy, drop, store;

public struct QueryCreated has copy, drop {
    query_id: ID,
    topic: vector<u8>,
    coin_type: TypeName,
    creator_witness: TypeName,
}

public struct ClaimSubmitted has copy, drop {
    query_id: ID,
    submitter: address,
    submitted_at_ms: u64,
}

public struct ClaimChallenged has copy, drop {
    query_id: ID,
    challenger: address,
    challenged_at_ms: u64,
}

public struct QueryResolved has copy, drop {
    query_id: ID,
    resolved_claim: Option<vector<u8>>,
}

/// Creates a new query.
///
/// This is the entry point for asking the oracle a question. The caller needs to:
/// 1. Set reasonable expiration and liveness periods
/// 2. Use a whitelisted topic and coin type
/// 3. Specify which type of resolver can resolve disputes
/// 4. Provide a bond amount that meets the minimum requirement
///
/// The witness pattern ensures only authorized contracts can create queries,
/// which helps prevent spam and ensures proper integration.
public fun create_query<CoinType, Witness: drop>(
    _witness: Witness,
    protocol: &mut Protocol,
    resolver: &Resolver,
    config: QueryConfig,
    bond_amount: u64,
    topic: vector<u8>,
    metadata: vector<u8>,
    timestamp_ms_maybe: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): Query {
    let coin_type = type_name::get<CoinType>();

    assert!(topic.length() > 0, EEmptyTopic);
    assert!(metadata.length() > 0, EEmptyMetadata);
    assert!(topic.length() <= MAX_TOPIC_LENGTH, ETooLongTopic);
    assert!(metadata.length() <= MAX_METADATA_LENGTH, ETooLongMetadata);

    assert!(protocol.is_topic_allowed(&topic), EUnauthorizedTopic);
    assert!(protocol.is_allowed_coin_type(coin_type), EInvalidCoinType);

    let current_time = clock.timestamp_ms();
    assert!(config.expires_at_ms > current_time, EInvalidExpiration);
    assert!(config.expires_at_ms > current_time + config.liveness_ms, EExpirationTooEarly);

    assert!(bond_amount >= protocol.minimum_bond(coin_type), EInsufficientBond);

    // For historical queries (timestamp provided), the timestamp must be in the past
    if (timestamp_ms_maybe.is_some()) {
        assert!(*timestamp_ms_maybe.borrow() <= current_time, EInvalidLiveness);
    };

    // Assign query to current epoch and record metrics
    let epoch_manager = protocol.epoch_manager_mut();
    let epoch_id = epoch_manager.current_epoch_id(clock);

    let query = Query {
        id: object::new(ctx),
        topic,
        config,
        metadata,
        epoch_id,
        coin_type,
        bond_amount,
        is_settled: false,
        submitter: option::none(),
        challenger: option::none(),
        resolved_claim: option::none(),
        submitted_claim: option::none(),
        submitted_at_ms: option::none(),
        challenged_at_ms: option::none(),
        timestamp_ms: timestamp_ms_maybe,
        created_at_ms: clock.timestamp_ms(),
        resolver_witness: resolver.witness_type(),
        creator_witness: type_name::get<Witness>(),
    };

    epoch_manager.record_query_created(epoch_id, bond_amount, query.coin_type, clock, ctx);

    event::emit(QueryCreated {
        topic: query.topic,
        coin_type: query.coin_type,
        query_id: query.id.to_inner(),
        creator_witness: query.creator_witness,
    });

    query
}

public fun share_query(query: Query) {
    transfer::share_object(query)
}

public fun create_query_config(
    liveness_ms_maybe: Option<u64>,
    expires_at_ms: u64,
    refund_address: Option<address>,
): QueryConfig {
    let liveness_ms = liveness_ms_maybe.destroy_with_default(DEFAULT_LIVENESS_MS);

    QueryConfig {
        liveness_ms,
        expires_at_ms,
        refund_address,
    }
}

/// Adds rewards to incentivize participation in a query.
public fun add_reward<RewardType, Witness: drop>(
    query: &mut Query,
    _: &Witness,
    reward: Coin<RewardType>,
    clock: &Clock,
) {
    assert!(query.status(clock) == QueryStatus::Created, EInvalidQueryStatus);
    assert!(query.creator_witness == type_name::get<Witness>(), EInvalidWitness);

    dynamic_field::add(&mut query.id, RewardKey(), reward.into_balance());
}

public fun set_refund_address<Witness: drop>(
    query: &mut Query,
    _: &Witness,
    refund_address: Option<address>,
    clock: &Clock,
) {
    assert!(query.status(clock) == QueryStatus::Created, EInvalidQueryStatus);
    assert!(query.creator_witness == type_name::get<Witness>(), EInvalidWitness);

    query.config.refund_address = refund_address
}

/// Submits a claim to a query by posting the required bond.
///
/// This is where someone commits to a claim and puts skin in the game.
/// They need to post exactly the bond amount specified in the query config.
///
/// Anyone who disagrees with this claim has a limited time to challenge it by posting
/// their own bond. If nobody challenges within the liveness period, this claim
/// becomes the accepted claim.
public fun submit_claim<CoinType>(
    query: &mut Query,
    claim: vector<u8>,
    bond: Coin<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(query.coin_type == type_name::get<CoinType>(), EInvalidCoinType);
    assert!(query.status(clock) == QueryStatus::Created, EInvalidQueryStatus);
    assert!(bond.value() == query.bond_amount, EInsufficientBond);

    query.collect_bond(bond);

    let current_time_ms = clock.timestamp_ms();
    query.submitted_at_ms.fill(current_time_ms);
    query.submitter.fill(ctx.sender());
    query.submitted_claim.fill(claim);

    event::emit(ClaimSubmitted {
        submitter: ctx.sender(),
        query_id: query.id.to_inner(),
        submitted_at_ms: current_time_ms,
    });
}

/// Challenges a submitted claim.
///
/// Anyone can challenge a claim if they think it's wrong, but they have post the competing bond.
///
/// The timing rules are important here:
/// 1. Submitter can't challenge their own claim
/// 2. Can only challenge during the "liveness period" after submission
/// 3. Can't challenge if the query has already expired
/// 4. Need to post the same bond amount as the original submitter
public fun challenge_claim<CoinType>(
    query: &mut Query,
    protocol: &mut Protocol,
    bond: Coin<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
): Challenge<CoinType> {
    assert!(ctx.sender() != *query.submitter.borrow(), ECannotChallengeSelf);
    assert!(query.status(clock) == QueryStatus::Submitted, EInvalidQueryStatus);
    assert!(query.submitted_at_ms.is_some(), EClaimNotSubmitted);

    let current_time_ms = clock.timestamp_ms();
    assert!(current_time_ms < query.config.expires_at_ms, EInvalidQueryStatus);
    assert!(
        current_time_ms - *query.submitted_at_ms.borrow() < query.config.liveness_ms,
        ELivenessNotExpired,
    );

    query.collect_bond(bond);

    query.challenged_at_ms.fill(current_time_ms);
    query.challenger.fill(ctx.sender());

    // If the query creator specified a refund address, send rewards there immediately
    query.config.refund_address.do_ref!(|addr| {
        query.transfer_balance<CoinType, RewardKey>(
            RewardKey(),
            *addr,
            ctx,
        )
    });

    let query_id = query.id.to_inner();
    let fee_amount = (
        (
            (protocol.fee_factor_bps() as u128) * (query.bond_amount as u128)
        ) / (protocol::bps!() as u128) as u64,
    );

    // Record challenge in the epoch
    let epoch_manager = protocol.epoch_manager_mut();

    let bond_balance = dynamic_field::borrow_mut<BondKey, Balance<CoinType>>(
        &mut query.id,
        BondKey(),
    );

    event::emit(ClaimChallenged {
        query_id: query_id,
        challenger: ctx.sender(),
        challenged_at_ms: current_time_ms,
    });

    resolver::new_challenge(
        query_id,
        bond_balance.split(fee_amount),
        ctx.sender(),
        current_time_ms,
        query.resolver_witness,
    )
}

/// Settles a query and distributes bonds/rewards according to the outcome.
///
///
/// For EXPIRED queries:
/// - If someone submitted a claim: they get their bond back + any rewards
/// - If nobody submitted a claim: rewards go to refund address if specified
///
/// For RESOLVED queries (for challenged claims):
/// - Winner gets remaining bond pool (resolution fee was already deducted during challenge) + rewards
public fun settle_query<CoinType>(
    query: &mut Query,
    resolution: Option<Resolution>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(query.coin_type == type_name::get<CoinType>(), EInvalidCoinType);

    // If there's a resolution and the query was challenged, apply it first
    if (resolution.is_some()) {
        assert!(query.status(clock) == QueryStatus::Challenged, EInvalidQueryStatus);
        query.apply_resolution(resolution.destroy_some());
    };

    query.winner(clock).do!(|addr| {
        query.transfer_balance<CoinType, BondKey>(BondKey(), addr, ctx);
        query.transfer_balance<CoinType, RewardKey>(RewardKey(), addr, ctx);
    });

    query.is_settled = true;
    event::emit(QueryResolved {
        query_id: query.id.to_inner(),
        resolved_claim: query.resolved_claim,
    });
}

fun winner(query: &Query, clock: &Clock): Option<address> {
    let status = query.status(clock);
    assert!(status == QueryStatus::Resolved || status == QueryStatus::Expired, EInvalidQueryStatus);
    if (query.resolved_claim == query.submitted_claim || status == QueryStatus::Expired) {
        query.submitter
    } else {
        query.challenger
    }
}

fun transfer_balance<CoinType, K: copy + drop + store>(
    query: &mut Query,
    key: K,
    recipient: address,
    ctx: &mut TxContext,
) {
    if (dynamic_field::exists_(&query.id, key)) {
        let bond_balance = dynamic_field::remove<K, Balance<CoinType>>(&mut query.id, key);
        transfer::public_transfer(bond_balance.into_coin(ctx), recipient);
    }
}

/// Collects and stores bond payments from participants
fun collect_bond<CoinType>(query: &mut Query, bond: Coin<CoinType>) {
    let bond_key = BondKey();
    if (!dynamic_field::exists_(&query.id, bond_key)) {
        dynamic_field::add(&mut query.id, bond_key, bond.into_balance());
    } else {
        let bond_balance = dynamic_field::borrow_mut<BondKey, Balance<CoinType>>(
            &mut query.id,
            bond_key,
        );

        bond_balance.join(bond.into_balance());
    }
}

/// Returns the status of query at a given time
public fun status(query: &Query, clock: &Clock): QueryStatus {
    let current_time = clock.timestamp_ms();

    if (query.submitter.is_none()) return QueryStatus::Created;
    if (query.is_settled) return QueryStatus::Settled;

    if (query.challenger.is_none()) {
        let submitted_time = *query.submitted_at_ms.borrow();
        if (current_time - submitted_time >= query.config.liveness_ms) {
            return QueryStatus::Expired
        };

        return QueryStatus::Submitted
    };

    if (query.resolved_claim.is_some()) {
        QueryStatus::Resolved
    } else {
        QueryStatus::Challenged
    }
}

/// Applies a dispute resolution to finalize what the correct claim was.
///
/// This gets called when an external resolver (like a committee or automated system)
/// has determined what the correct claim should be. We do several validation checks:
///
/// 1. Make sure this resolution is for the right query
/// 2. Ensure the resolution happened after the challenge
/// 3. Verify it came from the expected resolver type
fun apply_resolution(query: &mut Query, resolution: Resolution) {
    assert!(query.submitted_claim.is_some(), EClaimNotSubmitted);
    assert!(query.challenger.is_some(), ENotAuthorized);

    let submitted_claim = *query.submitted_claim.borrow();

    assert!(resolution.query_id() == query.id.to_inner(), EWrongQueryResolution);
    assert!(resolution.resolved_at_ms() > *query.challenged_at_ms.borrow(), EStaleResolution);
    assert!(resolution.witness_type() == query.resolver_witness, EWrongResolverType);

    if (submitted_claim == resolution.claim()) {
        query.resolved_claim = query.submitted_claim;
    } else {
        query.resolved_claim = option::some(resolution.claim());
    };
}

// === Getter Functions ===

public fun topic(query: &Query): vector<u8> {
    query.topic
}

public fun metadata(query: &Query): vector<u8> {
    query.metadata
}

public fun created_at_ms(query: &Query): u64 {
    query.created_at_ms
}

public fun epoch_id(query: &Query): u64 {
    query.epoch_id
}

public fun coin_type(query: &Query): TypeName {
    query.coin_type
}

public fun submitter(query: &Query): Option<address> {
    query.submitter
}

public fun submitted_claim(query: &Query): Option<vector<u8>> {
    query.submitted_claim
}

public fun submitted_at_ms(query: &Query): Option<u64> {
    query.submitted_at_ms
}

public fun challenger(query: &Query): Option<address> {
    query.challenger
}

public fun challenged_at_ms(query: &Query): Option<u64> {
    query.challenged_at_ms
}

public fun resolved_claim(query: &Query): Option<vector<u8>> {
    query.resolved_claim
}

public fun resolver_witness(query: &Query): TypeName {
    query.resolver_witness
}

public fun bond_amount(query: &Query): u64 {
    query.bond_amount
}

public fun total_bond<CoinType>(query: &Query): u64 {
    assert!(query.coin_type == type_name::get<CoinType>(), EInvalidCoinType);
    if (dynamic_field::exists_(&query.id, BondKey())) {
        let bond_balance = dynamic_field::borrow<BondKey, Balance<CoinType>>(&query.id, BondKey());
        bond_balance.value()
    } else {
        0
    }
}

public fun reward_amount<RewardType>(query: &Query): u64 {
    if (dynamic_field::exists_(&query.id, RewardKey())) {
        let reward_balance = dynamic_field::borrow<RewardKey, Balance<RewardType>>(
            &query.id,
            RewardKey(),
        );
        reward_balance.value()
    } else {
        0
    }
}

public fun expires_at_ms(query: &Query): u64 {
    query.config.expires_at_ms
}

public fun is_expired(query: &Query, clock: &Clock): bool {
    clock.timestamp_ms() >= query.config.expires_at_ms
}

public fun is_settled(query: &Query): bool {
    query.is_settled
}

public fun query_status_created(): QueryStatus {
    QueryStatus::Created
}

public fun query_status_submitted(): QueryStatus {
    QueryStatus::Submitted
}

public fun query_status_challenged(): QueryStatus {
    QueryStatus::Challenged
}

public fun query_status_resolved(): QueryStatus {
    QueryStatus::Resolved
}

public fun query_status_settled(): QueryStatus {
    QueryStatus::Settled
}

public fun query_status_expired(): QueryStatus {
    QueryStatus::Expired
}

public fun submit_claim_with_callback<CoinType>(
    query: &mut Query,
    claim: vector<u8>,
    bond: Coin<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
): callback::ClaimSubmitted {
    query.submit_claim(claim, bond, clock, ctx);

    callback::new_claim_submitted(
        query.id.to_inner(),
        ctx.sender(),
        claim,
        query.creator_witness,
    )
}

public fun challenge_claim_with_callback<CoinType>(
    query: &mut Query,
    protocol: &mut Protocol,
    bond: Coin<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Challenge<CoinType>, callback::ClaimChallenged) {
    let qc = query.challenge_claim(protocol, bond, clock, ctx);

    (
        qc,
        callback::new_claim_challenged(
            query.id.to_inner(),
            ctx.sender(),
            query.creator_witness,
        ),
    )
}

public fun settle_query_with_callback<CoinType>(
    query: &mut Query,
    resolution: Option<Resolution>,
    clock: &Clock,
    ctx: &mut TxContext,
): callback::QuerySettled {
    query.settle_query<CoinType>(resolution, clock, ctx);

    callback::new_query_settled(
        query.id.to_inner(),
        *query.resolved_claim.borrow(),
        query.creator_witness,
    )
}
