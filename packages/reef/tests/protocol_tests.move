#[test_only]
module reef::protocol_tests;

use reef::protocol::{Self, Protocol, ProtocolCap};
use sui::package::Publisher;
use sui::test_scenario::{Self, Scenario};
use sui::test_utils;
use reef::macros;

public struct DummyCoin() has drop;

public fun setup_protocol(scenario: &mut Scenario): (Protocol, ProtocolCap) {
    protocol::init_for_testing(scenario.ctx());

    let sender = scenario.sender();
    scenario.next_tx(sender);

    let publisher = scenario.take_from_sender<Publisher>();
    protocol::initialize(publisher, scenario.ctx())
}

#[test]
fun test_set_custom_liveness() {
    let mut scenario = test_scenario::begin(sender!());
    let (mut protocol, protocol_cap) = setup_protocol(&mut scenario);

    protocol.set_default_liveness_ms(&protocol_cap, custom_liveness!());
    assert!(protocol.default_liveness_ms() == custom_liveness!());
    cleanup(protocol, protocol_cap, scenario)
}

#[test]
fun test_set_custom_fee_factor() {
    let mut scenario = test_scenario::begin(sender!());
    let (mut protocol, protocol_cap) = setup_protocol(&mut scenario);

    protocol.set_fee_factor_bps(&protocol_cap, custom_fee_factor!());
    assert!(protocol.fee_factor_bps() == custom_fee_factor!());
    cleanup(protocol, protocol_cap, scenario)
}

#[test]
fun test_add_supported_topic() {
    let mut scenario = test_scenario::begin(sender!());
    let (mut protocol, protocol_cap) = setup_protocol(&mut scenario);

    let topic = b"ETH_USDC";
    protocol.add_supported_topic(&protocol_cap, topic);
    assert!(protocol.is_topic_supported(topic));
    cleanup(protocol, protocol_cap, scenario)
}

#[test]
fun test_add_supported_coin_type() {
    let mut scenario = test_scenario::begin(sender!());
    let (mut protocol, protocol_cap) = setup_protocol(&mut scenario);

    protocol.add_supported_coin_type<DummyCoin>(&protocol_cap);
    assert!(protocol.is_coin_type_supported<DummyCoin>());
    cleanup(protocol, protocol_cap, scenario)
}

#[test]
fun test_set_resolver_fee() {
    let mut scenario = test_scenario::begin(sender!());
    let (mut protocol, protocol_cap) = setup_protocol(&mut scenario);

    protocol.add_supported_coin_type<DummyCoin>(&protocol_cap);
    protocol.set_resolver_fee<DummyCoin>(&protocol_cap, resolver_fee!());
    assert!(protocol.resolver_fee<DummyCoin>() == resolver_fee!());
    cleanup(protocol, protocol_cap, scenario)
}

#[test]
fun test_minimum_bond() {
    let mut scenario = test_scenario::begin(sender!());
    let (mut protocol, protocol_cap) = setup_protocol(&mut scenario);

    protocol.add_supported_coin_type<DummyCoin>(&protocol_cap);
    protocol.set_resolver_fee<DummyCoin>(&protocol_cap, resolver_fee!());

    let expected_bond = (resolver_fee!() * macros::bps!()) / protocol.fee_factor_bps();
    assert!(protocol.minimum_bond_amount<DummyCoin>() == expected_bond);
    cleanup(protocol, protocol_cap, scenario)
}

fun cleanup(protocol: Protocol, protocol_cap: ProtocolCap, scenario: Scenario) {
    test_utils::destroy(protocol);
    test_utils::destroy(protocol_cap);
    scenario.end();
}

macro fun resolver_fee(): u64 {
    600
}

macro fun custom_fee_factor(): u64 {
    4_000
}

macro fun custom_liveness(): u64 {
    12 * 60 * 1_000
}

macro fun sender(): address {
    @0xBaBe
}
