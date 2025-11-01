module reef::query;

use reef::callback;
use reef::protocol::{Self, Protocol};
use reef::resolver::{Self, Resolver, Resolution, DisputeTicket};
use std::type_name::{Self, TypeName};
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::Coin;
use sui::event;

// ====== Error codes ======

/// Thrown when liveness period is below minimum required
const EInvalidLiveness: u64 = 1;
/// Thrown when query topic is not supported by protocol
const EUnsupportedTopic: u64 = 2;
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
/// Thrown when trying to apply resolution but no proposal/dispute exists
const EDataNotProposed: u64 = 11;
/// Thrown when resolution query ID doesn't match the query being settled
const EWrongQueryResolution: u64 = 12;
/// Thrown when resolution timestamp is before dispute timestamp
const EStaleResolution: u64 = 13;
/// Thrown when resolution witness type doesn't match resolver
const EWrongResolverType: u64 = 14;
/// Thrown when query state is invalid for winner determination
const EInvalidQueryStatus: u64 = 15;

public struct Query<phantom T> has key, store {
    id: UID,
    settled: bool,
    resolver_id: ID,
    bond_amount: u64,
    topic: vector<u8>,
    config: Config,
    metadata: vector<u8>,
    balances: Balances<T>,
    dispute: Option<Dispute>,
    timestamp_ms: Option<u64>,
    creator_witness: TypeName,
    proposal: Option<Proposal>,
    callback_object_id: Option<ID>,
    resolved_data: Option<vector<u8>>,
}

public struct Balances<phantom T> has store {
    bond: Balance<T>,
    reward: Balance<T>,
}

public struct Proposal has store {
    data: vector<u8>,
    proposer: address,
    expires_at_ms: u64,
    proposed_at_ms: u64,
}

public struct Dispute has store {
    disputer: address,
    disputed_at_ms: u64,
}

public struct Config has copy, drop, store {
    liveness_ms: u64,
    refund_address: Option<address>,
}

public enum State has copy, drop, store {
    Created,
    Proposed,
    Expired,
    Disputed,
    Resolved,
    Settled,
}

// ====== Events ======

public struct QueryCreated<phantom T> has copy, drop {
    query_id: ID,
    creator: address,
    topic: vector<u8>,
    bond_amount: u64,
    timestamp_ms: Option<u64>,
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

public struct QuerySettled has copy, drop {
    query_id: ID,
    resolved_data: vector<u8>,
    winner: address,
    total_payout: u64,
}

/// Creates a new query with specified parameters. The query starts in Created state
/// and validates all inputs against protocol constraints. Creator witness provides
/// authentication and determines callback authorization.
///
/// @param _witness Creator witness for authentication (consumed)
/// @param protocol Protocol instance for validation
/// @param resolver Resolver instance for dispute resolution
/// @param topic Topic identifier (must be protocol-supported)
/// @param metadata Optional metadata bytes
/// @param timestamp_ms Optional timestamp for historical queries (must not be future)
/// @param callback_object_id Optional ID for callback integration
/// @param bond_amount Required bond amount (must meet protocol minimum)
/// @param clock System clock for timestamp validation
/// @param ctx Transaction context
///
/// @return New Query object ready to be shared
public fun create<T, CreatorWitness: drop>(
    _: CreatorWitness,
    protocol: &Protocol,
    resolver: &Resolver,
    topic: vector<u8>,
    metadata: vector<u8>,
    timestamp_ms: Option<u64>,
    callback_object_id: Option<ID>,
    bond_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Query<T> {
    assert!(protocol.is_topic_supported(topic), EUnsupportedTopic);
    assert!(protocol.is_coin_type_supported<T>(), EUnsupportedCoinType);
    assert!(bond_amount >= protocol.minimum_bond<T>(), EInsufficientBond);
    assert!(metadata.length() <= max_metadata_length!(), EMetadataTooLong);

    if (timestamp_ms.is_some()) {
        assert!(*timestamp_ms.borrow() <= clock.timestamp_ms(), ETimestampInFuture);
    };

    let query = Query {
        id: object::new(ctx),
        topic,
        metadata,
        bond_amount,
        timestamp_ms,
        settled: false,
        callback_object_id,
        dispute: option::none(),
        proposal: option::none(),
        resolver_id: resolver.id(),
        resolved_data: option::none(),
        balances: Balances {
            bond: balance::zero(),
            reward: balance::zero(),
        },
        config: Config {
            refund_address: option::none(),
            liveness_ms: protocol.default_liveness_ms(),
        },
        creator_witness: type_name::with_defining_ids<CreatorWitness>(),
    };

    event::emit(QueryCreated<T> {
        topic,
        bond_amount,
        timestamp_ms,
        creator: ctx.sender(),
        query_id: query.id.to_inner(),
    });

    query
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
    assert!(query.state(clock) == State::Created, EInvalidState);
    assert!(
        query.creator_witness == type_name::with_defining_ids<CreatorWitness>(),
        EInvalidCreatorWitness,
    );

    let liveness_ms = liveness_ms_maybe.destroy_with_default(protocol.default_liveness_ms());
    assert!(liveness_ms >= protocol::min_liveness_ms!(), EInvalidLiveness);

    query.config.liveness_ms = liveness_ms;
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
    assert!(query.state(clock) == State::Created, EInvalidState);
    assert!(
        query.creator_witness == type_name::with_defining_ids<CreatorWitness>(),
        EInvalidCreatorWitness,
    );

    query.config.refund_address = refund_address;
}

/// Adds reward incentive for honest proposals. Rewards are distributed to the
/// winner upon settlement. Can only be called when query is in Created state.
///
/// @param query Query to add rewards to (must be in Created state)
/// @param reward Reward coins to incentivize proposals
/// @param clock System clock for state validation
public fun add_reward<T>(query: &mut Query<T>, reward: Coin<T>, clock: &Clock) {
    assert!(query.state(clock) == State::Created, EInvalidState);
    query.balances.reward.join(reward.into_balance());
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
    ctx: &mut TxContext,
) {
    assert!(query.state(clock) == State::Created, EInvalidState);

    // For non-timestamp queries, reject "too_early" value as it's only
    // meaningful for timestamp-based queries where data might not yet exist.
    // Event-based queries should provide actual data or "unresolvable".
    assert!(!(query.timestamp_ms.is_none() && data == too_early!()), ECannotProposeTooEarly);

    let bond_amount = bond.value();
    let current_time_ms = clock.timestamp_ms();
    assert!(bond_amount >= query.bond_amount, EInsufficientBond);

    let proposer = ctx.sender();
    let expires_at_ms = query.config.liveness_ms + current_time_ms;

    query
        .proposal
        .fill(Proposal {
            data,
            proposer,
            expires_at_ms,
            proposed_at_ms: current_time_ms,
        });

    query.balances.bond.join(bond.into_balance());

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
    assert!(query.state(clock) == State::Proposed, EInvalidState);
    let bond_amount = bond.value();
    assert!(bond_amount >= query.bond_amount, EInsufficientBond);

    let disputer = ctx.sender();
    let disputed_at_ms = clock.timestamp_ms();

    query
        .dispute
        .fill(Dispute {
            disputer,
            disputed_at_ms,
        });

    query.balances.bond.join(bond.into_balance());

    event::emit(ProposalDisputed {
        disputer,
        bond_amount,
        disputed_at_ms,
        query_id: query.id.to_inner(),
    });

    let fee_amount =
        (
            (protocol.fee_factor_bps() as u128) * (query.bond_amount as u128)
         / (protocol::bps!() as u128),
        ) as u64;

    let verification_bond_amount = query.balances.bond.value();
    resolver::new_dispute_ticket<T>(
        query.id.to_inner(),
        query.resolver_id,
        query.balances.bond.split(fee_amount),
        disputer,
        disputed_at_ms,
        // the required bond whoever is challenging the resolver decision has to pay
        verification_bond_amount,
    )
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
    if (resolution_maybe.is_some()) {
        assert!(query.state(clock) == State::Disputed, EInvalidState);
        query.apply_resolution(resolution_maybe.destroy_some());
    } else {
        assert!(query.state(clock) == State::Expired, EInvalidState);

        query.proposal.do_ref!(|proposal_ref| {
            query.resolved_data.fill(proposal_ref.data);
        });
    };

    let state = query.state(clock);
    assert!(state == State::Resolved || state == State::Expired, EInvalidState);

    let mut payout = query.balances.bond.withdraw_all();
    payout.join(query.balances.reward.withdraw_all());

    let winner = query.winner(clock);
    let total_payout = payout.value();
    let resolved_data = *query.resolved_data.borrow();

    query.settled = true;
    transfer::public_transfer(payout.into_coin(ctx), winner);

    event::emit(QuerySettled {
        winner,
        total_payout,
        resolved_data,
        query_id: query.id.to_inner(),
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
    resolution: Option<Resolution>,
    clock: &Clock,
    ctx: &mut TxContext,
): callback::QuerySettled {
    query.settle(resolution, clock, ctx);

    callback::new_query_settled(
        query.id.to_inner(),
        *query.resolved_data.borrow(),
        query.creator_witness,
    )
}

fun apply_resolution<T>(query: &mut Query<T>, resolution: Resolution) {
    assert!(query.proposal.is_some() && query.dispute.is_some(), EDataNotProposed);

    assert!(resolution.query_id() == query.id.to_inner(), EWrongQueryResolution);
    assert!(resolution.resolver_id() == query.resolver_id, EWrongResolverType);
    assert!(resolution.resolved_at_ms() >= query.dispute.borrow().disputed_at_ms, EStaleResolution);

    query.resolved_data.fill(resolution.data());
}

fun winner<T>(query: &Query<T>, clock: &Clock): address {
    let state = query.state(clock);
    assert!(state == State::Resolved || state == State::Expired, EInvalidQueryStatus);

    let proposal = query.proposal.borrow();
    if (query.resolved_data == option::some(proposal.data) || state == State::Expired) {
        proposal.proposer
    } else {
        query.dispute.borrow().disputer
    }
}

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
    let current_time = clock.timestamp_ms();

    if (query.proposal.is_none()) return State::Created;
    if (query.settled) return State::Settled;

    if (query.dispute.is_none()) {
        let proposal = query.proposal.borrow();
        if (current_time >= proposal.expires_at_ms) {
            return State::Expired
        };

        return State::Proposed
    };

    if (query.resolved_data.is_some()) {
        State::Resolved
    } else {
        State::Disputed
    }
}

/// Returns the topic identifier for this query.
///
/// @param query Query object
///
/// @return Topic bytes
public fun topic<T>(query: &Query<T>): vector<u8> {
    query.topic
}

/// Returns the metadata associated with this query.
///
/// @param query Query object
///
/// @return Metadata bytes
public fun metadata<T>(query: &Query<T>): vector<u8> {
    query.metadata
}

/// Returns the required bond amount for proposals and disputes.
///
/// @param query Query object
///
/// @return Bond amount in coin units
public fun bond_amount<T>(query: &Query<T>): u64 {
    query.bond_amount
}

/// Returns the optional callback object ID for external integrations.
///
/// @param query Query object
///
/// @return Optional object ID for callbacks
public fun callback_id<T>(query: &Query<T>): Option<ID> {
    query.callback_object_id
}

/// Returns the proposal data if one exists.
public fun proposal_data<T>(query: &Query<T>): Option<vector<u8>> {
    if (query.proposal.is_some()) {
        option::some(query.proposal.borrow().data)
    } else {
        option::none()
    }
}

/// Returns the proposer address if a proposal exists.
public fun proposer<T>(query: &Query<T>): Option<address> {
    if (query.proposal.is_some()) {
        option::some(query.proposal.borrow().proposer)
    } else {
        option::none()
    }
}

/// Returns when the proposal expires (in milliseconds).
public fun expires_at_ms<T>(query: &Query<T>): Option<u64> {
    if (query.proposal.is_some()) {
        option::some(query.proposal.borrow().expires_at_ms)
    } else {
        option::none()
    }
}

/// Returns the disputer address if the proposal was disputed.
public fun disputer<T>(query: &Query<T>): Option<address> {
    if (query.dispute.is_some()) {
        option::some(query.dispute.borrow().disputer)
    } else {
        option::none()
    }
}

/// Returns when the proposal was disputed (in milliseconds).
public fun disputed_at_ms<T>(query: &Query<T>): Option<u64> {
    if (query.dispute.is_some()) {
        option::some(query.dispute.borrow().disputed_at_ms)
    } else {
        option::none()
    }
}

/// Returns the resolved data if the query has been resolved.
public fun resolved_data<T>(query: &Query<T>): Option<vector<u8>> {
    query.resolved_data
}

/// Returns whether the query has been settled.
public fun is_settled<T>(query: &Query<T>): bool {
    query.settled
}

/// Returns the optional timestamp this query is for.
public fun timestamp_ms<T>(query: &Query<T>): Option<u64> {
    query.timestamp_ms
}

/// Returns the liveness period in milliseconds.
public fun liveness_ms<T>(query: &Query<T>): u64 {
    query.config.liveness_ms
}

/// Returns the refund address if one is set.
public fun refund_address<T>(query: &Query<T>): Option<address> {
    query.config.refund_address
}

public fun id<T>(query: &Query<T>): ID {
    query.id.to_inner()
}

public fun state_created(): State {
    State::Created
}

public fun state_proposed(): State {
    State::Proposed
}

public fun state_expired(): State {
    State::Expired
}

public fun state_disputed(): State {
    State::Disputed
}

public fun state_resolved(): State {
    State::Resolved
}

public fun state_settled(): State {
    State::Settled
}

/// Data value representing a too early query proposal
public macro fun too_early(): vector<u8> {
    x"fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe"
}

/// Data value representing unresolvable query
public macro fun unresolvable(): vector<u8> {
    x"fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffd"
}

public macro fun max_metadata_length(): u64 {
    1024 // Maximum 1KB for metadata
}
