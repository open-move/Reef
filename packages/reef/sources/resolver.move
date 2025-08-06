module reef::resolver;

use std::type_name::{Self, TypeName};

public struct Resolver has key {
    id: UID,
    instance_id: ID,
    is_enabled: bool,
    proof_type: TypeName,
}

public struct Resolution {
    claim: vector<u8>,
}

const EInvalidProofType: u64 = 0;

public fun create<Proof: drop>(_: Proof, instance_id: ID, ctx: &mut TxContext): Resolver {
    Resolver {
        id: object::new(ctx),
        instance_id,
        is_enabled: true,
        proof_type: type_name::get<Proof>(),
    }
}

public fun share_resolver(resolver: Resolver) {
    transfer::share_object(resolver)
}

public fun enable(resolver: &mut Resolver) {
    resolver.is_enabled = true;
}

public fun disable(resolver: &mut Resolver) {
    resolver.is_enabled = false;
}

public fun create_resolution<Proof: drop>(
    resolver: &mut Resolver,
    _: Proof,
    claim: vector<u8>,
): Resolution {
    assert!(resolver.proof_type == type_name::get<Proof>(), EInvalidProofType);

    Resolution {
        claim,
    }
}

public fun destroy_resolution(resolution: Resolution): vector<u8> {
    let Resolution { claim } = resolution;
    claim
}
