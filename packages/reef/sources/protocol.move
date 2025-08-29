/// This module manages the protocol level config for Reef.
///
/// Key responsibilities:
/// 1. Economic policy (fee factor, resolution fees, minimum bonds)
/// 2. Content moderation (topic and coin type whitelists)
/// 3. Resolver management (which types can resolve disputes)
/// 4. Treasury management (collecting fees)
/// 5. Security policies (minimum challenge periods)
///
/// The Protocol struct is shared globally so all queries can reference the same
/// config.
module reef::protocol;

use reef::epoch::{Self, EpochManager};
use std::type_name::{Self, TypeName};
use sui::balance::Balance;
use sui::clock::Clock;
use sui::coin::Coin;
use sui::dynamic_field;
use sui::package::{Self, Publisher};
use sui::table::{Self, Table};
use sui::vec_set::{Self, VecSet};

// ====== Error Codes =====

/// Publisher doesn't match the protocol module
const EInvalidPublisher: u64 = 0;
const EInvalidFeeFactor: u64 = 2;

// ===== Structs =====

/// One-time witness for protocol initialization
public struct PROTOCOL() has drop;

/// The main protocol config object.
///
/// This shared object contains all the global settings that govern how the oracle works.
public struct Protocol has key {
    id: UID,
    fee_factor_bps: u64,
    /// Minimum time challengers have to challenge claims
    minimum_liveness_ms: u64,
    /// Which coin types can be used for bonds/fees
    allowed_coin_types: VecSet<TypeName>,
    /// Which topics are allowed for new queries
    allowed_topics: Table<vector<u8>, bool>,
    /// Fee amounts for resolution in different coin types
    resolution_fees: Table<TypeName, u64>,
    /// Global epoch management system
    epoch_manager: EpochManager,
}

/// Admin cap for protocol governance.
public struct ProtocolCap has key {
    id: UID,
}

/// Key for storing collected fees in dynamic fields
public struct FeeKey(TypeName) has copy, drop, store;

fun init(otw: PROTOCOL, ctx: &mut TxContext) {
    package::claim_and_keep(otw, ctx);
}

/// Initializes the protocol.
///
/// This creates the Protocol object with the defaults and protocol cap.
/// The publisher ensures this can only be called by initialized once as it is deleted during the initialization process.
public fun initialize(
    publisher: Publisher,
    clock: &Clock,
    ctx: &mut TxContext,
): (Protocol, ProtocolCap) {
    assert!(publisher.from_module<PROTOCOL>(), EInvalidPublisher);

    let protocol = Protocol {
        id: object::new(ctx),
        allowed_topics: table::new(ctx),
        resolution_fees: table::new(ctx),
        fee_factor_bps: default_fee_factor!(),
        allowed_coin_types: vec_set::empty(),
        minimum_liveness_ms: default_minimum_liveness_ms!(),
        epoch_manager: epoch::new_epoch_manager(option::none(), clock, ctx),
    };

    publisher.burn();
    (protocol, ProtocolCap { id: object::new(ctx) })
}

public fun share_protocol(protocol: Protocol) {
    transfer::share_object(protocol)
}

public fun transfer_protocol_cap(cap: ProtocolCap, recipient: address) {
    transfer::transfer(cap, recipient)
}

public fun set_resolution_fee(
    protocol: &mut Protocol,
    _: &ProtocolCap,
    fee_type: TypeName,
    fee_amount: u64,
) {
    if (!protocol.resolution_fees.contains(fee_type)) {
        protocol.resolution_fees.add(fee_type, fee_amount);
    } else {
        *(&mut protocol.resolution_fees[fee_type]) = fee_amount;
    }
}

public fun set_minimum_liveness(
    protocol: &mut Protocol,
    _: &ProtocolCap,
    minimum_liveness_ms: u64,
) {
    protocol.minimum_liveness_ms = minimum_liveness_ms;
}

public fun set_fee_factor(protocol: &mut Protocol, _: &ProtocolCap, fee_factor_bps: u64) {
    assert!(fee_factor_bps <= bps!(), EInvalidFeeFactor);
    protocol.fee_factor_bps = fee_factor_bps;
}

/// Collects protocol fees.
public(package) fun collect_fee<CoinType>(protocol: &mut Protocol, fee: Coin<CoinType>) {
    let fee_key = FeeKey(type_name::get<CoinType>());
    if (!dynamic_field::exists_(&protocol.id, fee_key)) {
        dynamic_field::add(&mut protocol.id, fee_key, fee.into_balance());
    } else {
        let fee_balance = dynamic_field::borrow_mut<FeeKey, Balance<CoinType>>(
            &mut protocol.id,
            fee_key,
        );

        fee_balance.join(fee.into_balance());
    }
}

/// Adds a new allowed reward type to the protocol.
public fun add_allowed_coin_type(protocol: &mut Protocol, _: &ProtocolCap, reward_type: TypeName) {
    protocol.allowed_coin_types.insert(reward_type);
}

/// Adds a topic to the allowed list.
public fun add_allowed_topic(protocol: &mut Protocol, _: &ProtocolCap, topic: vector<u8>) {
    protocol.allowed_topics.add(topic, true);
}

/// Removes a topic from the allowed list.
public fun remove_allowed_topic(protocol: &mut Protocol, _: &ProtocolCap, topic: vector<u8>) {
    protocol.allowed_topics.remove(topic);
}

/// Removes an allowed reward type from the protocol.
public fun remove_allowed_coin_type(
    protocol: &mut Protocol,
    _: &ProtocolCap,
    reward_type: TypeName,
) {
    protocol.allowed_coin_types.remove(&reward_type);
}

// === View Functions ===

public fun is_allowed_coin_type(protocol: &Protocol, reward_type: TypeName): bool {
    protocol.allowed_coin_types.contains(&reward_type)
}

public fun is_topic_allowed(protocol: &Protocol, topic: &vector<u8>): bool {
    protocol.allowed_topics.contains(*topic)
}

public fun minimum_bond(protocol: &Protocol, coin_type: TypeName): u64 {
    let fee_amount = protocol.resolution_fees[coin_type];
    ((fee_amount as u128) * (bps!() as u128) / (protocol.fee_factor_bps as u128)) as u64
}

public fun resolution_fee(protocol: &Protocol, coin_type: TypeName): u64 {
    protocol.resolution_fees[coin_type]
}

public fun minimum_liveness_ms(protocol: &Protocol): u64 {
    protocol.minimum_liveness_ms
}

public fun fee_factor_bps(protocol: &Protocol): u64 {
    protocol.fee_factor_bps
}

public fun epoch_manager(protocol: &Protocol): &EpochManager {
    &protocol.epoch_manager
}


// ===== Macros =====

/// Basis points in 100%
public macro fun bps(): u64 {
    10_000
}

/// 50% fee factor for calculating minimum bonds from resolution fees
public macro fun default_fee_factor(): u64 {
    5_000
}

/// 20 hours minimum for challenges
public macro fun default_minimum_liveness_ms(): u64 {
    72_000_00
}

// ===== Test Only functions =====

#[test_only]
public fun initialize_for_testing(clock: &Clock, ctx: &mut TxContext): (Protocol, ProtocolCap) {
    let publisher = package::test_claim(PROTOCOL(), ctx);
    initialize(publisher, clock, ctx)
}
