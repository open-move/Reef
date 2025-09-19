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

const EInvalidLiveness: u64 = 0;
const EInvalidPublisher: u64 = 1;
const EInvalidFeeFactor: u64 = 2;
const EUnsupportedCoinType: u64 = 3;

fun init(otw: PROTOCOL, ctx: &mut TxContext) {
    package::claim_and_keep(otw, ctx);
}

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

public fun transfer_cap(cap: ProtocolCap, recipient: address) {
    transfer::transfer(cap, recipient)
}

public fun set_default_liveness_ms(protocol: &mut Protocol, _: &ProtocolCap, liveness_ms: u64) {
    assert!(liveness_ms > min_liveness_ms!(), EInvalidLiveness);
    protocol.default_liveness_ms = liveness_ms;
}

public fun set_fee_factor_bps(protocol: &mut Protocol, _: &ProtocolCap, fee_factor_bps: u64) {
    assert!(fee_factor_bps <= bps!(), EInvalidFeeFactor);
    protocol.fee_factor_bps = fee_factor_bps;
}

public fun add_supported_topic(protocol: &mut Protocol, _: &ProtocolCap, topic: vector<u8>) {
    protocol.supported_topics.add(topic, true);
}

public fun remove_supported_topic(protocol: &mut Protocol, _: &ProtocolCap, topic: vector<u8>) {
    protocol.supported_topics.remove(topic);
}

public fun add_supported_coin_type<T>(protocol: &mut Protocol, _: &ProtocolCap) {
    protocol.supported_coin_types.add(type_name::with_original_ids<T>(), true);
}

public fun remove_supported_coin_type<T>(protocol: &mut Protocol, _: &ProtocolCap) {
    protocol.supported_coin_types.remove(type_name::with_original_ids<T>());
}

public fun set_resolution_fee<T>(protocol: &mut Protocol, _: &ProtocolCap, fee: u64) {
    let coin_type = type_name::with_original_ids<T>();
    assert!(protocol.supported_coin_types.contains(coin_type), EUnsupportedCoinType);

    if (protocol.resolution_fees.contains(coin_type)) {
        protocol.resolution_fees.remove(coin_type);
    };

    protocol.resolution_fees.add(coin_type, fee);
}

public fun remove_resolution_fee<T>(protocol: &mut Protocol, _: &ProtocolCap) {
    let coin_type = type_name::with_original_ids<T>();

    assert!(protocol.resolution_fees.contains(coin_type), EUnsupportedCoinType);
    protocol.resolution_fees.remove(coin_type);
}

public fun resolution_fee<T>(protocol: &Protocol): u64 {
    let coin_type = type_name::with_original_ids<T>();

    assert!(protocol.resolution_fees.contains(coin_type), 0);
    protocol.resolution_fees[coin_type]
}

public fun is_coin_type_supported<T>(protocol: &Protocol): bool {
    protocol.supported_coin_types.contains(type_name::with_original_ids<T>())
}

public fun is_topic_supported(protocol: &Protocol, topic: vector<u8>): bool {
    protocol.supported_topics.contains(topic)
}

public fun default_liveness_ms(protocol: &Protocol): u64 {
    protocol.default_liveness_ms
}

public fun minimum_bond<T>(protocol: &Protocol): u64 {
    (
        (protocol.resolution_fees[type_name::with_original_ids<T>()] as u128) * (bps!() as u128) / (protocol.fee_factor_bps as u128),
    ) as u64
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
