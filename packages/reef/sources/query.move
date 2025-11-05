module reef::query;

use reef::callback;
use reef::macros;
use reef::protocol::Protocol;
use reef::query_inner::{Self, QueryInner, State};
use reef::resolver::{Resolver, Resolution, DisputeTicket};
use reef::schema;
use reef::versioned_object::{Self, VersionedObject};
use std::type_name;
use sui::clock::Clock;
use sui::coin::Coin;
use sui::derived_object;
use sui::event;

// ====== Error codes ======

/// Thrown when liveness period is below minimum required
const EInvalidLiveness: u64 = 1;
const ETopicSchemaNotFound: u64 = 2;
/// Thrown when coin type is not supported by protocol
const EUnsupportedCoinType: u64 = 3;
/// Thrown when query operation is not valid for current state
const EInvalidState: u64 = 4;
/// Thrown when timestamp is in the future relative to clock
const ETimestampInFuture: u64 = 5;
/// Thrown when trying to propose "too early" data for timestamp queries
const ECannotProposeTooEarly: u64 = 6;
/// Thrown when bond amount is below required minimum
const EInsufficientBond: u64 = 7;
/// Thrown when metadata exceeds maximum length
const EMetadataTooLong: u64 = 8;
/// Thrown when creator witness type doesn't match query creator
const EInvalidCreatorWitness: u64 = 10;
/// Thrown when query version doesn't match expected version
const EInvalidQueryVersion: u64 = 11;
/// Thrown when resolution query ID doesn't match the query being settled
const EWrongQueryResolution: u64 = 12;
/// Thrown when proposal data doesn't match schema
const EInvalidProposalData: u64 = 13;

/// Optimistic oracle request. Tracks the lifecycle from creation to
/// settlement, including bonds, proposals, disputes, and callbacks for a given
/// coin type `T`.
public struct Query<phantom T> has key, store {
    id: UID,
    inner: VersionedObject,
}

public struct QueryKey(u64) has copy, drop, store;

// ====== Events ======

public struct QueryCreated<phantom T> has copy, drop {
    query_id: ID,
    creator: address,
    topic: vector<u8>,
    bond_amount: u64,
    timestamp_ms: Option<u64>,
    schema_version: Option<u64>,
}

public struct DataProposed has copy, drop {
    query_id: ID,
    proposer: address,
    data: vector<u8>,
    bond_amount: u64,
    expires_at_ms: u64,
}

public struct ProposalDisputed has copy, drop {
    query_id: ID,
    disputer: address,
    disputed_at_ms: u64,
    bond_amount: u64,
}

/// Emitted when a reward is instantly refunded because the query was disputed
/// and the creator configured a refund address.
public struct RewardRefunded has copy, drop {
    query_id: ID,
    amount: u64,
}

public struct QuerySettled has copy, drop {
    query_id: ID,
    resolved_data: vector<u8>,
    winner: address,
    total_payout: u64,
}

/// Creates a new query with specified schema. The query starts in Created state
/// and validates all inputs against protocol constraints. Creator witness provides
/// authentication and determines callback authorization.
///
/// @param _witness Creator witness for authentication (consumed)
/// @param protocol Protocol instance for validation
/// @param resolver Resolver instance for dispute resolution
/// @param schema Schema defining data structure and validation
/// @param metadata Optional metadata bytes
/// @param timestamp_ms Optional timestamp for historical queries (must not be future)
/// @param callback_object_ids vector of object ids for callback integration
/// @param bond_amount Required bond amount (must meet protocol minimum)
/// @param clock System clock for timestamp validation
/// @param ctx Transaction context
///
/// @return New Query object ready to be shared
public fun create_with_schema<T, CreatorWitness: drop>(
    _: CreatorWitness,
    protocol: &mut Protocol,
    resolver: &Resolver,
    schema: query_inner::Schema,
    topic: vector<u8>,
    metadata: vector<u8>,
    timestamp_ms: Option<u64>,
    callback_object_ids: vector<ID>,
    bond_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Query<T> {
    assert!(protocol.is_coin_type_supported<T>(), EUnsupportedCoinType);
    assert!(bond_amount >= protocol.minimum_bond_amount<T>(), EInsufficientBond);
    assert!(metadata.length() <= macros::max_metadata_length!(), EMetadataTooLong);

    if (timestamp_ms.is_some()) {
        assert!(*timestamp_ms.borrow() <= clock.timestamp_ms(), ETimestampInFuture);
    };

    let query_index = protocol.num_queries();
    let mut query_uid = derived_object::claim(protocol.extend(), QueryKey(query_index));

    let query_inner = query_inner::create<T>(
        &mut query_uid,
        resolver.id(),
        schema,
        topic,
        metadata,
        protocol.default_liveness_ms(),
        timestamp_ms,
        callback_object_ids,
        type_name::with_defining_ids<CreatorWitness>(),
        bond_amount,
    );

    let schema_version = query_inner.schema_version();
    let query = Query {
        id: query_uid,
        inner: versioned_object::create(query_inner::current_query_version(), query_inner, ctx),
    };

    event::emit(QueryCreated<T> {
        topic,
        bond_amount,
        timestamp_ms,
        schema_version,
        creator: ctx.sender(),
        query_id: query.id.to_inner(),
    });

    protocol.increment_num_queries();

    query
}

/// Creates a new query with topic (backwards compatibility). Looks up schema from protocol.
/// The query starts in Created state and validates all inputs against protocol constraints.
///
/// @param _witness Creator witness for authentication (consumed)
/// @param protocol Protocol instance for validation
/// @param resolver Resolver instance for dispute resolution
/// @param topic Topic identifier (must be protocol-supported)
/// @param metadata Optional metadata bytes
/// @param timestamp_ms Optional timestamp for historical queries (must not be future)
/// @param callback_object_ids vector of object ids for callback integration
/// @param bond_amount Required bond amount (must meet protocol minimum)
/// @param clock System clock for timestamp validation
/// @param ctx Transaction context
///
/// @return New Query object ready to be shared
public fun create<T, CreatorWitness: drop>(
    witness: CreatorWitness,
    protocol: &mut Protocol,
    resolver: &Resolver,
    topic: vector<u8>,
    schema_version: u64,
    metadata: vector<u8>,
    timestamp_ms: Option<u64>,
    callback_object_ids: vector<ID>,
    bond_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Query<T> {
    assert!(protocol.has_topic_schema(topic, schema_version), ETopicSchemaNotFound);
    let schema = *protocol.topic_schema(topic, schema_version);

    create_with_schema<T, CreatorWitness>(
        witness,
        protocol,
        resolver,
        query_inner::new_standard_schema(schema, schema_version),
        topic,
        metadata,
        timestamp_ms,
        callback_object_ids,
        bond_amount,
        clock,
        ctx,
    )
}

/// Sets the liveness period for proposals on this query. Only callable before any
/// proposals are made. The liveness period determines how long proposals remain
/// open before expiring if not disputed.
///
/// @param query Query to modify (must be in Created state)
/// @param protocol Protocol instance for minimum validation
/// @param _witness Creator witness for authorization (consumed)
/// @param liveness_ms_maybe Optional liveness period in milliseconds (uses protocol default if None)
/// @param clock System clock for state validation
public fun set_liveness_ms<T, CreatorWitness: drop>(
    query: &mut Query<T>,
    protocol: &Protocol,
    _: CreatorWitness,
    liveness_ms_maybe: Option<u64>,
    clock: &Clock,
) {
    let query_inner = query.load_inner_mut<T>();
    assert!(query_inner.state(clock) == query_inner::state_created(), EInvalidState);
    assert!(
        query_inner.creator_witness() == type_name::with_defining_ids<CreatorWitness>(),
        EInvalidCreatorWitness,
    );

    let liveness_ms = liveness_ms_maybe.destroy_with_default(protocol.default_liveness_ms());
    assert!(liveness_ms >= macros::min_liveness_ms!(), EInvalidLiveness);
    query_inner.set_liveness_ms(liveness_ms)
}

/// Sets an optional refund address for rewards upon dispute. When set, any reward
/// balance will be immediately transferred to this address when a dispute occurs,
/// regardless of the dispute outcome.
///
/// @param query Query to modify (must be in Created state)
/// @param _witness Creator witness for authorization (consumed)
/// @param refund_address Optional address to receive rewards when disputed
/// @param clock System clock for state validation
public fun set_refund_address<T, CreatorWitness: drop>(
    query: &mut Query<T>,
    _: CreatorWitness,
    refund_address: Option<address>,
    clock: &Clock,
) {
    let query_inner = query.load_inner_mut<T>();
    assert!(query_inner.state(clock) == query_inner::state_created(), EInvalidState);
    assert!(
        query_inner.creator_witness() == type_name::with_defining_ids<CreatorWitness>(),
        EInvalidCreatorWitness,
    );

    query_inner.set_refund_address(refund_address);
}

/// Adds reward incentive for honest proposals. Rewards are distributed to the
/// winner upon settlement. Can only be called when query is in Created state.
///
/// @param query Query to add rewards to (must be in Created state)
/// @param reward Reward coins to incentivize proposals
/// @param clock System clock for state validation
public fun add_reward<T>(query: &mut Query<T>, reward: Coin<T>, clock: &Clock) {
    let query_inner = query.load_inner_mut<T>();
    assert!(query_inner.state(clock) == query_inner::state_created(), EInvalidState);
    query_inner.add_reward(reward.into_balance())
}

/// Proposes data for the query with a bond. Transitions query to Proposed state
/// and starts the liveness countdown. Bond is held until settlement. For timestamp
/// queries, cannot propose "too early" marker unless timestamp is set.
///
/// @param query Query to propose data for (must be in Created state)
/// @param bond Bond payment (must meet minimum amount)
/// @param data Proposed data bytes (cannot be "too early" marker for timestamp queries)
/// @param clock System clock for expiration calculation
/// @param ctx Transaction context
///
/// Emits DataProposed event
public fun propose_data<T>(
    query: &mut Query<T>,
    bond: Coin<T>,
    data: vector<u8>,
    clock: &Clock,
    ctx: &TxContext,
) {
    let query_inner = query.load_inner_mut<T>();
    assert!(query_inner.state(clock) == query_inner::state_created(), EInvalidState);

    // For non-timestamp queries, reject "too_early" value as it's only
    // meaningful for timestamp-based queries where data might not yet exist.
    // Event-based queries should provide actual data or "unresolvable".
    assert!(
        !(query_inner.timestamp_ms().is_none() && data == macros::too_early!()),
        ECannotProposeTooEarly,
    );

    assert!(query_inner.schema().validate(&data), EInvalidProposalData);
    let (proposer, bond_amount, expires_at_ms) = query_inner.propose_data(
        bond.into_balance(),
        data,
        ctx.sender(),
        clock,
    );
    event::emit(DataProposed {
        data,
        proposer,
        bond_amount,
        expires_at_ms,
        query_id: query.id.to_inner(),
    });
}

/// Disputes the current proposal by posting a bond. Transitions query to Disputed
/// state and stops the expiration timer. Creates dispute ticket for resolver processing.
///
/// @param protocol Protocol object
/// @param query Query with proposal to dispute (must be in Proposed state)
/// @param bond Bond payment (must meet minimum amount)
/// @param clock System clock for timing validation
/// @param ctx Transaction context
///
/// @return DisputeTicket for resolver processing
///
/// Emits ProposalDisputed event
public fun dispute_proposal<T>(
    protocol: &Protocol,
    query: &mut Query<T>,
    bond: Coin<T>,
    clock: &Clock,
    ctx: &mut TxContext,
): DisputeTicket<T> {
    let query_id = query.id.to_inner();
    let query_inner = query.load_inner_mut<T>();
    assert!(query_inner.state(clock) == query_inner::state_proposed(), EInvalidState);

    let (ticket, disputer, bond_amount, refund_amount) = query_inner.dispute_proposal(
        bond.into_balance(),
        protocol.fee_factor_bps(),
        ctx.sender(),
        clock,
        ctx,
    );

    if (refund_amount > 0 && query_inner.refund_address().is_some()) {
        event::emit(RewardRefunded { amount: refund_amount, query_id });
    };

    event::emit(ProposalDisputed {
        disputer,
        query_id,
        bond_amount,
        disputed_at_ms: clock.timestamp_ms(),
    });

    ticket
}

/// Settles the query by distributing bonds to the winner. For disputed queries,
/// requires resolution from authorized resolver. For expired queries, automatically
/// awards to proposer. Winner determination based on data match for resolutions.
///
/// @param query Query to settle (must be Disputed with resolution OR Expired)
/// @param resolution_maybe Optional resolution from resolver (required for disputed queries)
/// @param clock System clock for state validation
/// @param ctx Transaction context
///
/// Transfers all bonds to winner and emits QuerySettled event
public fun settle<T>(
    query: &mut Query<T>,
    resolution_maybe: Option<Resolution>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let query_id = query.id.to_inner();
    let query_inner = query.load_inner_mut<T>();
    resolution_maybe.do_ref!(|r| {
        assert!(r.query_id() == query_id, EWrongQueryResolution);
        assert!(query_inner.schema().validate(&r.data()), EInvalidProposalData);
    });

    let (winner, total_payout, resolved_data) = query_inner.settle(resolution_maybe, clock, ctx);

    event::emit(QuerySettled {
        winner,
        query_id,
        total_payout,
        resolved_data,
    });
}

/// Settles the query and returns a callback object for external integrations.
/// Performs same settlement logic as settle() but provides structured callback
/// data for contracts that need to react to query resolution.
///
/// @param query Query to settle
/// @param resolution Optional resolution from resolver
/// @param clock System clock for validation
/// @param ctx Transaction context
///
/// @return QuerySettled callback struct for external contract integration
public fun settle_with_callback<T>(
    query: &mut Query<T>,
    resolution_maybe: Option<Resolution>,
    clock: &Clock,
    ctx: &mut TxContext,
): callback::QuerySettled {
    let query_id = query.id.to_inner();
    resolution_maybe.do_ref!(|r| assert!(r.query_id() ==query_id, EWrongQueryResolution));

    let query_inner = query.load_inner_mut<T>();
    let creator_witness = query_inner.creator_witness();
    let (winner, total_payout, resolved_data) = query_inner.settle(resolution_maybe, clock, ctx);

    event::emit(QuerySettled {
        winner,
        total_payout,
        resolved_data,
        query_id,
    });

    callback::new_query_settled(
        query_id,
        resolved_data,
        creator_witness,
    )
}

// These functions are now handled entirely in query_inner.move

// ====== View Functions ======

/// Returns the current state of the query based on time and internal state.
/// State transitions: Created -> Proposed -> (Expired OR Disputed) -> Resolved -> Settled.
/// Time-based transitions occur automatically based on proposal expiration.
///
/// @param query Query to check
/// @param clock System clock for time-based state transitions
///
/// @return Current State (Created, Proposed, Expired, Disputed, Resolved, or Settled)
public fun state<T>(query: &Query<T>, clock: &Clock): State {
    query.load_inner<T>().state(clock)
}

/// Returns the topic identifier for this query.
///
/// @param query Query object
///
/// @return Topic bytes (empty for custom schemas)
public fun topic<T>(query: &Query<T>): vector<u8> {
    query.load_inner<T>().topic()
}

/// Returns the schema for this query.
///
/// @param query Query object
///
/// @return Query schema
public fun schema<T>(query: &Query<T>): &schema::Schema {
    query.load_inner<T>().schema()
}

/// Returns the metadata associated with this query.
///
/// @param query Query object
///
/// @return Metadata bytes
public fun metadata<T>(query: &Query<T>): vector<u8> {
    query.load_inner<T>().metadata()
}

/// Returns the required bond amount for proposals and disputes.
///
/// @param query Query object
///
/// @return Bond amount in coin units
public fun bond_amount<T>(query: &Query<T>): u64 {
    query.load_inner<T>().bond_amount()
}

/// Returns the callback object IDs for external integrations.
///
/// @param query Query object
///
/// @return Vector of object IDs for callbacks
public fun callback_object_ids<T>(query: &Query<T>): vector<ID> {
    query.load_inner<T>().callback_object_ids()
}

/// Returns the proposal data if one exists.
public fun proposal_data<T>(query: &Query<T>): Option<vector<u8>> {
    query.load_inner<T>().proposal_data()
}

/// Returns the proposer address if a proposal exists.
public fun proposer<T>(query: &Query<T>): Option<address> {
    query.load_inner<T>().proposer()
}

/// Returns when the proposal expires (in milliseconds).
public fun expires_at_ms<T>(query: &Query<T>): Option<u64> {
    query.load_inner<T>().expires_at_ms()
}

/// Returns the disputer address if the proposal was disputed.
public fun disputer<T>(query: &Query<T>): Option<address> {
    query.load_inner<T>().disputer()
}

/// Returns when the proposal was disputed (in milliseconds).
public fun disputed_at_ms<T>(query: &Query<T>): Option<u64> {
    query.load_inner<T>().disputed_at_ms()
}

/// Returns the resolved data if the query has been resolved.
public fun resolved_data<T>(query: &Query<T>): Option<vector<u8>> {
    query.load_inner<T>().resolved_data()
}

/// Returns whether the query has been settled.
public fun is_settled<T>(query: &Query<T>): bool {
    query.load_inner<T>().is_settled()
}

/// Returns the optional timestamp this query is for.
public fun timestamp_ms<T>(query: &Query<T>): Option<u64> {
    query.load_inner<T>().timestamp_ms()
}

/// Returns the liveness period in milliseconds.
public fun liveness_ms<T>(query: &Query<T>): u64 {
    query.load_inner<T>().liveness_ms()
}

/// Returns the refund address if one is set.
public fun refund_address<T>(query: &Query<T>): Option<address> {
    query.load_inner<T>().refund_address()
}

public fun id<T>(query: &Query<T>): ID {
    query.id.to_inner()
}

public fun state_created(): State {
    query_inner::state_created()
}

public fun state_proposed(): State {
    query_inner::state_proposed()
}

public fun state_expired(): State {
    query_inner::state_expired()
}

public fun state_disputed(): State {
    query_inner::state_disputed()
}

public fun state_resolved(): State {
    query_inner::state_resolved()
}

public fun state_settled(): State {
    query_inner::state_settled()
}

/// Loads the immutable inner query for the current version.
fun load_inner<T>(query: &Query<T>): &QueryInner<T> {
    assert!(query.inner.version() == query_inner::current_query_version(), EInvalidQueryVersion);
    query.inner.load_value()
}

/// Loads the mutable inner query for the current version.
fun load_inner_mut<T>(query: &mut Query<T>): &mut QueryInner<T> {
    assert!(query.inner.version() == query_inner::current_query_version(), EInvalidQueryVersion);
    query.inner.load_value_mut()
}
