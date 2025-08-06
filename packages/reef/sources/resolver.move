module reef::resolver;

use reef::protocol::ProtocolCap;
use std::type_name::{Self, TypeName};
use sui::clock::Clock;
use sui::package::Publisher;

public struct Resolver has key {
    id: UID,
    is_enabled: bool,
    proof_type: TypeName,
}

public struct Resolution has drop {
    query_id: ID,
    confidence: u64,
    timestamp_ms: u64,
    claim: vector<u8>,
    proof_type: TypeName,
}

public use fun resolution_claim as Resolution.claim;
public use fun resolution_query_id as Resolution.query_id;
public use fun resolution_confidence as Resolution.confidence;
public use fun resolution_proof_type as Resolution.proof_type;
public use fun resolution_timestamp_ms as Resolution.timestamp_ms;

// Error codes

const EInvalidPublisher: u64 = 0;
const EInvalidProofType: u64 = 1;
const EResolverDisabled: u64 = 3;
const EInvalidConfidence: u64 = 4;

const PCT_PRECISION: u64 = 10_000;

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

public fun make_resolution<Proof: drop>(
    resolver: &Resolver,
    _proof: Proof,
    query_id: ID,
    claim: vector<u8>,
    confidence: u64,
    clock: &Clock,
): Resolution {
    assert!(resolver.is_enabled, EResolverDisabled);
    assert!(resolver.proof_type == type_name::get<Proof>(), EInvalidProofType);
    assert!(confidence <= PCT_PRECISION, EInvalidConfidence);

    Resolution {
        claim,
        query_id,
        confidence,
        proof_type: resolver.proof_type,
        timestamp_ms: clock.timestamp_ms(),
    }
}

public fun is_enabled(resolver: &Resolver): bool {
    resolver.is_enabled
}

public fun proof_type(resolver: &Resolver): TypeName {
    resolver.proof_type
}

// View functions for Resolution
public fun resolution_query_id(resolution: &Resolution): ID {
    resolution.query_id
}

public fun resolution_claim(resolution: &Resolution): vector<u8> {
    resolution.claim
}

public fun resolution_confidence(resolution: &Resolution): u64 {
    resolution.confidence
}

public fun resolution_timestamp_ms(resolution: &Resolution): u64 {
    resolution.timestamp_ms
}

public fun resolution_proof_type(resolution: &Resolution): TypeName {
    resolution.proof_type
}
