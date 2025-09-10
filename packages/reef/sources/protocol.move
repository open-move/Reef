module reef::protocol;

use std::type_name::{Self, TypeName};
use sui::package::{Self, Publisher};
use sui::table::{Self, Table};

public struct PROTOCOL() has drop;

public struct Protocol has key, store {
    id: UID,
    fee_factor_bps: u64,
    default_liveness_ms: u64,
    supported_topics: Table<vector<u8>, bool>,
    supported_coin_types: Table<TypeName, bool>,
}

public struct ProtocolCap has key {
    id: UID,
}

const EInvalidPublisher: u64 = 0;
const EInvalidLiveness: u64 = 1;
const EInvalidFeeFactor: u64 = 2;

fun init(otw: PROTOCOL, ctx: &mut TxContext) {
    package::claim_and_keep(otw, ctx);
}

public fun create(publisher: Publisher, ctx: &mut TxContext): (Protocol, ProtocolCap) {
    assert!(publisher.from_module<PROTOCOL>(), EInvalidPublisher);

    let protocol = Protocol {
        id: object::new(ctx),
        supported_topics: table::new(ctx),
        fee_factor_bps: default_fee_factor!(),
        supported_coin_types: table::new(ctx),
        default_liveness_ms: min_liveness_ms!(),
    };

    publisher.burn();
    (protocol, ProtocolCap { id: object::new(ctx) })
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

public fun is_coin_type_supported<T>(protocol: &Protocol): bool {
    protocol.supported_coin_types.contains(type_name::with_original_ids<T>())
}

public fun is_topic_supported(protocol: &Protocol, topic: vector<u8>): bool {
    protocol.supported_topics.contains(topic)
}

public fun default_liveness_ms(protocol: &Protocol): u64 {
    protocol.default_liveness_ms
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
