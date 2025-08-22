/// This module manages the protocol level config for Reef.
///
/// Key responsibilities:
/// 1. Economic policy (burn rates, minimum bonds, fees)
/// 3. Content moderation (topic and coin type whitelists)
/// 4. Resolver management (which types can resolve disputes)
/// 5. Treasury management (collecting fees and burned bonds)
/// 2. Security policies (minimum challenge periods, submission delays)
///
/// The Protocol struct is shared globally so all queries can reference the same
/// config.
module reef::protocol;

use std::type_name::{Self, TypeName};
use sui::balance::Balance;
use sui::coin::Coin;
use sui::dynamic_field;
use sui::package::{Self, Publisher};
use sui::table::{Self, Table};
use sui::vec_map::{Self, VecMap};
use sui::vec_set::{Self, VecSet};

// ====== Error Codes =====

/// Publisher doesn't match the protocol module
const EInvalidPublisher: u64 = 0;
/// Trying to use a coin type that isn't whitelisted
const EBondTypeNotAllowed: u64 = 1;
const EInvalidBurnRate: u64 = 2;

// ===== Structs =====

/// One-time witness for protocol initialization
public struct PROTOCOL() has drop;

/// The main protocol config object.
///
/// This shared object contains all the global settings that govern how the oracle works.
public struct Protocol has key {
    id: UID,
    /// How much of losing bonds get burned (in basis points)
    burn_rate_bps: u64,
    /// Minimum time challengers have to challenge claims
    minimum_liveness_ms: u64,
    /// Which coin types can be used for bonds/fees
    allowed_coin_types: VecSet<TypeName>,
    /// Which topics are allowed for new queries
    allowed_topics: Table<vector<u8>, bool>,
    /// Protocol fees for creating queries
    fee_amounts: VecMap<TypeName, u64>,
    /// Minimum bond amounts for different coin types
    minimum_bond_map: VecMap<TypeName, u64>,
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
public fun initialize(publisher: Publisher, ctx: &mut TxContext): (Protocol, ProtocolCap) {
    assert!(publisher.from_module<PROTOCOL>(), EInvalidPublisher);

    let protocol = Protocol {
        id: object::new(ctx),
        fee_amounts: vec_map::empty(),
        allowed_topics: table::new(ctx),
        minimum_bond_map: vec_map::empty(),
        burn_rate_bps: default_burn_rate!(),
        allowed_coin_types: vec_set::empty(),
        minimum_liveness_ms: default_minimum_liveness_ms!()
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

public fun set_minimum_bond(
    protocol: &mut Protocol,
    _: &ProtocolCap,
    coin_type: TypeName,
    minimum_bond: u64,
) {
    assert!(protocol.is_allowed_coin_type(coin_type), EBondTypeNotAllowed);

    if (!protocol.minimum_bond_map.contains(&coin_type)) {
        protocol.minimum_bond_map.insert(coin_type, minimum_bond);
    } else {
        let current_minimum = &mut protocol.minimum_bond_map[&coin_type];
        *current_minimum = minimum_bond;
    }
}

public fun set_fee_amount(
    protocol: &mut Protocol,
    _: &ProtocolCap,
    fee_type: TypeName,
    fee_amount: u64,
) {
    if (!protocol.fee_amounts.contains(&fee_type)) {
        protocol.fee_amounts.insert(fee_type, fee_amount);
    } else {
        let current_minimum = &mut protocol.fee_amounts[&fee_type];
        *current_minimum = fee_amount;
    }
}

public fun set_minimum_liveness(
    protocol: &mut Protocol,
    _: &ProtocolCap,
    minimum_liveness_ms: u64,
) {
    protocol.minimum_liveness_ms = minimum_liveness_ms;
}

public fun set_burn_rate(protocol: &mut Protocol, _: &ProtocolCap, burn_rate_bps: u64) {
    assert!(burn_rate_bps <= 10000, EInvalidBurnRate); // Max 100%
    protocol.burn_rate_bps = burn_rate_bps;
}

/// Collects protocol fees from query creation.
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

/// Collects burned bonds from challenge resolutions.
public(package) fun collect_burned_bond<CoinType>(protocol: &mut Protocol, bond: Coin<CoinType>) {
    // Burned bonds go to the treasury too
    protocol.collect_fee(bond)
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
    protocol.minimum_bond_map[&coin_type]
}

public fun fee_amount(protocol: &Protocol, coin_type: TypeName): u64 {
    protocol.fee_amounts[&coin_type]
}

public fun minimum_liveness_ms(protocol: &Protocol): u64 {
    protocol.minimum_liveness_ms
}

public fun burn_rate_bps(protocol: &Protocol): u64 {
    protocol.burn_rate_bps
}

// ===== Macros =====

/// 50% burn rate on disputes
macro public fun default_burn_rate(): u64 {
    5_000
}

/// 20 hours minimum for challenges
macro public fun default_minimum_liveness_ms(): u64 {
    72_000_00
}

/// 5 minutes before claims can be submitted
macro public fun default_minimum_submission_delay_ms(): u64 {
    3_000_00
}

// ===== Test Only functions =====

#[test_only]
public fun initialize_for_testing(ctx: &mut TxContext): (Protocol, ProtocolCap) {
    let publisher = package::test_claim(PROTOCOL(), ctx);
    initialize(publisher, ctx)
}

