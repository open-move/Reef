module dummy_resolver::dummy_resolver;

use reef::resolver::{Self, ResolverCap};
use sui::package;

public struct DummyResolver has key {
    id: UID,
    resolver_cap: ResolverCap,
}

public struct DUMMY_RESOLVER() has drop;

public struct Witness() has drop;

fun init(otw: DUMMY_RESOLVER, ctx: &mut TxContext) {
    let publisher = package::claim(otw, ctx);

    let (resolver, resolver_cap) = resolver::create(Witness(), publisher, ctx);
    resolver.share();

    transfer::share_object(DummyResolver { id: object::new(ctx), resolver_cap })
}
