/// This module provides the base for resolving challenged claims.
/// 
/// When someone challenges a submitted claim, we need a way to determine who was right.
/// This could be a human committee, an automated system, or any other decision-making process.
/// 
/// The key concepts:
/// 1. Resolver: An authorized entity that can make resolution decisions
/// 2. Resolution: The actual decision about what the correct claim was
/// 3. ChallengeRequest: A hot potato that forces the request to a resolver
/// 
/// We're flexible about how challenged claims get resolved, but strict about who
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
/// "proof type" that acts as their auth witness.
public struct Resolver has key {
    id: UID,
    /// Whether this resolver is currently active
    is_enabled: bool,
    /// The witness type needed to use this resolver
    proof_type: TypeName,
}

/// The final decision about what the correct claim to a query was.
public struct Resolution has drop {
    query_id: ID,
    claim: vector<u8>,
    resolved_at_ms: u64,
    proof_type: TypeName,
}

/// A hot potato that represents a dispute needing resolution.
/// 
/// When someone challenges a claim, this struct gets created and must be consumed
/// by someone who can resolve the dispute.
public struct ChallengeRequest<phantom CoinType> {
    query_id: ID,
    challenger: address,
    challenged_at_ms: u64,
    fee: Balance<CoinType>,
    resolver_type: TypeName
}

public use fun resolution_claim as Resolution.claim;
public use fun resolution_query_id as Resolution.query_id;
public use fun resolution_proof_type as Resolution.proof_type;
public use fun resolution_resolved_at_ms as Resolution.resolved_at_ms;

public use fun share_resolver as Resolver.share;


/// Publisher doesn't match the resolver proof module
const EInvalidPublisher: u64 = 0;
/// Proof type doesn't match what the resolver expects
const EInvalidProofType: u64 = 1;
/// Trying to use a resolver that's been disabled
const EResolverDisabled: u64 = 2;

/// Creates a new resolver that can resolve challenges.
/// 
/// The proof parameter acts as a witness for the resolver and the publisher must come from the same module as the proof type.
/// 
/// New resolvers start disabled and must be explicitly enabled by protocol governance
/// before they can be used.
public fun create<Proof: drop>(_proof: Proof, publisher: Publisher, ctx: &mut TxContext): Resolver {
    assert!(publisher.from_module<Proof>(), EInvalidPublisher);
    publisher.burn();

    Resolver {
        id: object::new(ctx),
        is_enabled: false,
        proof_type: type_name::get<Proof>(),
    }
}

public fun share_resolver(resolver: Resolver) {
    transfer::share_object(resolver)
}

public fun enable(_: &ProtocolCap, resolver: &mut Resolver) {
    resolver.is_enabled = true;
}

public fun disable(_: &ProtocolCap, resolver: &mut Resolver) {
    resolver.is_enabled = false;
}

/// Makes a resolution decision for a disputed query.
public fun make_resolution<Proof: drop>(
    resolver: &Resolver,
    _proof: Proof,
    query_id: ID,
    claim: vector<u8>,
    clock: &Clock,
): Resolution {
    assert!(resolver.is_enabled, EResolverDisabled);
    assert!(resolver.proof_type == type_name::get<Proof>(), EInvalidProofType);

    Resolution {
        claim,
        query_id,
        proof_type: resolver.proof_type,
        resolved_at_ms: clock.timestamp_ms(),
    }
}

public fun is_enabled(resolver: &Resolver): bool {
    resolver.is_enabled
}

public fun proof_type(resolver: &Resolver): TypeName {
    resolver.proof_type
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

public fun resolution_proof_type(resolution: &Resolution): TypeName {
    resolution.proof_type
}

public(package) fun new_challenge_request<CoinType>(
    query_id: ID,
    fee: Balance<CoinType>,
    challenger: address,
    timestamp_ms: u64,
    resolver_type: TypeName,
): ChallengeRequest<CoinType> {
    ChallengeRequest {
        fee,
        query_id,
        challenger,
        resolver_type,
        challenged_at_ms: timestamp_ms,
    }
}

public fun unpack_challenge_request<CoinType>(
    request: ChallengeRequest<CoinType>,
): (ID, Balance<CoinType>, address, u64, TypeName) {
    let ChallengeRequest {
        fee,
        query_id,
        challenger,
        resolver_type,
        challenged_at_ms,
    } = request;

    (query_id, fee, challenger, challenged_at_ms, resolver_type)
}
