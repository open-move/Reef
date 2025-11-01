#[test_only]
module reef::resolver_tests;

use reef::protocol::{Protocol, ProtocolCap};
use reef::protocol_tests;
use reef::resolver::{Self, Resolver, ResolverCap};
use sui::balance;
use sui::clock;
use sui::package;
use sui::test_scenario::{Self, Scenario};
use sui::test_utils;

// ====== Test types ======

public struct TestCoin() has drop;
public struct ResolverWitness() has drop;
public struct WrongWitness() has drop;

// ====== Helper functions ======

/// Creates a protocol with test setup
fun setup_protocol(scenario: &mut Scenario): (Protocol, ProtocolCap) {
    protocol_tests::setup_protocol(scenario)
}

/// Creates a resolver with ResolverWitness
public fun setup_resolver(scenario: &mut Scenario): (Resolver, ResolverCap) {
    let publisher = package::test_claim(ResolverWitness(), scenario.ctx());
    
    let (resolver, resolver_cap) = resolver::create(
        ResolverWitness(),
        publisher,
        scenario.ctx(),
    );
    
    (resolver, resolver_cap)
}

/// Creates a resolver with WrongWitness for error testing
fun setup_wrong_resolver(scenario: &mut Scenario): (Resolver, ResolverCap) {
    let publisher = package::test_claim(WrongWitness(), scenario.ctx());
    
    let (resolver, resolver_cap) = resolver::create(
        WrongWitness(),
        publisher,
        scenario.ctx(),
    );
    
    (resolver, resolver_cap)
}

// Helper function removed as it's not used in these tests

// ====== Basic Functionality Tests ======

#[test]
fun create_resolver_basic() {
    let mut scenario = test_scenario::begin(sender!());
    let (resolver, resolver_cap) = setup_resolver(&mut scenario);
    
    // Verify resolver starts disabled
    assert!(!resolver.is_enabled());
    
    // Verify IDs match
    assert!(resolver.id() == resolver::cap_resolver_id(&resolver_cap));
    
    test_utils::destroy(resolver);
    test_utils::destroy(resolver_cap);
    scenario.end();
}

#[test]
fun enable_resolver() {
    let mut scenario = test_scenario::begin(sender!());
    let (protocol, protocol_cap) = setup_protocol(&mut scenario);
    let (mut resolver, resolver_cap) = setup_resolver(&mut scenario);
    
    // Initially disabled
    assert!(!resolver.is_enabled());
    
    // Enable resolver
    resolver.enable(&protocol_cap);
    assert!(resolver.is_enabled());
    
    test_utils::destroy(resolver);
    test_utils::destroy(resolver_cap);
    test_utils::destroy(protocol);
    test_utils::destroy(protocol_cap);
    scenario.end();
}

#[test]
fun disable_resolver() {
    let mut scenario = test_scenario::begin(sender!());
    let (protocol, protocol_cap) = setup_protocol(&mut scenario);
    let (mut resolver, resolver_cap) = setup_resolver(&mut scenario);
    
    // Enable first
    resolver.enable(&protocol_cap);
    assert!(resolver.is_enabled());
    
    // Then disable
    resolver.disable(&protocol_cap);
    assert!(!resolver.is_enabled());
    
    test_utils::destroy(resolver);
    test_utils::destroy(resolver_cap);
    test_utils::destroy(protocol);
    test_utils::destroy(protocol_cap);
    scenario.end();
}

#[test]
fun make_resolution_basic() {
    let mut scenario = test_scenario::begin(sender!());
    let (protocol, protocol_cap) = setup_protocol(&mut scenario);
    let (mut resolver, resolver_cap) = setup_resolver(&mut scenario);
    
    // Enable resolver
    resolver.enable(&protocol_cap);
    
    let clock = clock::create_for_testing(scenario.ctx());
    let query_id = object::id_from_address(@0x123);
    let data = b"resolution data";
    
    let resolution = resolver::make_resolution(
        &resolver,
        &resolver_cap,
        query_id,
        data,
        &clock,
    );
    
    // Verify resolution data
    assert!(resolution.query_id() == query_id);
    assert!(resolution.data() == data);
    assert!(resolution.resolver_id() == resolver.id());
    assert!(resolution.resolved_at_ms() == clock.timestamp_ms());
    
    test_utils::destroy(resolution);
    test_utils::destroy(resolver);
    test_utils::destroy(resolver_cap);
    test_utils::destroy(protocol);
    test_utils::destroy(protocol_cap);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun share_resolver() {
    let mut scenario = test_scenario::begin(sender!());
    let (resolver, resolver_cap) = setup_resolver(&mut scenario);
    
    // Share the resolver (this consumes it)
    resolver::share(resolver);
    
    test_utils::destroy(resolver_cap);
    scenario.end();
}

#[test]
fun unpack_dispute_ticket_basic() {
    let mut scenario = test_scenario::begin(sender!());
    let (resolver, resolver_cap) = setup_resolver(&mut scenario);
    
    // Create a dispute ticket with matching resolver ID
    let fee_balance = balance::create_for_testing<TestCoin>(100);
    let ticket = resolver::new_dispute_ticket<TestCoin>(
        object::id_from_address(@0x1234), // query_id
        resolver.id(), // Use actual resolver ID
        fee_balance,
        @0xD15,
        1000, // disputed_at_ms
        500,  // verification_bond_amount
    );
    
    // Unpack the ticket
    let (query_id, resolver_id, fee, disputer, disputed_at_ms, verification_bond_amount) = 
        ticket.unpack(&resolver_cap);
    
    // Verify unpacked data
    assert!(query_id == object::id_from_address(@0x1234));
    assert!(resolver_id == resolver.id());
    assert!(fee.value() == 100);
    assert!(disputer == @0xD15);
    assert!(disputed_at_ms == 1000);
    assert!(verification_bond_amount == 500);
    
    fee.destroy_for_testing();
    test_utils::destroy(resolver);
    test_utils::destroy(resolver_cap);
    scenario.end();
}

// ====== Error Tests ======

// Note: EInvalidPublisher test removed - cannot test cross-module publisher validation 
// within a single test module since both witness types originate from the same module

#[test]
#[expected_failure(abort_code = resolver::EResolverDisabled)]
fun make_resolution_fails_disabled_resolver() {
    let mut scenario = test_scenario::begin(sender!());
    let (resolver, resolver_cap) = setup_resolver(&mut scenario);
    
    // Don't enable the resolver - it should be disabled by default
    assert!(!resolver.is_enabled());
    
    let clock = clock::create_for_testing(scenario.ctx());
    
    // Try to make resolution with disabled resolver - should fail
    let resolution = resolver::make_resolution(
        &resolver,
        &resolver_cap,
        object::id_from_address(@0x123),
        b"resolution data",
        &clock,
    );
    
    test_utils::destroy(resolution);
    test_utils::destroy(resolver);
    test_utils::destroy(resolver_cap);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = resolver::EInvalidResolverCap)]
fun make_resolution_fails_wrong_cap() {
    let mut scenario = test_scenario::begin(sender!());
    let (protocol, protocol_cap) = setup_protocol(&mut scenario);
    let (mut resolver1, resolver_cap1) = setup_resolver(&mut scenario);
    let (mut resolver2, resolver_cap2) = setup_wrong_resolver(&mut scenario);
    
    // Enable both resolvers
    resolver1.enable(&protocol_cap);
    resolver2.enable(&protocol_cap);
    
    let clock = clock::create_for_testing(scenario.ctx());
    
    // Try to use resolver1 with resolver2's cap - should fail
    let resolution = resolver::make_resolution(
        &resolver1,
        &resolver_cap2, // Wrong cap!
        object::id_from_address(@0x123),
        b"resolution data",
        &clock,
    );
    
    test_utils::destroy(resolution);
    test_utils::destroy(resolver1);
    test_utils::destroy(resolver_cap1);
    test_utils::destroy(resolver2);
    test_utils::destroy(resolver_cap2);
    test_utils::destroy(protocol);
    test_utils::destroy(protocol_cap);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = resolver::EInvalidResolverCap)]
fun unpack_dispute_ticket_fails_wrong_cap() {
    let mut scenario = test_scenario::begin(sender!());
    let (resolver1, resolver_cap1) = setup_resolver(&mut scenario);
    let (resolver2, resolver_cap2) = setup_wrong_resolver(&mut scenario);
    
    // Create ticket for resolver1
    let fee_balance = balance::create_for_testing<TestCoin>(100);
    let ticket = resolver::new_dispute_ticket<TestCoin>(
        object::id_from_address(@0x1234),
        resolver1.id(), // Ticket for resolver1
        fee_balance,
        @0xD15,
        1000,
        500,
    );
    
    // Try to unpack with resolver2's cap - should fail
    let (_query_id, _resolver_id, fee, _disputer, _disputed_at_ms, _verification_bond_amount) = 
        ticket.unpack(&resolver_cap2); // Wrong cap!
    
    fee.destroy_for_testing();
    test_utils::destroy(resolver1);
    test_utils::destroy(resolver_cap1);
    test_utils::destroy(resolver2);
    test_utils::destroy(resolver_cap2);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = resolver::EInvalidResolverCap)]
fun make_resolution_fails_wrong_resolver_cap() {
    let mut scenario = test_scenario::begin(sender!());
    let (protocol, protocol_cap) = setup_protocol(&mut scenario);
    let (mut resolver, _resolver_cap) = setup_resolver(&mut scenario);
    let (_wrong_resolver, wrong_cap) = setup_wrong_resolver(&mut scenario);
    
    // Enable resolver
    resolver.enable(&protocol_cap);
    
    let clock = clock::create_for_testing(scenario.ctx());
    
    // Try to make resolution with cap from different resolver
    let resolution = resolver::make_resolution(
        &resolver,
        &wrong_cap, // Cap from different resolver
        object::id_from_address(@0x123),
        b"resolution data",
        &clock,
    );
    
    test_utils::destroy(resolution);
    test_utils::destroy(resolver);
    test_utils::destroy(_resolver_cap);
    test_utils::destroy(_wrong_resolver);
    test_utils::destroy(wrong_cap);
    test_utils::destroy(protocol);
    test_utils::destroy(protocol_cap);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = resolver::EInvalidResolverCap)]
fun unpack_ticket_fails_wrong_resolver_id() {
    let mut scenario = test_scenario::begin(sender!());
    let (resolver, resolver_cap) = setup_resolver(&mut scenario);
    
    // Create ticket for different resolver ID
    let fee_balance = balance::create_for_testing<TestCoin>(100);
    let ticket = resolver::new_dispute_ticket<TestCoin>(
        object::id_from_address(@0x1234),
        object::id_from_address(@0xDFF), // Different resolver ID
        fee_balance,
        @0xD15,
        1000,
        500,
    );
    
    // Try to unpack with resolver's cap - should fail because IDs don't match
    let (_query_id, _resolver_id, fee, _disputer, _disputed_at_ms, _verification_bond_amount) = 
        ticket.unpack(&resolver_cap);
    
    fee.destroy_for_testing();
    test_utils::destroy(resolver);
    test_utils::destroy(resolver_cap);
    scenario.end();
}

// ====== State Transition Tests ======

#[test]
fun resolver_starts_disabled() {
    let mut scenario = test_scenario::begin(sender!());
    let (resolver, resolver_cap) = setup_resolver(&mut scenario);
    
    // Verify resolver starts in disabled state
    assert!(!resolver.is_enabled());
    
    test_utils::destroy(resolver);
    test_utils::destroy(resolver_cap);
    scenario.end();
}

#[test]
fun enable_disable_cycle() {
    let mut scenario = test_scenario::begin(sender!());
    let (protocol, protocol_cap) = setup_protocol(&mut scenario);
    let (mut resolver, resolver_cap) = setup_resolver(&mut scenario);
    
    // Initially disabled
    assert!(!resolver.is_enabled());
    
    // Enable
    resolver.enable(&protocol_cap);
    assert!(resolver.is_enabled());
    
    // Disable
    resolver.disable(&protocol_cap);
    assert!(!resolver.is_enabled());
    
    // Enable again
    resolver.enable(&protocol_cap);
    assert!(resolver.is_enabled());
    
    test_utils::destroy(resolver);
    test_utils::destroy(resolver_cap);
    test_utils::destroy(protocol);
    test_utils::destroy(protocol_cap);
    scenario.end();
}

#[test]
fun multiple_enable_calls() {
    let mut scenario = test_scenario::begin(sender!());
    let (protocol, protocol_cap) = setup_protocol(&mut scenario);
    let (mut resolver, resolver_cap) = setup_resolver(&mut scenario);
    
    // Enable multiple times
    resolver.enable(&protocol_cap);
    assert!(resolver.is_enabled());
    
    resolver.enable(&protocol_cap);
    assert!(resolver.is_enabled()); // Still enabled
    
    resolver.enable(&protocol_cap);
    assert!(resolver.is_enabled()); // Still enabled
    
    test_utils::destroy(resolver);
    test_utils::destroy(resolver_cap);
    test_utils::destroy(protocol);
    test_utils::destroy(protocol_cap);
    scenario.end();
}

#[test]
fun multiple_disable_calls() {
    let mut scenario = test_scenario::begin(sender!());
    let (protocol, protocol_cap) = setup_protocol(&mut scenario);
    let (mut resolver, resolver_cap) = setup_resolver(&mut scenario);
    
    // Initially disabled
    assert!(!resolver.is_enabled());
    
    // Disable multiple times
    resolver.disable(&protocol_cap);
    assert!(!resolver.is_enabled()); // Still disabled
    
    resolver.disable(&protocol_cap);
    assert!(!resolver.is_enabled()); // Still disabled
    
    // Enable then disable multiple times
    resolver.enable(&protocol_cap);
    assert!(resolver.is_enabled());
    
    resolver.disable(&protocol_cap);
    assert!(!resolver.is_enabled());
    
    resolver.disable(&protocol_cap);
    assert!(!resolver.is_enabled()); // Still disabled
    
    test_utils::destroy(resolver);
    test_utils::destroy(resolver_cap);
    test_utils::destroy(protocol);
    test_utils::destroy(protocol_cap);
    scenario.end();
}

// ====== Resolution Data Tests ======

#[test]
fun resolution_data_integrity() {
    let mut scenario = test_scenario::begin(sender!());
    let (protocol, protocol_cap) = setup_protocol(&mut scenario);
    let (mut resolver, resolver_cap) = setup_resolver(&mut scenario);
    
    resolver.enable(&protocol_cap);
    
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.increment_for_testing(5000); // Set specific timestamp
    
    let query_id = object::id_from_address(@0x12345);
    let data = b"comprehensive resolution data";
    let expected_timestamp = clock.timestamp_ms();
    
    let resolution = resolver::make_resolution(
        &resolver,
        &resolver_cap,
        query_id,
        data,
        &clock,
    );
    
    // Verify all fields
    assert!(resolution.query_id() == query_id);
    assert!(resolution.data() == data);
    assert!(resolution.resolver_id() == resolver.id());
    assert!(resolution.resolved_at_ms() == expected_timestamp);
    
    test_utils::destroy(resolution);
    test_utils::destroy(resolver);
    test_utils::destroy(resolver_cap);
    test_utils::destroy(protocol);
    test_utils::destroy(protocol_cap);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun resolution_timestamp_accuracy() {
    let mut scenario = test_scenario::begin(sender!());
    let (protocol, protocol_cap) = setup_protocol(&mut scenario);
    let (mut resolver, resolver_cap) = setup_resolver(&mut scenario);
    
    resolver.enable(&protocol_cap);
    
    let mut clock = clock::create_for_testing(scenario.ctx());
    
    // Test different timestamps
    let timestamps = vector[0, 1000, 5000, 1234567890];
    let mut i = 0;
    
    while (i < timestamps.length()) {
        let timestamp = timestamps[i];
        clock.increment_for_testing(timestamp);
        
        let resolution = resolver::make_resolution(
            &resolver,
            &resolver_cap,
            object::id_from_address(@0x123),
            b"data",
            &clock,
        );
        
        assert!(resolution.resolved_at_ms() == clock.timestamp_ms());
        test_utils::destroy(resolution);
        
        i = i + 1;
    };
    
    test_utils::destroy(resolver);
    test_utils::destroy(resolver_cap);
    test_utils::destroy(protocol);
    test_utils::destroy(protocol_cap);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun resolution_with_empty_data() {
    let mut scenario = test_scenario::begin(sender!());
    let (protocol, protocol_cap) = setup_protocol(&mut scenario);
    let (mut resolver, resolver_cap) = setup_resolver(&mut scenario);
    
    resolver.enable(&protocol_cap);
    
    let clock = clock::create_for_testing(scenario.ctx());
    let empty_data = vector::empty<u8>();
    
    let resolution = resolver::make_resolution(
        &resolver,
        &resolver_cap,
        object::id_from_address(@0x123),
        empty_data,
        &clock,
    );
    
    assert!(resolution.data() == empty_data);
    assert!(resolution.data().length() == 0);
    
    test_utils::destroy(resolution);
    test_utils::destroy(resolver);
    test_utils::destroy(resolver_cap);
    test_utils::destroy(protocol);
    test_utils::destroy(protocol_cap);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun resolution_with_large_data() {
    let mut scenario = test_scenario::begin(sender!());
    let (protocol, protocol_cap) = setup_protocol(&mut scenario);
    let (mut resolver, resolver_cap) = setup_resolver(&mut scenario);
    
    resolver.enable(&protocol_cap);
    
    let clock = clock::create_for_testing(scenario.ctx());
    
    // Create large data (1KB)
    let mut large_data = vector::empty<u8>();
    let mut i = 0;
    while (i < 1024) {
        large_data.push_back((i % 256) as u8);
        i = i + 1;
    };
    
    let resolution = resolver::make_resolution(
        &resolver,
        &resolver_cap,
        object::id_from_address(@0x123),
        large_data,
        &clock,
    );
    
    assert!(resolution.data().length() == 1024);
    assert!(resolution.data()[0] == 0);
    assert!(resolution.data()[255] == 255);
    assert!(resolution.data()[256] == 0); // Wraps around
    
    test_utils::destroy(resolution);
    test_utils::destroy(resolver);
    test_utils::destroy(resolver_cap);
    test_utils::destroy(protocol);
    test_utils::destroy(protocol_cap);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun multiple_resolutions_same_resolver() {
    let mut scenario = test_scenario::begin(sender!());
    let (protocol, protocol_cap) = setup_protocol(&mut scenario);
    let (mut resolver, resolver_cap) = setup_resolver(&mut scenario);
    
    resolver.enable(&protocol_cap);
    
    let clock = clock::create_for_testing(scenario.ctx());
    
    // Create multiple resolutions
    let resolution1 = resolver::make_resolution(
        &resolver,
        &resolver_cap,
        object::id_from_address(@0x1231),
        b"resolution 1",
        &clock,
    );
    
    let resolution2 = resolver::make_resolution(
        &resolver,
        &resolver_cap,
        object::id_from_address(@0x1232),
        b"resolution 2",
        &clock,
    );
    
    let resolution3 = resolver::make_resolution(
        &resolver,
        &resolver_cap,
        object::id_from_address(@0x1233),
        b"resolution 3",
        &clock,
    );
    
    // Verify each resolution is unique but from same resolver
    assert!(resolution1.query_id() != resolution2.query_id());
    assert!(resolution2.query_id() != resolution3.query_id());
    assert!(resolution1.resolver_id() == resolution2.resolver_id());
    assert!(resolution2.resolver_id() == resolution3.resolver_id());
    assert!(resolution1.resolver_id() == resolver.id());
    
    test_utils::destroy(resolution1);
    test_utils::destroy(resolution2);
    test_utils::destroy(resolution3);
    test_utils::destroy(resolver);
    test_utils::destroy(resolver_cap);
    test_utils::destroy(protocol);
    test_utils::destroy(protocol_cap);
    clock.destroy_for_testing();
    scenario.end();
}

// ====== View Function Tests ======

#[test]
fun test_all_resolver_view_functions() {
    let mut scenario = test_scenario::begin(sender!());
    let (protocol, protocol_cap) = setup_protocol(&mut scenario);
    let (mut resolver, resolver_cap) = setup_resolver(&mut scenario);
    
    // Test resolver view functions
    let resolver_id = resolver.id();
    assert!(resolver::cap_resolver_id(&resolver_cap) == resolver_id);
    assert!(!resolver.is_enabled()); // Initially disabled
    
    // Enable and test again
    resolver.enable(&protocol_cap);
    assert!(resolver.is_enabled());
    
    // Disable and test again
    resolver.disable(&protocol_cap);
    assert!(!resolver.is_enabled());
    
    test_utils::destroy(resolver);
    test_utils::destroy(resolver_cap);
    test_utils::destroy(protocol);
    test_utils::destroy(protocol_cap);
    scenario.end();
}

#[test]
fun test_resolution_view_functions() {
    let mut scenario = test_scenario::begin(sender!());
    let (protocol, protocol_cap) = setup_protocol(&mut scenario);
    let (mut resolver, resolver_cap) = setup_resolver(&mut scenario);
    
    resolver.enable(&protocol_cap);
    
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.increment_for_testing(12345);
    
    let query_id = object::id_from_address(@0x12346);
    let data = b"test resolution data";
    let expected_timestamp = clock.timestamp_ms();
    
    let resolution = resolver::make_resolution(
        &resolver,
        &resolver_cap,
        query_id,
        data,
        &clock,
    );
    
    // Test all resolution view functions
    assert!(resolution.query_id() == query_id);
    assert!(resolution.data() == data);
    assert!(resolution.resolver_id() == resolver.id());
    assert!(resolution.resolved_at_ms() == expected_timestamp);
    
    test_utils::destroy(resolution);
    test_utils::destroy(resolver);
    test_utils::destroy(resolver_cap);
    test_utils::destroy(protocol);
    test_utils::destroy(protocol_cap);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_resolver_cap_functions() {
    let mut scenario = test_scenario::begin(sender!());
    let (resolver1, resolver_cap1) = setup_resolver(&mut scenario);
    let (resolver2, resolver_cap2) = setup_wrong_resolver(&mut scenario);
    
    // Test cap functions
    assert!(resolver::cap_resolver_id(&resolver_cap1) == resolver1.id());
    assert!(resolver::cap_resolver_id(&resolver_cap2) == resolver2.id());
    
    // Verify caps point to different resolvers
    assert!(resolver::cap_resolver_id(&resolver_cap1) != resolver::cap_resolver_id(&resolver_cap2));
    
    test_utils::destroy(resolver1);
    test_utils::destroy(resolver_cap1);
    test_utils::destroy(resolver2);
    test_utils::destroy(resolver_cap2);
    scenario.end();
}

// Note: Integration tests with query module are covered in query_tests.move

// Removed integration tests - they are comprehensively covered in query_tests.move

// ====== Edge Case Tests ======

#[test]
fun resolver_id_consistency() {
    let mut scenario = test_scenario::begin(sender!());
    let (resolver, resolver_cap) = setup_resolver(&mut scenario);
    
    // Test ID consistency across different calls
    let id1 = resolver.id();
    let id2 = resolver.id();
    let cap_id = resolver::cap_resolver_id(&resolver_cap);
    
    assert!(id1 == id2);
    assert!(id1 == cap_id);
    assert!(id2 == cap_id);
    
    test_utils::destroy(resolver);
    test_utils::destroy(resolver_cap);
    scenario.end();
}

#[test]
fun resolution_with_future_queries() {
    let mut scenario = test_scenario::begin(sender!());
    let (protocol, protocol_cap) = setup_protocol(&mut scenario);
    let (mut resolver, resolver_cap) = setup_resolver(&mut scenario);
    
    resolver.enable(&protocol_cap);
    
    let clock = clock::create_for_testing(scenario.ctx());
    
    // Create resolution for query that doesn't exist yet (future query)
    let future_query_id = object::id_from_address(@0xFFF);
    let resolution = resolver::make_resolution(
        &resolver,
        &resolver_cap,
        future_query_id,
        b"preemptive resolution",
        &clock,
    );
    
    // Resolution should still be valid
    assert!(resolution.query_id() == future_query_id);
    assert!(resolution.data() == b"preemptive resolution");
    
    test_utils::destroy(resolution);
    test_utils::destroy(resolver);
    test_utils::destroy(resolver_cap);
    test_utils::destroy(protocol);
    test_utils::destroy(protocol_cap);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun concurrent_resolution_attempts() {
    let mut scenario = test_scenario::begin(sender!());
    let (protocol, protocol_cap) = setup_protocol(&mut scenario);
    let (mut resolver, resolver_cap) = setup_resolver(&mut scenario);
    
    resolver.enable(&protocol_cap);
    
    let clock = clock::create_for_testing(scenario.ctx());
    let query_id = object::id_from_address(@0x999);
    
    // Create multiple resolutions for same query (simulating concurrent attempts)
    let resolution1 = resolver::make_resolution(
        &resolver,
        &resolver_cap,
        query_id,
        b"first resolution",
        &clock,
    );
    
    let resolution2 = resolver::make_resolution(
        &resolver,
        &resolver_cap,
        query_id,
        b"second resolution",
        &clock,
    );
    
    // Both should be valid but different
    assert!(resolution1.query_id() == query_id);
    assert!(resolution2.query_id() == query_id);
    assert!(resolution1.data() != resolution2.data());
    assert!(resolution1.resolver_id() == resolution2.resolver_id());
    
    test_utils::destroy(resolution1);
    test_utils::destroy(resolution2);
    test_utils::destroy(resolver);
    test_utils::destroy(resolver_cap);
    test_utils::destroy(protocol);
    test_utils::destroy(protocol_cap);
    clock.destroy_for_testing();
    scenario.end();
}

// ====== Helper macros ======

macro fun sender(): address {
    @0xBaBe
}