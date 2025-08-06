module reef::resolver;

use std::type_name::{Self, TypeName};
use sui::clock::Clock;
use sui::package::Publisher;
use reef::protocol::ProtocolCap;

public struct Resolver has key {
    id: UID,
    is_enabled: bool,
    proof_type: TypeName,
}

public struct Resolution { confidence: u64, timestamp_ms: u64, claim: vector<u8> }

// Error codes

const EInvalidPublisher: u64 = 0;
const EInvalidProofType: u64 = 1;
const EInvalidConfidence: u64 = 2;

const MAX_CONFIDENCE: u64 = 10_000;

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

public fun enable(_: ProtocolCap, resolver: &mut Resolver) {
    resolver.is_enabled = true;
}

public fun disable(_: ProtocolCap, resolver: &mut Resolver) {
    resolver.is_enabled = false;
}

public fun create_resolution<Proof: drop>(
    resolver: &Resolver,
    _proof: Proof,
    claim: vector<u8>,
    confidence: u64,
    clock: &Clock,
): Resolution {
    assert!(resolver.proof_type == type_name::get<Proof>(), EInvalidProofType);
    assert!(confidence <= MAX_CONFIDENCE, EInvalidConfidence);

    Resolution {
        claim,
        confidence,
        timestamp_ms: clock.timestamp_ms(),
    }
}

public fun destroy_resolution(resolution: Resolution): (vector<u8>, u64, u64) {
    let Resolution { claim, timestamp_ms, confidence } = resolution;
    (claim, timestamp_ms, confidence)
}

public fun is_enabled(resolver: &Resolver): bool {
    resolver.is_enabled
}

public fun proof_type(resolver: &Resolver): TypeName {
    resolver.proof_type
}

public fun resolution_claim(resolution: &Resolution): vector<u8> {
    resolution.claim
}

public fun resolution_timestamp_ms(resolution: &Resolution): u64 {
    resolution.timestamp_ms
}

public fun resolution_confidence(resolution: &Resolution): u64 {
    resolution.confidence
}
