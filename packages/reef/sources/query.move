module reef::query;

use reef::protocol::{Self, Protocol};
use reef::resolver::Resolver;
use std::type_name::{Self, TypeName};
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::Coin;

// ====== Error codes ======
const EInvalidLiveness: u64 = 1;
const EUnsupportedTopic: u64 = 2;
const EUnsupportedCoinType: u64 = 3;
const EInvalidState: u64 = 4;
const ETimestampInFuture: u64 = 5;
const ECannotProposeTooEarly: u64 = 6;
const EInsufficientBond: u64 = 7;
const EAlreadySettled: u64 = 8;
const ENotExpired: u64 = 9;
const EInvalidCreatorWitness: u64 = 10;

public struct Query<phantom CoinType> has key, store {
    id: UID,
    state: State,
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

public enum State has copy, drop, store {
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

public fun create_query<CoinType, Witness: drop>(
    _: Witness,
    protocol: &Protocol,
    resolver: &Resolver,
    topic: vector<u8>,
    metadata: vector<u8>,
    timestamp_ms: Option<u64>,
    bond_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Query<CoinType> {
    assert!(protocol.is_topic_supported(topic), EUnsupportedTopic);
    assert!(protocol.is_coin_type_supported<CoinType>(), EUnsupportedCoinType);

    if (timestamp_ms.is_some()) {
        assert!(*timestamp_ms.borrow() <= clock::timestamp_ms(clock), ETimestampInFuture);
    };

    let config = QueryConfig {
        refund_address: option::none(),
        liveness_ms: protocol.default_liveness_ms(),
    };

    let balances = Balances {
        bond: balance::zero(),
        reward: balance::zero(),
    };

    Query {
        id: object::new(ctx),
        topic,
        config,
        balances,
        metadata,
        bond_amount,
        timestamp_ms,
        settled: false,
        state: State::Created,
        dispute: option::none(),
        proposal: option::none(),
        resolved_data: option::none(),
        resolver_witness: resolver.witness_type(),
        creator_witness: type_name::with_defining_ids<Witness>(),
    }
}

public fun set_liveness_ms<CoinType, Witness: drop>(
    query: &mut Query<CoinType>,
    protocol: &Protocol,
    _: Witness,
    liveness_ms_maybe: Option<u64>,
) {
    assert!(query.state == State::Created, EInvalidState);
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
) {
    assert!(query.state == State::Created, EInvalidState);
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
    assert!(query.state == State::Created, EInvalidState);

    // Check for event-based "too early" restriction
    if (query.timestamp_ms.is_none()) {};

    let current_time_ms = clock::timestamp_ms(clock);
    assert!(bond.value() >= query.bond_amount, EInsufficientBond);

    query
        .proposal
        .fill(Proposal {
            data,
            proposer: ctx.sender(),
            proposed_at_ms: current_time_ms,
            expires_at_ms: query.config.liveness_ms + current_time_ms,
        });

    query.state = State::Proposed;
    query.balances.bond.join(bond.into_balance());
}

public fun dispute_proposal<CoinType>(
    query: &mut Query<CoinType>,
    bond: Coin<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
): DisputeTicket {
    assert!(query.state == State::Proposed, EInvalidState);
    assert!(bond.value() >= query.bond_amount, EInsufficientBond);

    query
        .dispute
        .fill(Dispute {
            disputer: ctx.sender(),
            disputed_at_ms: clock.timestamp_ms(),
        });

    query.state = State::Disputed;
    query.balances.bond.join(bond.into_balance());

    if (query.config.refund_address.is_some()) {
        if (query.balances.reward.value() > 0) {
            let reward = query.balances.reward.withdraw_all();
            transfer::public_transfer(reward.into_coin(ctx), *query.config.refund_address.borrow());
        };
    };

    DisputeTicket {
        disputer: ctx.sender(),
        query_id: object::id(query),
        timestamp_ms: clock.timestamp_ms(),
    }
}

public fun settle_expired<CoinType>(
    query: &mut Query<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(query.state == State::Proposed, EInvalidState);
    let current_time_ms = clock::timestamp_ms(clock);

    query.proposal.do_ref!(|proposal_ref| {
        assert!(current_time_ms >= proposal_ref.expires_at_ms, ENotExpired);
        query.resolved_data.fill(proposal_ref.data);
    });

    query.state = State::Expired;
    query.settle_payout_expired(ctx)
}

public fun settle_resolved<CoinType>(
    query: &mut Query<CoinType>,
    data: vector<u8>,
    ctx: &mut TxContext,
) {
    assert!(query.state == State::Disputed, EInvalidState);

    query.resolved_data.fill(data);
    query.state = State::Resolved;

    let dispute_success = data !=  query.proposal.borrow().data;
    settle_payout_resolved(query, dispute_success, ctx)
}

fun settle_payout_expired<CoinType>(query: &mut Query<CoinType>, ctx: &mut TxContext) {
    assert!(!query.settled, EAlreadySettled);
    query.settled = true;
    query.state = State::Settled;

    // Proposer gets everything in expired case
    let mut payout = balance::withdraw_all(&mut query.balances.bond);
    payout.join(query.balances.reward.withdraw_all());

    // event::emit(QuerySettled {
    //     query_id: object::id(query),
    //     resolved_data: query.resolved_data,
    //     payout_recipient: query.proposer,
    //     payout_amount: coin::value(&payout_coin),
    //     currency_type: type_name::with_original_ids<CoinType>(),
    // });

    transfer::public_transfer(payout.into_coin(ctx), query.proposal.borrow().proposer);
}

fun settle_payout_resolved<CoinType>(
    query: &mut Query<CoinType>,
    dispute_success: bool,
    _ctx: &mut TxContext,
) {
    assert!(!query.settled, EAlreadySettled);
    query.settled = true;
    query.state = State::Settled;

    let _winner = if (dispute_success) {
        query.dispute.borrow().disputer
    } else {
        query.proposal.borrow().proposer
    };

    // Calculate burned amount from loser's bond
    // let (burn_amount, mut payout) = if (dispute_success) {
    //     // Disputer won - burn from proposer's bond
    //     let burn_amt = balance::value(&query.proposal_bond) * BURN_RATE / HUNDRED_PERCENT;
    //     let burned = balance::split(&mut query.proposal_bond, burn_amt);
    //     let mut payout_balance = balance::withdraw_all(&mut query.dispute_bond);
    //     balance::join(&mut payout_balance, balance::withdraw_all(&mut query.proposal_bond));
    //     (burned, payout_balance)
    // } else {
    //     // Proposer won - burn from disputer's bond
    //     let burn_amt = balance::value(&query.dispute_bond) * BURN_RATE / HUNDRED_PERCENT;
    //     let burned = balance::split(&mut query.dispute_bond, burn_amt);
    //     let mut payout_balance = balance::withdraw_all(&mut query.proposal_bond);
    //     balance::join(&mut payout_balance, balance::withdraw_all(&mut query.dispute_bond));
    //     (burned, payout_balance)
    // };

    // // Add rewards to payout
    // balance::join(&mut payout, balance::withdraw_all(&mut query.reward));

    // let payout_coin = coin::from_balance(payout, ctx);
    // let burn_coin = coin::from_balance(burn_amount, ctx);

    // event::emit(QuerySettled {
    //     query_id: object::id(query),
    //     resolved_data: query.resolved_data,
    //     payout_recipient: winner,
    //     payout_amount: coin::value(&payout_coin),
    //     currency_type: type_name::with_original_ids<CoinType>(),
    // });

    // transfer::public_transfer(payout_coin, winner);
    // burn_coin // Return the burned amount
}

// ====== View Functions ======

public fun state<CoinType>(query: &Query<CoinType>): State {
    query.state
}

public fun topic<CoinType>(query: &Query<CoinType>): vector<u8> {
    query.topic
}

public fun metadata<CoinType>(query: &Query<CoinType>): vector<u8> {
    query.metadata
}

public fun is_settleable<CoinType>(query: &Query<CoinType>, clock: &Clock): bool {
    if (query.settled) {
        return false
    };

    if (query.state == State::Proposed) {
        clock::timestamp_ms(clock) >= query.proposal.borrow().expires_at_ms
    } else if (query.state == State::Resolved) {
        true
    } else {
        false
    }
}
