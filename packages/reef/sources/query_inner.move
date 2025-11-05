module reef::query_inner;

use reef::macros;
use reef::resolver::{Self, Resolution, DisputeTicket};
use reef::schema::Schema as BaseSchema;
use std::type_name::TypeName;
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::derived_object;

// ====== Error codes ======

/// Thrown when liveness period is below minimum required
const EInvalidLiveness: u64 = 1;
/// Thrown when query operation is not valid for current state
const EInvalidState: u64 = 2;
/// Thrown when bond amount is below required minimum
const EInsufficientBond: u64 = 3;
/// Thrown when trying to apply resolution but no proposal/dispute exists
const EDataNotProposed: u64 = 4;
/// Thrown when resolution timestamp is before dispute timestamp
const EStaleResolution: u64 = 5;
/// Thrown when resolution witness type doesn't match resolver
const EWrongResolverType: u64 = 6;
/// Thrown when query state is invalid for winner determination
const EInvalidQueryStatus: u64 = 7;

/// Optimistic oracle request. Tracks the lifecycle from creation to
/// settlement, including bonds, proposals, disputes, and callbacks for a given
/// coin type `T`.
public struct QueryInner<phantom T> has key, store {
    id: UID,
    settled: bool,
    /// Resolver object ID that is authorized to resolve this query.
    resolver_id: ID,
    /// Minimum bond (in coin `T`) required for proposals and disputes.
    bond_amount: u64,
    /// Bytes describing the oracle topic (e.g., market identifier).
    topic: vector<u8>,
    /// Schema defining data structure and validation rules.
    schema: Schema,
    /// Query config such as liveness window and refund address.
    config: Config,
    /// Small arbitrary metadata provided at creation to contextualize the query offchain.
    metadata: vector<u8>,
    balances: Balances<T>,
    dispute: Option<Dispute>,
    /// Optional timestamp the query references (used for time-based feeds).
    timestamp_ms: Option<u64>,
    /// Witness of the query creator's package.
    creator_witness: TypeName,
    proposal: Option<Proposal>,
    /// Callback object IDs to notify once the query settles.
    /// Their types (if needed for type args) will be resolved and will be passed in the order that they are in this vector.
    callback_object_ids: vector<ID>,
    /// Finalized data once settlement occurs, or stored proposal data if expired.
    resolved_data: Option<vector<u8>>,
}

public struct Balances<phantom T> has store {
    bond: Balance<T>,
    reward: Balance<T>,
}

/// Proposed data for a query.
public struct Proposal has store {
    data: vector<u8>,
    proposer: address,
    expires_at_ms: u64,
    proposed_at_ms: u64,
}

/// Dispute marker stored after a challenger posts the required bond.
public struct Dispute has store {
    disputer: address,
    disputed_at_ms: u64,
}

/// Per-query configuration controlled by the creator. Contains adjustable
/// liveness windows and an optional address that should receive rewards if a
/// dispute occurs.
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

public enum Schema has copy, drop, store {
    Standard(BaseSchema, u64),
    Custom(BaseSchema),
}

public struct QueryKey(u64) has copy, drop, store;

const CURRENT_QUERY_VERSION: u64 = 1;

public(package) fun create<T>(
    parent: &mut UID,
    resolver_id: ID,
    schema: Schema,
    topic: vector<u8>,
    metadata: vector<u8>,
    liveness_ms: u64,
    timestamp_ms: Option<u64>,
    callback_object_ids: vector<ID>,
    creator_witness: TypeName,
    bond_amount: u64,
): QueryInner<T> {
    QueryInner {
        id: derived_object::claim(parent, QueryKey(CURRENT_QUERY_VERSION)),
        topic,
        schema,
        metadata,
        bond_amount,
        resolver_id,
        timestamp_ms,
        settled: false,
        creator_witness,
        callback_object_ids,
        dispute: option::none(),
        proposal: option::none(),
        resolved_data: option::none(),
        balances: Balances {
            bond: balance::zero(),
            reward: balance::zero(),
        },
        config: Config {
            liveness_ms: liveness_ms,
            refund_address: option::none(),
        },
    }
}

public(package) fun set_liveness_ms<T>(query: &mut QueryInner<T>, liveness_ms: u64) {
    assert!(liveness_ms >= macros::min_liveness_ms!(), EInvalidLiveness);
    query.config.liveness_ms = liveness_ms;
}

public(package) fun set_refund_address<T>(
    query: &mut QueryInner<T>,
    refund_address: Option<address>,
) {
    query.config.refund_address = refund_address;
}

public(package) fun add_reward<T>(query: &mut QueryInner<T>, reward: Balance<T>) {
    query.balances.reward.join(reward);
}

public(package) fun propose_data<T>(
    query: &mut QueryInner<T>,
    bond: Balance<T>,
    data: vector<u8>,
    proposer: address,
    clock: &Clock,
): (address, u64, u64) {
    let bond_amount = bond.value();
    let current_time_ms = clock.timestamp_ms();
    assert!(bond_amount >= query.bond_amount, EInsufficientBond);

    let expires_at_ms = query.config.liveness_ms + current_time_ms;

    query
        .proposal
        .fill(Proposal {
            data,
            proposer,
            expires_at_ms,
            proposed_at_ms: current_time_ms,
        });

    query.balances.bond.join(bond);
    (proposer, bond_amount, expires_at_ms)
}

public(package) fun dispute_proposal<T>(
    query: &mut QueryInner<T>,
    bond: Balance<T>,
    fee_factor_bps: u64,
    disputer: address,
    clock: &Clock,
    ctx: &mut TxContext,
): (DisputeTicket<T>, address, u64, u64) {
    let bond_amount = bond.value();
    assert!(bond_amount >= query.bond_amount, EInsufficientBond);

    let disputed_at_ms = clock.timestamp_ms();

    query
        .dispute
        .fill(Dispute {
            disputer,
            disputed_at_ms,
        });

    query.balances.bond.join(bond);

    let mut refund_amount = query.balances.reward.value();
    if (refund_amount > 0) {
        if (query.config.refund_address.is_some()) {
            // Reward refunds are best-effort; only materialize when an address exists.
            query.config.refund_address.do_ref!(|refund_address| {
                transfer::public_transfer(
                    query.balances.reward.withdraw_all().into_coin(ctx),
                    *refund_address,
                );
            });
        } else {
            refund_amount = 0;
        };
    };

    let fee_amount =
        (
            (fee_factor_bps as u128) * (query.bond_amount as u128)
         / (macros::bps!() as u128),
        ) as u64;

    let verification_bond_amount = query.balances.bond.value();
    let ticket = resolver::new_dispute_ticket<T>(
        query.id.to_inner(),
        query.resolver_id,
        query.balances.bond.split(fee_amount),
        disputer,
        disputed_at_ms,
        // the required bond whoever is challenging the resolver decision has to pay
        verification_bond_amount,
    );

    (ticket, disputer, bond_amount, refund_amount)
}

public(package) fun settle<T>(
    query: &mut QueryInner<T>,
    resolution_maybe: Option<Resolution>,
    clock: &Clock,
    ctx: &mut TxContext,
): (address, u64, vector<u8>) {
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

    query.settled = true;
    transfer::public_transfer(payout.into_coin(ctx), winner);

    (winner, total_payout, *query.resolved_data.borrow())
}

public(package) fun new_standard_schema(inner: BaseSchema, version: u64): Schema {
    Schema::Standard(inner, version)
}

public(package) fun new_custom_schema(inner: BaseSchema): Schema {
    Schema::Custom(inner)
}

fun apply_resolution<T>(query: &mut QueryInner<T>, resolution: Resolution) {
    assert!(query.proposal.is_some() && query.dispute.is_some(), EDataNotProposed);

    assert!(resolution.resolver_id() == query.resolver_id, EWrongResolverType);
    assert!(resolution.resolved_at_ms() >= query.dispute.borrow().disputed_at_ms, EStaleResolution);

    query.resolved_data.fill(resolution.data());
}

fun winner<T>(query: &QueryInner<T>, clock: &Clock): address {
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

public(package) fun state<T>(query: &QueryInner<T>, clock: &Clock): State {
    if (query.proposal.is_none()) return State::Created;
    if (query.settled) return State::Settled;

    if (query.dispute.is_none()) {
        let proposal = query.proposal.borrow();
        if (clock.timestamp_ms() >= proposal.expires_at_ms) {
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

public(package) fun topic<T>(query: &QueryInner<T>): vector<u8> {
    query.topic
}

public(package) fun schema<T>(query: &QueryInner<T>): &BaseSchema {
    match (&query.schema) {
        Schema::Standard(schema, _) => schema,
        Schema::Custom(schema) => schema,
    }
}

public(package) fun schema_version<T>(query: &QueryInner<T>): Option<u64> {
    match (&query.schema) {
        Schema::Standard(_, version) => option::some(*version),
        Schema::Custom(_) => option::none(),
    }
}

public(package) fun metadata<T>(query: &QueryInner<T>): vector<u8> {
    query.metadata
}

public(package) fun bond_amount<T>(query: &QueryInner<T>): u64 {
    query.bond_amount
}

public(package) fun callback_object_ids<T>(query: &QueryInner<T>): vector<ID> {
    query.callback_object_ids
}

public(package) fun proposal_data<T>(query: &QueryInner<T>): Option<vector<u8>> {
    if (query.proposal.is_some()) {
        option::some(query.proposal.borrow().data)
    } else {
        option::none()
    }
}

public(package) fun proposer<T>(query: &QueryInner<T>): Option<address> {
    if (query.proposal.is_some()) {
        option::some(query.proposal.borrow().proposer)
    } else {
        option::none()
    }
}

public(package) fun expires_at_ms<T>(query: &QueryInner<T>): Option<u64> {
    if (query.proposal.is_some()) {
        option::some(query.proposal.borrow().expires_at_ms)
    } else {
        option::none()
    }
}

public(package) fun disputer<T>(query: &QueryInner<T>): Option<address> {
    if (query.dispute.is_some()) {
        option::some(query.dispute.borrow().disputer)
    } else {
        option::none()
    }
}

public(package) fun disputed_at_ms<T>(query: &QueryInner<T>): Option<u64> {
    if (query.dispute.is_some()) {
        option::some(query.dispute.borrow().disputed_at_ms)
    } else {
        option::none()
    }
}

public(package) fun resolved_data<T>(query: &QueryInner<T>): Option<vector<u8>> {
    query.resolved_data
}

public(package) fun is_settled<T>(query: &QueryInner<T>): bool {
    query.settled
}

public(package) fun timestamp_ms<T>(query: &QueryInner<T>): Option<u64> {
    query.timestamp_ms
}

public(package) fun liveness_ms<T>(query: &QueryInner<T>): u64 {
    query.config.liveness_ms
}

public(package) fun refund_address<T>(query: &QueryInner<T>): Option<address> {
    query.config.refund_address
}

public(package) fun creator_witness<T>(query: &QueryInner<T>): TypeName {
    query.creator_witness
}

public(package) fun id<T>(query: &QueryInner<T>): ID {
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

public fun current_query_version(): u64 {
    CURRENT_QUERY_VERSION
}
