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

/// Thrown when publisher is not from the witness module
const EInvalidPublisher: u64 = 0;
/// Thrown when witness type doesn't match resolver or dispute ticket
const EInvalidWitnessType: u64 = 1;
/// Thrown when resolver is disabled and cannot create resolutions
const EResolverDisabled: u64 = 2;

/// Creates a new resolver with the given witness type. Resolver starts disabled
/// and must be enabled by protocol governance before it can provide resolutions.
/// Witness type determines authorization for resolution creation.
///
/// @param _witness Witness for authentication (consumed)
/// @param publisher Publisher from witness module (consumed for verification)
/// @param ctx Transaction context
///
/// @return (Resolver object, ResolverCap for governance)
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

/// Shares the resolver object.
///
/// @param resolver Resolver to share (consumed)
public fun share(resolver: Resolver) {
    transfer::share_object(resolver)
}

/// Enables the resolver to provide resolutions. Once enabled, the resolver
/// can create authoritative resolutions for disputed queries.
///
/// @param resolver Resolver to enable
/// @param _cap ProtocolCap for authorization
public fun enable(resolver: &mut Resolver, _: &ProtocolCap) {
    resolver.is_enabled = true;
}

/// Disables the resolver from providing new resolutions.
///
/// @param resolver Resolver to disable
/// @param _cap ProtocolCap for authorization
public fun disable(resolver: &mut Resolver, _: &ProtocolCap) {
    resolver.is_enabled = false;
}

/// Returns the resolver ID associated with this capability.
///
/// @param cap ResolverCap to check
///
/// @return Resolver object ID
public fun cap_resolver_id(cap: &ResolverCap): ID {
    cap.resolver_id
}

/// Creates a resolution for a disputed query. Provides authoritative data
/// that determines the winner of the dispute. Resolver must be enabled and
/// witness type must match.
///
/// @param resolver Resolver instance (must be enabled)
/// @param _witness Witness for authentication (consumed)
/// @param query_id ID of query being resolved
/// @param data Authoritative data for resolution
/// @param clock System clock for timestamp
///
/// @return Resolution object for settlement
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

/// Returns whether the resolver is currently enabled.
///
/// @param resolver Resolver to check
///
/// @return True if resolver can create resolutions
public fun is_enabled(resolver: &Resolver): bool {
    resolver.is_enabled
}

/// Returns the witness type for this resolver.
///
/// @param resolver Resolver to check
///
/// @return TypeName of the witness used for authorization
public fun witness_type(resolver: &Resolver): TypeName {
    resolver.witness_type
}

/// Returns the query ID this resolution applies to.
///
/// @param resolution Resolution to check
///
/// @return Query ID
public fun resolution_query_id(resolution: &Resolution): ID {
    resolution.query_id
}

/// Returns the resolved data.
///
/// @param resolution Resolution to check
///
/// @return Authoritative data bytes
public fun resolution_data(resolution: &Resolution): vector<u8> {
    resolution.data
}

/// Returns when this resolution was created (in milliseconds).
///
/// @param resolution Resolution to check
///
/// @return Timestamp in milliseconds
public fun resolution_resolved_at_ms(resolution: &Resolution): u64 {
    resolution.resolved_at_ms
}

/// Returns the witness type that created this resolution.
///
/// @param resolution Resolution to check
///
/// @return TypeName of creating witness
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

/// Unpacks a dispute ticket for processing by a resolver. Validates witness
/// type matches expected resolver and returns all ticket components.
///
/// @param request DisputeTicket to unpack (consumed)
/// @param _witness Witness for authorization (consumed)
///
/// @return (query_id, fee_balance, disputer_address, disputed_timestamp, resolver_witness_type)
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
