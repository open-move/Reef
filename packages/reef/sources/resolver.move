module reef::resolver;

use reef::protocol::ProtocolCap;
use std::type_name::{Self, TypeName};
use sui::balance::Balance;
use sui::clock::Clock;
use sui::package::Publisher;

public struct Resolver has key {
    id: UID,
    is_enabled: bool,
    witness_type: TypeName,
}

public struct ResolverCap has key, store {
    id: UID,
    resolver_id: ID,
}

public struct Resolution has drop {
    query_id: ID,
    data: vector<u8>,
    resolved_at_ms: u64,
    witness_type: TypeName,
}

public struct DisputeTicket<phantom CoinType> {
    query_id: ID,
    disputer: address,
    disputed_at_ms: u64,
    fee: Balance<CoinType>,
    resolver_witness: TypeName,
}

public use fun resolution_data as Resolution.data;
public use fun resolution_query_id as Resolution.query_id;
public use fun resolution_witness_type as Resolution.witness_type;
public use fun resolution_resolved_at_ms as Resolution.resolved_at_ms;

public use fun unpack_dispute_ticket as DisputeTicket.unpack;

const EInvalidPublisher: u64 = 0;
const EInvalidWitnessType: u64 = 1;
const EResolverDisabled: u64 = 2;

public fun create<Witness: drop>(
    _witness: Witness,
    publisher: Publisher,
    ctx: &mut TxContext,
): (Resolver, ResolverCap) {
    assert!(publisher.from_module<Witness>(), EInvalidPublisher);
    publisher.burn();

    let resolver = Resolver {
        id: object::new(ctx),
        is_enabled: false,
        witness_type: type_name::with_defining_ids<Witness>(),
    };

    let resolver_cap = ResolverCap {
        id: object::new(ctx),
        resolver_id: resolver.id.to_inner(),
    };

    (resolver, resolver_cap)
}

public fun share(resolver: Resolver) {
    transfer::share_object(resolver)
}

public fun enable(resolver: &mut Resolver, _: &ProtocolCap) {
    resolver.is_enabled = true;
}

public fun disable(resolver: &mut Resolver, _: &ProtocolCap) {
    resolver.is_enabled = false;
}

public fun cap_resolver_id(cap: &ResolverCap): ID {
    cap.resolver_id
}

public fun make_resolution<Witness: drop>(
    resolver: &Resolver,
    _witness: Witness,
    query_id: ID,
    data: vector<u8>,
    clock: &Clock,
): Resolution {
    assert!(resolver.is_enabled, EResolverDisabled);
    assert!(resolver.witness_type == type_name::with_defining_ids<Witness>(), EInvalidWitnessType);

    Resolution {
        data,
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

public fun resolution_query_id(resolution: &Resolution): ID {
    resolution.query_id
}

public fun resolution_data(resolution: &Resolution): vector<u8> {
    resolution.data
}

public fun resolution_resolved_at_ms(resolution: &Resolution): u64 {
    resolution.resolved_at_ms
}

public fun resolution_witness_type(resolution: &Resolution): TypeName {
    resolution.witness_type
}

public(package) fun new_dispute_ticket<CoinType>(
    query_id: ID,
    fee: Balance<CoinType>,
    disputer: address,
    timestamp_ms: u64,
    resolver_witness: TypeName,
): DisputeTicket<CoinType> {
    DisputeTicket {
        fee,
        query_id,
        disputer,
        resolver_witness,
        disputed_at_ms: timestamp_ms,
    }
}

public fun unpack_dispute_ticket<CoinType, Witness: drop>(
    request: DisputeTicket<CoinType>,
    _witness: Witness,
): (ID, Balance<CoinType>, address, u64, TypeName) {
    let DisputeTicket {
        fee,
        query_id,
        disputer,
        resolver_witness,
        disputed_at_ms,
    } = request;

    assert!(resolver_witness == type_name::with_defining_ids<Witness>(), EInvalidWitnessType);
    (query_id, fee, disputer, disputed_at_ms, resolver_witness)
}
