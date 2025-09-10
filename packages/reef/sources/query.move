module reef::query;

use reef::callback;
use reef::macros;
use reef::protocol::{Self, Protocol};
use reef::resolver::{Resolver, Resolution};
use std::type_name::{Self, TypeName};
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::Coin;
use sui::event;

// ====== Error codes ======
const EInvalidLiveness: u64 = 1;
const EUnsupportedTopic: u64 = 2;
const EUnsupportedCoinType: u64 = 3;
const EInvalidState: u64 = 4;
const ETimestampInFuture: u64 = 5;
const ECannotProposeTooEarly: u64 = 6;
const EInsufficientBond: u64 = 7;
const ENotExpired: u64 = 9;
const EInvalidCreatorWitness: u64 = 10;
const EDataNotProposed: u64 = 11;
const EWrongQueryResolution: u64 = 12;
const EStaleResolution: u64 = 13;
const EWrongResolverType: u64 = 14;
const EInvalidQueryStatus: u64 = 15;

public struct Query<phantom CoinType> has key, store {
    id: UID,
    settled: bool,
    topic: vector<u8>,
    bond_amount: u64,
    config: QueryConfig,
    metadata: vector<u8>,
    dispute: Option<Dispute>,
    timestamp_ms: Option<u64>,
    creator_witness: TypeName,
    resolver_witness: TypeName,
    proposal: Option<Proposal>,
    balances: Balances<CoinType>,
    callback_object: Option<ID>,
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

public struct QueryCreated has copy, drop {
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

public fun create_query<CoinType, Witness: drop>(
    _: Witness,
    protocol: &Protocol,
    resolver: &Resolver,
    topic: vector<u8>,
    metadata: vector<u8>,
    timestamp_ms: Option<u64>,
    callback_object: Option<ID>,
    bond_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Query<CoinType> {
    assert!(protocol.is_topic_supported(topic), EUnsupportedTopic);
    assert!(protocol.is_coin_type_supported<CoinType>(), EUnsupportedCoinType);

    if (timestamp_ms.is_some()) {
        assert!(*timestamp_ms.borrow() <= clock.timestamp_ms(), ETimestampInFuture);
    };

    let query_id = object::new(ctx);
    let id_inner = query_id.to_inner();

    event::emit(QueryCreated {
        query_id: id_inner,
        creator: ctx.sender(),
        topic,
        bond_amount,
        timestamp_ms,
    });

    Query {
        id: query_id,
        topic,
        metadata,
        bond_amount,
        timestamp_ms,
        settled: false,
        callback_object,
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
        creator_witness: type_name::with_defining_ids<Witness>(),
    }
}

public fun set_liveness_ms<CoinType, Witness: drop>(
    query: &mut Query<CoinType>,
    protocol: &Protocol,
    _: Witness,
    liveness_ms_maybe: Option<u64>,
    clock: &Clock,
) {
    assert!(query.state(clock) == QueryState::Created, EInvalidState);
    assert!(
        query.creator_witness == type_name::with_defining_ids<Witness>(),
        EInvalidCreatorWitness,
    );

    let liveness_ms = liveness_ms_maybe.destroy_with_default(protocol.default_liveness_ms());
    assert!(liveness_ms >= protocol::min_liveness_ms!(), EInvalidLiveness);

    query.config.liveness_ms = liveness_ms;
}

public fun set_refund_address<CoinType, Witness: drop>(
    query: &mut Query<CoinType>,
    _: Witness,
    refund_address: Option<address>,
    clock: &Clock,
) {
    assert!(query.state(clock) == QueryState::Created, EInvalidState);
    assert!(
        query.creator_witness == type_name::with_defining_ids<Witness>(),
        EInvalidCreatorWitness,
    );

    query.config.refund_address = refund_address;
}

public fun propose_data<CoinType>(
    query: &mut Query<CoinType>,
    data: vector<u8>,
    bond: Coin<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(query.state(clock) == QueryState::Created, EInvalidState);
    assert!(
        !(query.timestamp_ms.is_none() && data == macros::data_too_early!()),
        ECannotProposeTooEarly,
    );

    let current_time_ms = clock.timestamp_ms();
    let bond_amount = bond.value();
    assert!(bond_amount >= query.bond_amount, EInsufficientBond);

    let proposer = ctx.sender();
    let expires_at_ms = query.config.liveness_ms + current_time_ms;

    query
        .proposal
        .fill(Proposal {
            data,
            proposer,
            proposed_at_ms: current_time_ms,
            expires_at_ms,
        });

    query.balances.bond.join(bond.into_balance());

    event::emit(DataProposed {
        query_id: query.id.to_inner(),
        proposer,
        data,
        bond_amount,
        expires_at_ms,
    });
}

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
        query_id: query.id.to_inner(),
        disputer,
        disputed_at_ms,
        bond_amount,
    });

    DisputeTicket {
        disputer,
        query_id: object::id(query),
        timestamp_ms: disputed_at_ms,
    }
}

public fun settle_query<CoinType>(
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

        let current_time_ms = clock.timestamp_ms();
        query.proposal.do_ref!(|proposal_ref| {
            assert!(current_time_ms >= proposal_ref.expires_at_ms, ENotExpired);
            query.resolved_data.fill(proposal_ref.data);
        });
    };

    assert!(query.state(clock) == QueryState::Resolved, EInvalidState);
    query.settled = true;

    let mut payout = query.balances.bond.withdraw_all();
    payout.join(query.balances.reward.withdraw_all());
    let total_payout = payout.value();
    let winner = query.winner(clock);
    let resolved_data = *query.resolved_data.borrow();

    transfer::public_transfer(payout.into_coin(ctx), winner);

    event::emit(QuerySettled {
        query_id: query.id.to_inner(),
        resolved_data,
        winner,
        total_payout,
    });
}

public fun settle_query_with_callback<CoinType>(
    query: &mut Query<CoinType>,
    resolution: Resolution,
    clock: &Clock,
    ctx: &mut TxContext,
): callback::QuerySettled {
    query.settle_query(option::some(resolution), clock, ctx);

    callback::new_query_settled(
        query.id.to_inner(),
        *query.resolved_data.borrow(),
        query.creator_witness,
    )
}

fun apply_resolution<CoinType>(query: &mut Query<CoinType>, resolution: Resolution) {
    assert!(query.proposal.is_some() && query.dispute.is_some(), EDataNotProposed);

    let proposal = query.proposal.borrow();

    assert!(resolution.query_id() == query.id.to_inner(), EWrongQueryResolution);

    let dispute = query.dispute.borrow();
    assert!(resolution.resolved_at_ms() > dispute.disputed_at_ms, EStaleResolution);
    assert!(resolution.witness_type() == query.resolver_witness, EWrongResolverType);

    query
        .resolved_data
        .fill(if (proposal.data == resolution.data()) { proposal.data } else { resolution.data() });
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

public fun state<CoinType>(query: &Query<CoinType>, clock: &Clock): QueryState {
    let current_time = clock.timestamp_ms();

    if (query.proposal.is_none()) return QueryState::Created;
    if (query.settled) return QueryState::Settled;

    if (query.dispute.is_none()) {
        let proposal = query.proposal.borrow();
        if (current_time >= proposal.proposed_at_ms + query.config.liveness_ms) {
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

public fun topic<CoinType>(query: &Query<CoinType>): vector<u8> {
    query.topic
}

public fun metadata<CoinType>(query: &Query<CoinType>): vector<u8> {
    query.metadata
}

public fun bond_amount<CoinType>(query: &Query<CoinType>): u64 {
    query.bond_amount
}

public fun callback_id<CoinType>(query: &Query<CoinType>): Option<ID> {
    query.callback_object
}