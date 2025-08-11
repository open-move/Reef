#[test_only]
module reef::dummy_resolver;

use reef::resolver::{Self, Resolver, Resolution, ChallengeRequest};
use std::type_name;
use sui::clock::Clock;
use sui::package;

public struct DummyResolver() has drop;

public fun create_resolver(ctx: &mut TxContext): Resolver {
    let publisher = package::test_claim(DummyResolver(), ctx);
    resolver::create(DummyResolver(), publisher, ctx)
}

public fun resolve_challenge<CoinType>(
    resolver: &Resolver,
    challenge_request: ChallengeRequest<CoinType>,
    resolution_claim: vector<u8>,
    clock: &Clock,
): Resolution {
    let (query_id, fee, _, _, _) = challenge_request.unpack_challenge_request(DummyResolver());

    // Burn the fee for testing
    fee.into_coin(&mut sui::tx_context::dummy()).burn_for_testing();

    resolver.make_resolution<DummyResolver>(
        DummyResolver(),
        query_id,
        resolution_claim,
        clock,
    )
}

public fun make_test_resolution(
    resolver: &Resolver,
    query_id: ID,
    claim: vector<u8>,
    clock: &Clock,
): Resolution {
    resolver::make_resolution<DummyResolver>(
        resolver,
        DummyResolver(),
        query_id,
        claim,
        clock,
    )
}

public fun get_witness(): std::type_name::TypeName {
    type_name::get<DummyResolver>()
}

public fun resolve_submitter_wins<CoinType>(
    resolver: &Resolver,
    challenge_request: ChallengeRequest<CoinType>,
    original_claim: vector<u8>,
    clock: &Clock,
): Resolution {
    resolve_challenge(resolver, challenge_request, original_claim, clock)
}

public fun resolve_challenger_wins<CoinType>(
    resolver: &Resolver,
    challenge_request: ChallengeRequest<CoinType>,
    new_claim: vector<u8>,
    clock: &Clock,
): Resolution {
    resolve_challenge(resolver, challenge_request, new_claim, clock)
}
