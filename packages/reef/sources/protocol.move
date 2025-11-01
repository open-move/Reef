module reef::protocol;

use std::type_name::{Self, TypeName};
use sui::derived_object;
use sui::event;
use sui::package::{Self, Publisher};
use sui::table::{Self, Table};
use sui::versioned::{Self, Versioned};

public struct PROTOCOL() has drop;

public struct Protocol has key, store {
    id: UID,
    inner: Versioned,
}

public struct ProtocolStateV1 has store {
    fee_factor_bps: u64,
    default_liveness_ms: u64,
    resolver_fees: Table<TypeName, u64>,
    supported_topics: Table<vector<u8>, bool>,
    supported_coin_types: Table<TypeName, bool>,
}

public struct ProtocolCap has key {
    id: UID,
}

public struct ProtocolCapKey() has copy, drop, store;

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

public struct TopicAdded has copy, drop {
    topic: vector<u8>,
}

public struct TopicRemoved has copy, drop {
    topic: vector<u8>,
}

public struct CoinTypeAdded has copy, drop {
    coin_type: TypeName,
}

public struct CoinTypeRemoved has copy, drop {
    coin_type: TypeName,
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

    let protocol_v1 = ProtocolStateV1 {
        resolver_fees: table::new(ctx),
        supported_topics: table::new(ctx),
        fee_factor_bps: default_fee_factor!(),
        supported_coin_types: table::new(ctx),
        default_liveness_ms: min_liveness_ms!(),
    };

    let mut protocol = Protocol {
        id: object::new(ctx),
        inner: versioned::create(current_protocol_version!(), protocol_v1, ctx),
    };

    let protocol_cap = ProtocolCap {
        id: derived_object::claim(&mut protocol.id, ProtocolCapKey()),
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
    assert!(liveness_ms >= min_liveness_ms!(), EInvalidLiveness);
    let state = protocol.load_state_mut!();
    let old_ms = state.default_liveness_ms;
    state.default_liveness_ms = liveness_ms;

    event::emit(DefaultLivenessChanged { old_ms, new_ms: liveness_ms });
}

/// Sets the fee factor in basis points for bond calculation. Lower values
/// require higher bonds relative to resolution fees. Used in formula:
/// minimum_bond = (resolver_fee * 10000) / fee_factor_bps
///
/// @param protocol Protocol object
/// @param _cap ProtocolCap for authorization
/// @param fee_factor_bps Fee factor (1-10000 basis points, used in minimum bond calculation)
public fun set_fee_factor_bps(protocol: &mut Protocol, _: &ProtocolCap, fee_factor_bps: u64) {
    assert!(fee_factor_bps > 0 && fee_factor_bps <= bps!(), EInvalidFeeFactor);
    let state = protocol.load_state_mut!();
    let old_bps = state.fee_factor_bps;
    state.fee_factor_bps = fee_factor_bps;

    event::emit(FeeFactorChanged { old_bps, new_bps: fee_factor_bps });
}

/// Adds a topic to the list of supported query topics.
///
/// @param protocol Protocol object
/// @param _cap ProtocolCap for authorization
/// @param topic Topic identifier bytes to support
public fun add_supported_topic(protocol: &mut Protocol, _: &ProtocolCap, topic: vector<u8>) {
    assert!(!topic.is_empty(), EEmptyTopic);
    assert!(topic.length() <= max_topic_length!(), ETopicTooLong);

    protocol.load_state_mut!().supported_topics.add(topic, true);
    event::emit(TopicAdded { topic });
}

/// Removes a topic from the list of supported query topics.
///
/// @param protocol Protocol object
/// @param _cap ProtocolCap for authorization
/// @param topic Topic identifier bytes to remove
public fun remove_supported_topic(protocol: &mut Protocol, _: &ProtocolCap, topic: vector<u8>) {
    protocol.load_state_mut!().supported_topics.remove(topic);
    event::emit(TopicRemoved { topic });
}

/// Adds a coin type to the list of supported currencies for bonds.
public fun add_supported_coin_type<T>(protocol: &mut Protocol, _: &ProtocolCap) {
    let coin_type = type_name::with_defining_ids<T>();
    let state = protocol.load_state_mut!();
    state.supported_coin_types.add(coin_type, true);

    event::emit(CoinTypeAdded { coin_type });
}

/// Removes a coin type from the list of supported currencies.
public fun remove_supported_coin_type<T>(protocol: &mut Protocol, _: &ProtocolCap) {
    let coin_type = type_name::with_defining_ids<T>();
    let state = protocol.load_state_mut!();
    state.supported_coin_types.remove(coin_type);

    event::emit(CoinTypeRemoved { coin_type });
}

/// Sets the resolution fee for a specific coin type.
/// This fee determines the minimum bond amount required.
public fun set_resolver_fee<T>(protocol: &mut Protocol, _: &ProtocolCap, fee: u64) {
    let coin_type = type_name::with_defining_ids<T>();
    let state = protocol.load_state_mut!();
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
    let state = protocol.load_state_mut!();

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
    let state = protocol.load_state!();

    assert!(state.resolver_fees.contains(coin_type), EUnsupportedCoinType);
    state.resolver_fees[coin_type]
}

/// Checks if a coin type is supported for bonds.
///
/// @param protocol Protocol to check
///
/// @return true if coin type is supported
public fun is_coin_type_supported<T>(protocol: &Protocol): bool {
    protocol.load_state!().supported_coin_types.contains(type_name::with_defining_ids<T>())
}

/// Checks if a topic is supported for queries.
///
/// @param protocol Protocol to check
/// @param topic Topic identifier bytes
///
/// @return true if topic is supported
public fun is_topic_supported(protocol: &Protocol, topic: vector<u8>): bool {
    protocol.load_state!().supported_topics.contains(topic)
}

/// Returns the default liveness period in milliseconds.
///
/// @param protocol Protocol object
///
/// @return Default liveness period in milliseconds
public fun default_liveness_ms(protocol: &Protocol): u64 {
    protocol.load_state!().default_liveness_ms
}

/// Calculates the minimum bond amount for a coin type using the protocol's
/// fee factor and resolution fee. Higher fee factors result in lower bond requirements.
///
/// @param protocol Protocol object
///
/// @return Minimum bond amount using formula: (resolver_fee * 10000) / fee_factor_bps
public fun minimum_bond<T>(protocol: &Protocol): u64 {
    let state = protocol.load_state!();

    let coin_type = type_name::with_defining_ids<T>();
    assert!(state.resolver_fees.contains(coin_type), EUnsupportedCoinType);

    (
        (state.resolver_fees[coin_type] as u128) * (bps!() as u128) / (state.fee_factor_bps as u128),
    ) as u64
}

/// Returns the fee factor in basis points.
///
/// @param protocol Protocol object
///
/// @return Fee factor (1-10000 basis points)
public fun fee_factor_bps(protocol: &Protocol): u64 {
    protocol.load_state!().fee_factor_bps
}

public macro fun min_liveness_ms(): u64 {
    5 * 60 * 1000
}

public macro fun bps(): u64 {
    10_000
}

/// Loads the immutable protocol state for the current version.
macro fun load_state($protocol: &Protocol): &ProtocolStateV1 {
    let protocol = $protocol;
    assert!(protocol.inner.version() == current_protocol_version!(), EInvalidProtocolVersion);
    protocol.inner.load_value()
}

/// Loads the mutable protocol state for the current version.
macro fun load_state_mut($protocol: &mut Protocol): &mut ProtocolStateV1 {
    let protocol = $protocol;
    assert!(protocol.inner.version() == current_protocol_version!(), EInvalidProtocolVersion);
    protocol.inner.load_value_mut()
}

macro fun default_fee_factor(): u64 {
    5000
}

macro fun current_protocol_version(): u64 {
    1
}

public macro fun max_topic_length(): u64 {
    256 // Maximum 256 bytes for a topic
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    package::claim_and_keep(PROTOCOL(), ctx);
}
