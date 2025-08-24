/// This module provides the base for resolving challenged claims.
///
/// When someone challenges a submitted claim, we need a way to determine who was right.
/// This could be a human committee, an automated system, or any other decision-making process.
///
/// The key concepts:
/// 1. Resolver: An authorized entity that can make resolution decisions
/// 2. Resolution: The actual decision about what the correct claim was
/// 3. Challenge: A hot potato that forces the request to a resolver
///
/// Reef is flexible about how challenged claims get resolved, but strict about who
/// can resolve them (only authorized resolvers) and when they can do it (only after
/// a challenge was made).
module reef::resolver;

use reef::protocol::ProtocolCap;
use std::type_name::{Self, TypeName};
use sui::balance::Balance;
use sui::clock::Clock;
use sui::package::Publisher;

/// A resolver is an authorized entity that can resolve disputes.
///
/// Resolvers need to be explicitly enabled by protocol governance and are tied to a specific
/// "witness type" that acts as their authorization witness.
public struct Resolver has key {
    id: UID,
    /// Whether this resolver is currently active
    is_enabled: bool,
    /// The witness type needed to use this resolver
    witness_type: TypeName,
}

/// The final decision about what the correct claim to a query was.
public struct Resolution has drop {
    query_id: ID,
    claim: vector<u8>,
    resolved_at_ms: u64,
    witness_type: TypeName,
}

/// A hot potato that represents a dispute needing resolution.
///
/// When someone challenges a claim, this struct gets created and must be consumed
/// by someone who can resolve the dispute.
public struct Challenge<phantom CoinType> {
    query_id: ID,
    challenger: address,
    challenged_at_ms: u64,
    fee: Balance<CoinType>,
    resolver_witness: TypeName,
}

public use fun resolution_claim as Resolution.claim;
public use fun resolution_query_id as Resolution.query_id;
public use fun resolution_witness_type as Resolution.witness_type;
public use fun resolution_resolved_at_ms as Resolution.resolved_at_ms;

public use fun share_resolver as Resolver.share;

/// Publisher doesn't match the resolver witness module
const EInvalidPublisher: u64 = 0;
/// Witness type doesn't match what the resolver expects
const EInvalidWitnessType: u64 = 1;
/// Trying to use a resolver that's been disabled
const EResolverDisabled: u64 = 2;

/// Creates a new resolver that can resolve challenges.
///
/// The witness parameter acts as authorization for the resolver and the publisher must come from the same module as the witness type.
///
/// New resolvers start disabled and must be explicitly enabled by protocol governance
/// before they can be used.
public fun create<Witness: drop>(
    _witness: Witness,
    publisher: Publisher,
    ctx: &mut TxContext,
): Resolver {
    assert!(publisher.from_module<Witness>(), EInvalidPublisher);
    publisher.burn();

    Resolver {
        id: object::new(ctx),
        is_enabled: false,
        witness_type: type_name::get<Witness>(),
    }
}

public fun share_resolver(resolver: Resolver) {
    transfer::share_object(resolver)
}

public fun enable(resolver: &mut Resolver, _: &ProtocolCap) {
    resolver.is_enabled = true;
}

public fun disable(resolver: &mut Resolver, _: &ProtocolCap) {
    resolver.is_enabled = false;
}

/// Makes a resolution decision for a disputed query.
public fun make_resolution<Witness: drop>(
    resolver: &Resolver,
    _witness: Witness,
    query_id: ID,
    claim: vector<u8>,
    clock: &Clock,
): Resolution {
    assert!(resolver.is_enabled, EResolverDisabled);
    assert!(resolver.witness_type == type_name::get<Witness>(), EInvalidWitnessType);

    Resolution {
        claim,
        query_id,
        witness_type: resolver.witness_type,
        resolved_at_ms: clock.timestamp_ms(),
    }
}

public fun is_enabled(resolver: &Resolver): bool {
    resolver.is_enabled
}

public fun witness_type(resolver: &Resolver): TypeName {
    resolver.witness_type
}

/// View functions for Resolution
public fun resolution_query_id(resolution: &Resolution): ID {
    resolution.query_id
}

public fun resolution_claim(resolution: &Resolution): vector<u8> {
    resolution.claim
}

public fun resolution_resolved_at_ms(resolution: &Resolution): u64 {
    resolution.resolved_at_ms
}

public fun resolution_witness_type(resolution: &Resolution): TypeName {
    resolution.witness_type
}

public(package) fun new_challenge<CoinType>(
    query_id: ID,
    fee: Balance<CoinType>,
    challenger: address,
    timestamp_ms: u64,
    resolver_witness: TypeName,
): Challenge<CoinType> {
    Challenge {
        fee,
        query_id,
        challenger,
        resolver_witness,
        challenged_at_ms: timestamp_ms,
    }
}

public fun unpack_challenge<CoinType, Witness: drop>(
    request: Challenge<CoinType>,
    _witness: Witness,
): (ID, Balance<CoinType>, address, u64, TypeName) {
    let Challenge {
        fee,
        query_id,
        challenger,
        resolver_witness,
        challenged_at_ms,
    } = request;

    assert!(resolver_witness == type_name::get<Witness>(), EInvalidWitnessType);
    (query_id, fee, challenger, challenged_at_ms, resolver_witness)
}
