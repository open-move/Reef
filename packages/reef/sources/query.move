module reef::query;

use reef::callback;
use reef::protocol::{Self, Protocol};
use reef::resolver::{Resolver, Resolution};
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

public struct Query<phantom CoinType> has key, store {
    id: UID,
    settled: bool,
    bond_amount: u64,
    topic: vector<u8>,
    config: QueryConfig,
    metadata: vector<u8>,
    dispute: Option<Dispute>,
    timestamp_ms: Option<u64>,
    creator_witness: TypeName,
    resolver_witness: TypeName,
    proposal: Option<Proposal>,
    balances: Balances<CoinType>,
    callback_object_id: Option<ID>,
    resolved_data: Option<vector<u8>>,
}

public struct Balances<phantom CoinType> has store {
    bond: Balance<CoinType>,
    reward: Balance<CoinType>,
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

public struct QueryConfig has copy, drop, store {
    liveness_ms: u64,
    refund_address: Option<address>,
}

public enum QueryState has copy, drop, store {
    Created,
    Proposed,
    Expired,
    Disputed,
    Resolved,
    Settled,
}

public struct DisputeTicket {
    query_id: ID,
    disputer: address,
    timestamp_ms: u64,
}

// ====== Events ======

public struct QueryCreated<phantom CoinType> has copy, drop {
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
public fun create<CoinType, CreatorWitness: drop>(
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
): Query<CoinType> {
    assert!(protocol.is_topic_supported(topic), EUnsupportedTopic);
    assert!(protocol.is_coin_type_supported<CoinType>(), EUnsupportedCoinType);
    assert!(bond_amount >= protocol.minimum_bond<CoinType>(), EInsufficientBond);

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
        resolved_data: option::none(),
        balances: Balances {
            bond: balance::zero(),
            reward: balance::zero(),
        },
        config: QueryConfig {
            refund_address: option::none(),
            liveness_ms: protocol.default_liveness_ms(),
        },
        resolver_witness: resolver.witness_type(),
        creator_witness: type_name::with_defining_ids<CreatorWitness>(),
    };

    event::emit(QueryCreated<CoinType> {
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
public fun set_liveness_ms<CoinType, CreatorWitness: drop>(
    query: &mut Query<CoinType>,
    protocol: &Protocol,
    _: CreatorWitness,
    liveness_ms_maybe: Option<u64>,
    clock: &Clock,
) {
    assert!(query.state(clock) == QueryState::Created, EInvalidState);
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
public fun set_refund_address<CoinType, CreatorWitness: drop>(
    query: &mut Query<CoinType>,
    _: CreatorWitness,
    refund_address: Option<address>,
    clock: &Clock,
) {
    assert!(query.state(clock) == QueryState::Created, EInvalidState);
    assert!(
        query.creator_witness == type_name::with_defining_ids<CreatorWitness>(),
        EInvalidCreatorWitness,
    );

    query.config.refund_address = refund_address;
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
public fun propose_data<CoinType>(
    query: &mut Query<CoinType>,
    bond: Coin<CoinType>,
    data: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(query.state(clock) == QueryState::Created, EInvalidState);
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
/// state and stops the expiration timer. If refund address is set, immediately
/// transfers any reward balance. Creates dispute ticket for resolver processing.
///
/// @param query Query with proposal to dispute (must be in Proposed state)
/// @param bond Bond payment (must meet minimum amount)
/// @param clock System clock for timing validation
/// @param ctx Transaction context
///
/// @return DisputeTicket for resolver processing
///
/// Emits ProposalDisputed event and transfers rewards to refund address if set
public fun dispute_proposal<CoinType>(
    query: &mut Query<CoinType>,
    bond: Coin<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
): DisputeTicket {
    assert!(query.state(clock) == QueryState::Proposed, EInvalidState);
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

    if (query.config.refund_address.is_some()) {
        if (query.balances.reward.value() > 0) {
            let reward = query.balances.reward.withdraw_all();
            transfer::public_transfer(reward.into_coin(ctx), *query.config.refund_address.borrow());
        };
    };

    event::emit(ProposalDisputed {
        disputer,
        bond_amount,
        disputed_at_ms,
        query_id: query.id.to_inner(),
    });

    DisputeTicket {
        disputer,
        query_id: object::id(query),
        timestamp_ms: disputed_at_ms,
    }
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
public fun settle<CoinType>(
    query: &mut Query<CoinType>,
    resolution_maybe: Option<Resolution>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    if (resolution_maybe.is_some()) {
        assert!(query.state(clock) == QueryState::Disputed, EInvalidState);
        query.apply_resolution(resolution_maybe.destroy_some());
    } else {
        assert!(query.state(clock) == QueryState::Expired, EInvalidState);

        query.proposal.do_ref!(|proposal_ref| {
            query.resolved_data.fill(proposal_ref.data);
        });
    };

    let state = query.state(clock);
    assert!(state == QueryState::Resolved || state == QueryState::Expired, EInvalidState);

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
public fun settle_with_callback<CoinType>(
    query: &mut Query<CoinType>,
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

fun apply_resolution<CoinType>(query: &mut Query<CoinType>, resolution: Resolution) {
    assert!(query.proposal.is_some() && query.dispute.is_some(), EDataNotProposed);

    assert!(resolution.query_id() == query.id.to_inner(), EWrongQueryResolution);
    assert!(resolution.witness_type() == query.resolver_witness, EWrongResolverType);
    assert!(resolution.resolved_at_ms() > query.dispute.borrow().disputed_at_ms, EStaleResolution);

    query.resolved_data.fill(resolution.data());
}

fun winner<CoinType>(query: &Query<CoinType>, clock: &Clock): address {
    let state = query.state(clock);
    assert!(state == QueryState::Resolved || state == QueryState::Expired, EInvalidQueryStatus);

    let proposal = query.proposal.borrow();
    if (query.resolved_data == option::some(proposal.data) || state == QueryState::Expired) {
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
/// @return Current QueryState (Created, Proposed, Expired, Disputed, Resolved, or Settled)
public fun state<CoinType>(query: &Query<CoinType>, clock: &Clock): QueryState {
    let current_time = clock.timestamp_ms();

    if (query.proposal.is_none()) return QueryState::Created;
    if (query.settled) return QueryState::Settled;

    if (query.dispute.is_none()) {
        let proposal = query.proposal.borrow();
        if (current_time >= proposal.expires_at_ms) {
            return QueryState::Expired
        };

        return QueryState::Proposed
    };

    if (query.resolved_data.is_some()) {
        QueryState::Resolved
    } else {
        QueryState::Disputed
    }
}

/// Returns the topic identifier for this query.
///
/// @param query Query object
///
/// @return Topic bytes
public fun topic<CoinType>(query: &Query<CoinType>): vector<u8> {
    query.topic
}

/// Returns the metadata associated with this query.
///
/// @param query Query object
///
/// @return Metadata bytes
public fun metadata<CoinType>(query: &Query<CoinType>): vector<u8> {
    query.metadata
}

/// Returns the required bond amount for proposals and disputes.
///
/// @param query Query object
///
/// @return Bond amount in coin units
public fun bond_amount<CoinType>(query: &Query<CoinType>): u64 {
    query.bond_amount
}

/// Returns the optional callback object ID for external integrations.
///
/// @param query Query object
///
/// @return Optional object ID for callbacks
public fun callback_id<CoinType>(query: &Query<CoinType>): Option<ID> {
    query.callback_object_id
}

/// Returns the proposal data if one exists.
public fun proposal_data<CoinType>(query: &Query<CoinType>): Option<vector<u8>> {
    if (query.proposal.is_some()) {
        option::some(query.proposal.borrow().data)
    } else {
        option::none()
    }
}

/// Returns the proposer address if a proposal exists.
public fun proposer<CoinType>(query: &Query<CoinType>): Option<address> {
    if (query.proposal.is_some()) {
        option::some(query.proposal.borrow().proposer)
    } else {
        option::none()
    }
}

/// Returns when the proposal expires (in milliseconds).
public fun expires_at_ms<CoinType>(query: &Query<CoinType>): Option<u64> {
    if (query.proposal.is_some()) {
        option::some(query.proposal.borrow().expires_at_ms)
    } else {
        option::none()
    }
}

/// Returns the disputer address if the proposal was disputed.
public fun disputer<CoinType>(query: &Query<CoinType>): Option<address> {
    if (query.dispute.is_some()) {
        option::some(query.dispute.borrow().disputer)
    } else {
        option::none()
    }
}

/// Returns when the proposal was disputed (in milliseconds).
public fun disputed_at_ms<CoinType>(query: &Query<CoinType>): Option<u64> {
    if (query.dispute.is_some()) {
        option::some(query.dispute.borrow().disputed_at_ms)
    } else {
        option::none()
    }
}

/// Returns the resolved data if the query has been resolved.
public fun resolved_data<CoinType>(query: &Query<CoinType>): Option<vector<u8>> {
    query.resolved_data
}

/// Returns whether the query has been settled.
public fun is_settled<CoinType>(query: &Query<CoinType>): bool {
    query.settled
}

/// Returns the optional timestamp this query is for.
public fun timestamp_ms<CoinType>(query: &Query<CoinType>): Option<u64> {
    query.timestamp_ms
}

/// Returns the liveness period in milliseconds.
public fun liveness_ms<CoinType>(query: &Query<CoinType>): u64 {
    query.config.liveness_ms
}

/// Returns the refund address if one is set.
public fun refund_address<CoinType>(query: &Query<CoinType>): Option<address> {
    query.config.refund_address
}

public macro fun invalid_query(): vector<u8> {
    x"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
}

public macro fun unresolvable(): vector<u8> {
    x"fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe"
}

public macro fun too_early(): vector<u8> {
    x"fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffd"
}
