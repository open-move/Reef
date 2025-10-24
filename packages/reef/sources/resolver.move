module reef::resolver;

use reef::protocol::ProtocolCap;
use sui::balance::Balance;
use sui::clock::Clock;
use sui::derived_object;
use sui::event;
use sui::package::Publisher;

public struct Resolver has key {
    id: UID,
    is_enabled: bool,
}

public struct ResolverCap has key, store {
    id: UID,
    resolver_id: ID,
}

public struct Resolution has drop {
    query_id: ID,
    resolver_id: ID,
    data: vector<u8>,
    resolved_at_ms: u64,
}

public struct DisputeTicket<phantom T> {
    query_id: ID,
    disputer: address,
    resolver_id: ID,
    disputed_at_ms: u64,
    fee: Balance<T>,
    verification_bond_amount: u64,
}

public struct ResolverCapKey() has copy, drop, store;

public struct ResolverEnabled has copy, drop {
    resolver_id: ID,
}

public struct ResolverDisabled has copy, drop {
    resolver_id: ID,
}

public use fun resolution_data as Resolution.data;
public use fun resolution_query_id as Resolution.query_id;
public use fun resolution_resolver_id as Resolution.resolver_id;
public use fun resolution_resolved_at_ms as Resolution.resolved_at_ms;

public use fun unpack_dispute_ticket as DisputeTicket.unpack;

/// Thrown when publisher is not from the witness module
const EInvalidPublisher: u64 = 0;
/// Thrown when resolver cap doesn't match resolver ID
const EInvalidResolverCap: u64 = 1;
/// Thrown when resolver is disabled and cannot create resolutions
const EResolverDisabled: u64 = 2;

/// Creates a new resolver. Resolver starts disabled and must be enabled by
/// protocol governance before it can provide resolutions. Authorization is
/// managed through the ResolverCap.
///
/// @param _witness Witness for module verification (consumed)
/// @param publisher Publisher from witness module (consumed for verification)
/// @param ctx Transaction context
///
/// @return (Resolver object, ResolverCap for authorization)
public fun create<Witness: drop>(
    _witness: Witness,
    publisher: Publisher,
    ctx: &mut TxContext,
): (Resolver, ResolverCap) {
    assert!(publisher.from_module<Witness>(), EInvalidPublisher);
    publisher.burn();

    let mut resolver = Resolver {
        id: object::new(ctx),
        is_enabled: false,
    };

    let resolver_cap = ResolverCap {
        resolver_id: resolver.id.to_inner(),
        id: derived_object::claim(&mut resolver.id, ResolverCapKey()),
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
    event::emit(ResolverEnabled { resolver_id: resolver.id.to_inner() });
}

/// Disables the resolver from providing new resolutions.
///
/// @param resolver Resolver to disable
/// @param _cap ProtocolCap for authorization
public fun disable(resolver: &mut Resolver, _: &ProtocolCap) {
    resolver.is_enabled = false;
    event::emit(ResolverDisabled { resolver_id: resolver.id.to_inner() });
}

/// Returns the ID of the resolver.
///
/// @param resolver Resolver to get ID from
///
/// @return Resolver's object ID
public fun id(resolver: &Resolver): ID {
    resolver.id.to_inner()
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
/// cap must match the resolver.
///
/// @param resolver Resolver instance (must be enabled)
/// @param cap ResolverCap for authorization
/// @param query_id ID of query being resolved
/// @param data Authoritative data for resolution
/// @param clock System clock for timestamp
///
/// @return Resolution object for settlement
public fun make_resolution(
    resolver: &Resolver,
    cap: &ResolverCap,
    query_id: ID,
    data: vector<u8>,
    clock: &Clock,
): Resolution {
    assert!(resolver.is_enabled, EResolverDisabled);
    assert!(resolver.id.to_inner() == cap.resolver_id, EInvalidResolverCap);

    Resolution {
        data,
        query_id,
        resolver_id: resolver.id.to_inner(),
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

/// Returns the resolver ID that created this resolution.
///
/// @param resolution Resolution to check
///
/// @return ID of the resolver that created this resolution
public fun resolution_resolver_id(resolution: &Resolution): ID {
    resolution.resolver_id
}

public(package) fun new_dispute_ticket<T>(
    query_id: ID,
    resolver_id: ID,
    fee: Balance<T>,
    disputer: address,
    timestamp_ms: u64,
    verification_bond_amount: u64,
): DisputeTicket<T> {
    DisputeTicket {
        fee,
        query_id,
        disputer,
        resolver_id,
        verification_bond_amount,
        disputed_at_ms: timestamp_ms,
    }
}

/// Unpacks a dispute ticket for processing by a resolver. Validates that the
/// cap matches the resolver ID in the ticket.
///
/// @param request DisputeTicket to unpack (consumed)
/// @param cap ResolverCap for authorization
///
/// @return (query_id, resolver_id, fee_balance, disputer_address, disputed_timestamp, verification_bond_amount)
public fun unpack_dispute_ticket<T>(
    request: DisputeTicket<T>,
    cap: &ResolverCap,
): (ID, ID, Balance<T>, address, u64, u64) {
    let DisputeTicket {
        fee,
        query_id,
        disputer,
        resolver_id,
        disputed_at_ms,
        verification_bond_amount,
    } = request;

    assert!(cap.resolver_id == resolver_id, EInvalidResolverCap);
    (query_id, resolver_id, fee, disputer, disputed_at_ms, verification_bond_amount)
}
