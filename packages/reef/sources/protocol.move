module reef::protocol;

use std::type_name::{Self, TypeName};
use sui::derived_object;
use sui::package::{Self, Publisher};
use sui::table::{Self, Table};

public struct PROTOCOL() has drop;

public struct Protocol has key, store {
    id: UID,
    fee_factor_bps: u64,
    default_liveness_ms: u64,
    resolution_fees: Table<TypeName, u64>,
    supported_topics: Table<vector<u8>, bool>,
    supported_coin_types: Table<TypeName, bool>,
}

public struct ProtocolCap has key {
    id: UID,
}

public struct ProtocolCapKey() has copy, drop, store;

/// Thrown when liveness period is below minimum required
const EInvalidLiveness: u64 = 0;
/// Thrown when publisher is not from this module
const EInvalidPublisher: u64 = 1;
/// Thrown when fee factor is zero or exceeds maximum basis points
const EInvalidFeeFactor: u64 = 2;
/// Thrown when coin type is not supported or resolution fee not set
const EUnsupportedCoinType: u64 = 3;

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

    let mut protocol = Protocol {
        id: object::new(ctx),
        resolution_fees: table::new(ctx),
        supported_topics: table::new(ctx),
        fee_factor_bps: default_fee_factor!(),
        supported_coin_types: table::new(ctx),
        default_liveness_ms: min_liveness_ms!(),
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
    protocol.default_liveness_ms = liveness_ms;
}

/// Sets the fee factor in basis points for bond calculation. Lower values
/// require higher bonds relative to resolution fees. Used in formula:
/// minimum_bond = (resolution_fee * 10000) / fee_factor_bps
///
/// @param protocol Protocol object
/// @param _cap ProtocolCap for authorization
/// @param fee_factor_bps Fee factor (1-10000 basis points, used in minimum bond calculation)
public fun set_fee_factor_bps(protocol: &mut Protocol, _: &ProtocolCap, fee_factor_bps: u64) {
    assert!(fee_factor_bps > 0 && fee_factor_bps <= bps!(), EInvalidFeeFactor);
    protocol.fee_factor_bps = fee_factor_bps;
}

/// Adds a topic to the list of supported query topics.
///
/// @param protocol Protocol object
/// @param _cap ProtocolCap for authorization
/// @param topic Topic identifier bytes to support
public fun add_supported_topic(protocol: &mut Protocol, _: &ProtocolCap, topic: vector<u8>) {
    protocol.supported_topics.add(topic, true);
}

/// Removes a topic from the list of supported query topics.
///
/// @param protocol Protocol object
/// @param _cap ProtocolCap for authorization
/// @param topic Topic identifier bytes to remove
public fun remove_supported_topic(protocol: &mut Protocol, _: &ProtocolCap, topic: vector<u8>) {
    protocol.supported_topics.remove(topic);
}

/// Adds a coin type to the list of supported currencies for bonds.
public fun add_supported_coin_type<T>(protocol: &mut Protocol, _: &ProtocolCap) {
    protocol.supported_coin_types.add(type_name::with_original_ids<T>(), true);
}

/// Removes a coin type from the list of supported currencies.
public fun remove_supported_coin_type<T>(protocol: &mut Protocol, _: &ProtocolCap) {
    protocol.supported_coin_types.remove(type_name::with_original_ids<T>());
}

/// Sets the resolution fee for a specific coin type.
/// This fee determines the minimum bond amount required.
public fun set_resolution_fee<T>(protocol: &mut Protocol, _: &ProtocolCap, fee: u64) {
    let coin_type = type_name::with_original_ids<T>();
    assert!(protocol.supported_coin_types.contains(coin_type), EUnsupportedCoinType);

    if (protocol.resolution_fees.contains(coin_type)) {
        protocol.resolution_fees.remove(coin_type);
    };

    protocol.resolution_fees.add(coin_type, fee);
}

/// Removes the resolution fee for a specific coin type.
public fun remove_resolution_fee<T>(protocol: &mut Protocol, _: &ProtocolCap) {
    let coin_type = type_name::with_original_ids<T>();

    assert!(protocol.resolution_fees.contains(coin_type), EUnsupportedCoinType);
    protocol.resolution_fees.remove(coin_type);
}

/// Returns the resolution fee for a specific coin type.
///
/// @param protocol Protocol object
///
/// @return Resolution fee amount
public fun resolution_fee<T>(protocol: &Protocol): u64 {
    let coin_type = type_name::with_original_ids<T>();

    assert!(protocol.resolution_fees.contains(coin_type), EUnsupportedCoinType);
    protocol.resolution_fees[coin_type]
}

/// Checks if a coin type is supported for bonds.
///
/// @param protocol Protocol to check
///
/// @return true if coin type is supported
public fun is_coin_type_supported<T>(protocol: &Protocol): bool {
    protocol.supported_coin_types.contains(type_name::with_original_ids<T>())
}

/// Checks if a topic is supported for queries.
///
/// @param protocol Protocol to check
/// @param topic Topic identifier bytes
///
/// @return true if topic is supported
public fun is_topic_supported(protocol: &Protocol, topic: vector<u8>): bool {
    protocol.supported_topics.contains(topic)
}

/// Returns the default liveness period in milliseconds.
///
/// @param protocol Protocol object
///
/// @return Default liveness period in milliseconds
public fun default_liveness_ms(protocol: &Protocol): u64 {
    protocol.default_liveness_ms
}

/// Calculates the minimum bond amount for a coin type using the protocol's
/// fee factor and resolution fee. Higher fee factors result in lower bond requirements.
///
/// @param protocol Protocol object
///
/// @return Minimum bond amount using formula: (resolution_fee * 10000) / fee_factor_bps
public fun minimum_bond<T>(protocol: &Protocol): u64 {
    (
        (protocol.resolution_fees[type_name::with_original_ids<T>()] as u128) * (bps!() as u128) / (protocol.fee_factor_bps as u128),
    ) as u64
}

/// Returns the fee factor in basis points.
///
/// @param protocol Protocol object
///
/// @return Fee factor (1-10000 basis points)
public fun fee_factor_bps(protocol: &Protocol): u64 {
    protocol.fee_factor_bps
}

public macro fun min_liveness_ms(): u64 {
    5 * 60 * 1000
}

macro fun bps(): u64 {
    10_000
}

macro fun default_fee_factor(): u64 {
    5000
}
