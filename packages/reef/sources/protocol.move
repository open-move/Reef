module reef::protocol;

use reef::macros;
use reef::schema::{Self, Schema, SchemaRef};
use reef::versioned_object::{Self, VersionedObject};
use std::type_name::{Self, TypeName};
use sui::derived_object;
use sui::event;
use sui::package::{Self, Publisher};
use sui::table::{Self, Table};

public struct PROTOCOL() has drop;

public struct Protocol has key, store {
    id: UID,
    inner: VersionedObject,
}

public struct ProtocolInnerkey(u64) has copy, drop, store;

public struct ProtocolInner has key, store {
    id: UID,
    num_queries: u64,
    fee_factor_bps: u64,
    default_liveness_ms: u64,
    resolver_fees: Table<TypeName, u64>,
    topic_schemas: Table<SchemaRef, SchemaEntry>,
    supported_coin_types: Table<TypeName, bool>,
    last_schema_versions: Table<vector<u8>, u64>,
}

public struct SchemaEntry has copy, drop, store {
    active: bool,
    schema: Schema,
}

public struct ProtocolCap has key {
    id: UID,
}

public struct ProtocolCapKey() has copy, drop, store;

const PROTOCOL_VERSION: u64 = 1;

public struct DefaultLivenessChanged has copy, drop {
    old_ms: u64,
    new_ms: u64,
}

public struct FeeFactorChanged has copy, drop {
    old_bps: u64,
    new_bps: u64,
}

public struct ResolverFeeSet has copy, drop {
    coin_type: TypeName,
    fee: u64,
}

public struct ResolverFeeRemoved has copy, drop {
    coin_type: TypeName,
}

public struct CoinTypeAdded has copy, drop {
    coin_type: TypeName,
}

public struct CoinTypeRemoved has copy, drop {
    coin_type: TypeName,
}

public struct TopicSchemaSet has copy, drop {
    version: u64,
    topic: vector<u8>,
}

public struct TopicSchemaDeactivated has copy, drop {
    version: u64,
    topic: vector<u8>,
}

/// Thrown when liveness period is below minimum required
const EInvalidLiveness: u64 = 0;
/// Thrown when publisher is not from this module
const EInvalidPublisher: u64 = 1;
/// Thrown when fee factor is zero or exceeds maximum basis points
const EInvalidFeeFactor: u64 = 2;
/// Thrown when coin type is not supported or resolution fee not set
const EUnsupportedCoinType: u64 = 3;
/// Thrown when topic is empty
const EEmptyTopic: u64 = 4;
/// Thrown when topic exceeds maximum length
const ETopicTooLong: u64 = 5;
/// Thrown when protocol version is invalid
const EInvalidProtocolVersion: u64 = 6;
/// Thrown when schema does not exist for topic
const ESchemaNotFound: u64 = 7;

fun init(otw: PROTOCOL, ctx: &mut TxContext) {
    package::claim_and_keep(otw, ctx);
}

/// Initializes the protocol with default settings. Creates the global protocol
/// config with empty tables for topics/coins and default fee parameters.
/// Returns capability for governance.
///
/// @param publisher Publisher from this module (consumed, so it can only be called once)
/// @param ctx Transaction context
///
/// @return (Protocol object, ProtocolCap for governance)
public fun initialize(publisher: Publisher, ctx: &mut TxContext): (Protocol, ProtocolCap) {
    assert!(publisher.from_module<PROTOCOL>(), EInvalidPublisher);

    let mut protocol_uid = object::new(ctx);

    let protocol_v1 = ProtocolInner {
        id: derived_object::claim(&mut protocol_uid, ProtocolInnerkey(PROTOCOL_VERSION)),
        num_queries: 0,
        resolver_fees: table::new(ctx),
        topic_schemas: table::new(ctx),
        supported_coin_types: table::new(ctx),
        last_schema_versions: table::new(ctx),
        fee_factor_bps: macros::default_fee_factor!(),
        default_liveness_ms: macros::min_liveness_ms!(),
    };

    let protocol_cap = ProtocolCap {
        id: derived_object::claim(&mut protocol_uid, ProtocolCapKey()),
    };

    let protocol = Protocol {
        id: protocol_uid,
        inner: versioned_object::create(PROTOCOL_VERSION, protocol_v1, ctx),
    };

    publisher.burn();
    (protocol, protocol_cap)
}

/// Transfers the ProtocolCap to another address.
///
/// @param cap ProtocolCap to transfer (consumed)
/// @param recipient Address to receive the capability
public fun transfer_cap(cap: ProtocolCap, recipient: address) {
    transfer::transfer(cap, recipient)
}

/// Sets the default liveness period for new queries. This affects queries
/// created without explicit liveness settings. Must meet minimum requirements.
///
/// @param protocol Protocol object
/// @param _cap ProtocolCap for authorization
/// @param liveness_ms New default liveness in milliseconds (must be >= minimum)
public fun set_default_liveness_ms(protocol: &mut Protocol, _: &ProtocolCap, liveness_ms: u64) {
    assert!(liveness_ms >= macros::min_liveness_ms!(), EInvalidLiveness);
    let state = protocol.load_inner_mut();
    let old_ms = state.default_liveness_ms;
    state.default_liveness_ms = liveness_ms;

    event::emit(DefaultLivenessChanged { old_ms, new_ms: liveness_ms });
}

/// Sets the fee factor in basis points for bond calculation. Lower values
/// require higher bonds relative to resolution fees. Used in formula:
/// minimum_bond_amount = (resolver_fee * 10000) / fee_factor_bps
///
/// @param protocol Protocol object
/// @param _cap ProtocolCap for authorization
/// @param fee_factor_bps Fee factor (1-10000 basis points, used in minimum bond calculation)
public fun set_fee_factor_bps(protocol: &mut Protocol, _: &ProtocolCap, fee_factor_bps: u64) {
    assert!(fee_factor_bps > 0 && fee_factor_bps <= macros::bps!(), EInvalidFeeFactor);
    let state = protocol.load_inner_mut();
    let old_bps = state.fee_factor_bps;
    state.fee_factor_bps = fee_factor_bps;

    event::emit(FeeFactorChanged { old_bps, new_bps: fee_factor_bps });
}

/// Adds a coin type to the list of supported currencies for bonds.
public fun add_supported_coin_type<T>(protocol: &mut Protocol, _: &ProtocolCap) {
    let coin_type = type_name::with_defining_ids<T>();
    let state = protocol.load_inner_mut();
    state.supported_coin_types.add(coin_type, true);

    event::emit(CoinTypeAdded { coin_type });
}

/// Removes a coin type from the list of supported currencies.
public fun remove_supported_coin_type<T>(protocol: &mut Protocol, _: &ProtocolCap) {
    let coin_type = type_name::with_defining_ids<T>();
    let state = protocol.load_inner_mut();
    state.supported_coin_types.remove(coin_type);

    event::emit(CoinTypeRemoved { coin_type });
}

/// Sets the resolution fee for a specific coin type.
/// This fee determines the minimum bond amount required.
public fun set_resolver_fee<T>(protocol: &mut Protocol, _: &ProtocolCap, fee: u64) {
    let coin_type = type_name::with_defining_ids<T>();
    let state = protocol.load_inner_mut();
    assert!(state.supported_coin_types.contains(coin_type), EUnsupportedCoinType);

    if (state.resolver_fees.contains(coin_type)) {
        state.resolver_fees.remove(coin_type);
    };

    state.resolver_fees.add(coin_type, fee);
    event::emit(ResolverFeeSet { coin_type, fee });
}

/// Removes the resolution fee for a specific coin type.
public fun remove_resolver_fee<T>(protocol: &mut Protocol, _: &ProtocolCap) {
    let coin_type = type_name::with_defining_ids<T>();
    let state = protocol.load_inner_mut();

    assert!(state.resolver_fees.contains(coin_type), EUnsupportedCoinType);
    state.resolver_fees.remove(coin_type);

    event::emit(ResolverFeeRemoved { coin_type });
}

/// Returns the resolution fee for a specific coin type.
///
/// @param protocol Protocol object
///
/// @return Resolution fee amount
public fun resolver_fee<T>(protocol: &Protocol): u64 {
    let coin_type = type_name::with_defining_ids<T>();
    let state = protocol.load_inner();

    assert!(state.resolver_fees.contains(coin_type), EUnsupportedCoinType);
    state.resolver_fees[coin_type]
}

/// Checks if a coin type is supported for bonds.
///
/// @param protocol Protocol to check
///
/// @return true if coin type is supported
public fun is_coin_type_supported<T>(protocol: &Protocol): bool {
    protocol.load_inner().supported_coin_types.contains(type_name::with_defining_ids<T>())
}

/// Returns the default liveness period in milliseconds.
///
/// @param protocol Protocol object
///
/// @return Default liveness period in milliseconds
public fun default_liveness_ms(protocol: &Protocol): u64 {
    protocol.load_inner().default_liveness_ms
}

/// Calculates the minimum bond amount for a coin type using the protocol's
/// fee factor and resolution fee. Higher fee factors result in lower bond requirements.
///
/// @param protocol Protocol object
///
/// @return Minimum bond amount using formula: (resolver_fee * 10000) / fee_factor_bps
public fun minimum_bond_amount<T>(protocol: &Protocol): u64 {
    let state = protocol.load_inner();

    let coin_type = type_name::with_defining_ids<T>();
    assert!(state.resolver_fees.contains(coin_type), EUnsupportedCoinType);

    (
        (state.resolver_fees[coin_type] as u128) * (macros::bps!() as u128) / (state.fee_factor_bps as u128),
    ) as u64
}

/// Returns the fee factor in basis points.
///
/// @param protocol Protocol object
///
/// @return Fee factor (1-10000 basis points)
public fun fee_factor_bps(protocol: &Protocol): u64 {
    protocol.load_inner().fee_factor_bps
}

public fun num_queries(protocol: &Protocol): u64 {
    protocol.load_inner().num_queries
}

/// Registers a schema for a topic. Standard schemas enable proposal validation.
/// Enforces monotonic versioning - each new version must be previous + 1.
///
/// @param protocol Protocol object
/// @param _cap ProtocolCap for authorization
/// @param topic Topic identifier that the schema applies to
/// @param version Version number (must be previous + 1)
/// @param schema Schema definition for validation
/// @param clock System clock for timestamp
public fun set_topic_schema(
    protocol: &mut Protocol,
    _: &ProtocolCap,
    topic: vector<u8>,
    schema: Schema,
) {
    assert!(!topic.is_empty(), EEmptyTopic);
    assert!(topic.length() <= macros::max_topic_length!(), ETopicTooLong);

    let state = protocol.load_inner_mut();
    let last_version = if (state.last_schema_versions.contains(topic)) {
        state.last_schema_versions[topic]
    } else {
        0
    };

    let new_version = last_version + 1;
    let schema_ref = schema::new_schema_ref(topic, new_version);

    // Mark old version as inactive if it exists
    if (new_version > 1) {
        let old_ref = schema::new_schema_ref(topic, last_version);
        if (state.topic_schemas.contains(old_ref)) {
            let old_entry = &mut state.topic_schemas[old_ref];
            old_entry.active = false;
        };
    };

    state.topic_schemas.add(schema_ref, SchemaEntry { schema, active: true });

    // Update last version
    if (state.last_schema_versions.contains(topic)) {
        state.last_schema_versions.remove(topic);
    };

    state.last_schema_versions.add(topic, new_version);
    event::emit(TopicSchemaSet { topic, version: new_version });
}

/// Marks a schema as inactive. Never deletes to preserve history.
///
/// @param protocol Protocol object
/// @param _cap ProtocolCap for authorization
/// @param topic Topic identifier
/// @param version Version to mark inactive
public fun deactivate_topic_schema(
    protocol: &mut Protocol,
    _: &ProtocolCap,
    topic: vector<u8>,
    version: u64,
) {
    let state = protocol.load_inner_mut();
    let schema_ref = schema::new_schema_ref(topic, version);

    assert!(state.topic_schemas.contains(schema_ref), ESchemaNotFound);

    let entry = &mut state.topic_schemas[schema_ref];
    entry.active = false;

    event::emit(TopicSchemaDeactivated { topic, version });
}

/// Gets a registered schema for a topic. Must be active.
///
/// @param protocol Protocol object
/// @param topic Topic to get schema for
/// @param version Version to retrieve
///
/// @return Schema for the topic
public fun topic_schema(protocol: &Protocol, topic: vector<u8>, version: u64): &Schema {
    let state = protocol.load_inner();
    let schema_ref = schema::new_schema_ref(topic, version);

    assert!(state.topic_schemas.contains(schema_ref), ESchemaNotFound);
    &state.topic_schemas[schema_ref].schema
}

/// Checks if a schema is registered for a topic.
///
/// @param protocol Protocol object
/// @param topic Topic to check
///
/// @return true if schema exists for topic
public fun has_topic_schema(protocol: &Protocol, topic: vector<u8>, version: u64): bool {
    protocol.load_inner().topic_schemas.contains(schema::new_schema_ref(topic, version))
}

public(package) fun extend(protocol: &mut Protocol): &mut UID {
    &mut protocol.id
}

public(package) fun increment_num_queries(protocol: &mut Protocol) {
    let inner = protocol.load_inner_mut();
    inner.num_queries = inner.num_queries + 1;
}

/// Loads the immutable inner protocol for the current version.
fun load_inner(protocol: &Protocol): &ProtocolInner {
    assert!(protocol.inner.version() == PROTOCOL_VERSION, EInvalidProtocolVersion);
    protocol.inner.load_value()
}

/// Loads the mutable inner protocol for the current version.
fun load_inner_mut(protocol: &mut Protocol): &mut ProtocolInner {
    assert!(protocol.inner.version() == PROTOCOL_VERSION, EInvalidProtocolVersion);
    protocol.inner.load_value_mut()
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    package::claim_and_keep(PROTOCOL(), ctx);
}

#[test_only]
public fun load_inner_for_testing(protocol: &Protocol): &ProtocolInner {
    protocol.load_inner()
}
