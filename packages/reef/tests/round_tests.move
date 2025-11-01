#[test_only]
module reef::round_tests;

use reef::resolver::ResolverCap;
use reef::resolver_tests;
use reef::round::{Self, RoundManager};
use sui::clock;
use sui::test_scenario::{Self, Scenario};
use sui::test_utils;

public struct TestResolver() has drop;

/// Creates a RoundManager with default settings
fun setup_round_manager(scenario: &mut Scenario): RoundManager {
    let clock = clock::create_for_testing(scenario.ctx());
    let manager = round::new_round_manager(
        option::none(), // Use default duration
        &clock,
        scenario.ctx(),
    );

    clock.destroy_for_testing();
    manager
}

/// Creates a RoundManager with custom duration
fun setup_custom_round_manager(scenario: &mut Scenario, duration_ms: u64): RoundManager {
    let clock = clock::create_for_testing(scenario.ctx());
    let manager = round::new_round_manager(
        option::some(duration_ms),
        &clock,
        scenario.ctx(),
    );

    clock.destroy_for_testing();
    manager
}

/// Creates a test ResolverCap for storage tests
fun setup_resolver_cap(scenario: &mut Scenario): ResolverCap {
    let (resolver, resolver_cap) = resolver_tests::setup_resolver(scenario);
    test_utils::destroy(resolver);

    resolver_cap
}

#[test]
fun create_round_manager_basic() {
    let mut scenario = test_scenario::begin(sender!());
    let manager = setup_round_manager(&mut scenario);

    // Check default values
    assert!(manager.round_duration_ms() == round::default_round_duration_ms!());
    assert!(manager.genesis_timestamp_ms() >= 0);

    test_utils::destroy(manager);
    scenario.end();
}

#[test]
fun create_round_manager_custom_duration() {
    let mut scenario = test_scenario::begin(sender!());
    let custom_duration = 24 * 60 * 60 * 1000; // 24 hours
    let manager = setup_custom_round_manager(&mut scenario, custom_duration);

    // Check custom duration
    assert!(manager.round_duration_ms() == custom_duration);

    test_utils::destroy(manager);
    scenario.end();
}

#[test]
fun current_round_creation() {
    let mut scenario = test_scenario::begin(sender!());
    let mut manager = setup_round_manager(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());

    // Get current round (should auto-create round 0)
    let current_round = manager.current_round(&clock, scenario.ctx());
    assert!(current_round.round_no() == 0);
    assert!(current_round.start_time_ms() == manager.genesis_timestamp_ms());

    test_utils::destroy(manager);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun next_round_creation() {
    let mut scenario = test_scenario::begin(sender!());
    let mut manager = setup_round_manager(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());

    // Get next round (should auto-create round 1)
    let next_round = manager.next_round(&clock, scenario.ctx());
    assert!(next_round.round_no() == 1);

    test_utils::destroy(manager);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun round_boundaries_calculation() {
    let mut scenario = test_scenario::begin(sender!());
    let manager = setup_custom_round_manager(&mut scenario, 1000); // 1 second rounds

    let (start0, end0) = manager.round_boundaries(0);
    let (start1, end1) = manager.round_boundaries(1);

    // Round 0 should start at genesis
    assert!(start0 == manager.genesis_timestamp_ms());
    assert!(end0 == start0 + 1000);

    // Round 1 should start where round 0 ends
    assert!(start1 == end0);
    assert!(end1 == start1 + 1000);

    test_utils::destroy(manager);
    scenario.end();
}

#[test]
fun round_no_for_timestamp() {
    let mut scenario = test_scenario::begin(sender!());
    let manager = setup_custom_round_manager(&mut scenario, 1000); // 1 second rounds

    let genesis = manager.genesis_timestamp_ms();

    // Test various timestamps
    assert!(manager.round_no_for_timestamp(genesis) == 0);
    assert!(manager.round_no_for_timestamp(genesis + 500) == 0);
    assert!(manager.round_no_for_timestamp(genesis + 999) == 0);
    assert!(manager.round_no_for_timestamp(genesis + 1000) == 1);
    assert!(manager.round_no_for_timestamp(genesis + 1500) == 1);
    assert!(manager.round_no_for_timestamp(genesis + 2000) == 2);

    test_utils::destroy(manager);
    scenario.end();
}

#[test]
fun get_round_for_timestamp() {
    let mut scenario = test_scenario::begin(sender!());
    let mut manager = setup_custom_round_manager(&mut scenario, 1000); // 1 second rounds

    let genesis = manager.genesis_timestamp_ms();

    // Get round for specific timestamp
    let round = manager.get_round_for_timestamp(genesis + 1500, scenario.ctx());
    assert!(round.round_no() == 1);

    test_utils::destroy(manager);
    scenario.end();
}

#[test]
fun round_view_functions() {
    let mut scenario = test_scenario::begin(sender!());
    let mut manager = setup_custom_round_manager(&mut scenario, 2000); // 2 second rounds
    let clock = clock::create_for_testing(scenario.ctx());

    let round = manager.current_round(&clock, scenario.ctx());

    // Test all view functions
    let start_time = round.start_time_ms();
    let end_time = round.end_time_ms();
    let commit_end = round.commit_end_time_ms();

    assert!(round.round_no() == 0);
    assert!(end_time == start_time + 2000);
    assert!(commit_end == start_time + 1000); // Halfway point

    test_utils::destroy(manager);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = round::ERoundNotFound)]
fun round_not_found_error() {
    let mut scenario = test_scenario::begin(sender!());
    let manager = setup_round_manager(&mut scenario);

    // Try to get a round that doesn't exist
    let _round = manager.get_round(999);

    test_utils::destroy(manager);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = round::ETimestampBeforeGenesis)]
fun timestamp_before_genesis_error() {
    let mut scenario = test_scenario::begin(sender!());
    let mut clock = clock::create_for_testing(scenario.ctx());

    // Set genesis to a non-zero value to avoid underflow
    clock.increment_for_testing(1000);

    let manager = round::new_round_manager(
        option::some(1000),
        &clock,
        scenario.ctx(),
    );

    let genesis = manager.genesis_timestamp_ms();

    // Try to get round number for timestamp before genesis
    manager.round_no_for_timestamp(genesis - 1);

    test_utils::destroy(manager);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun storage_not_initialized_by_default() {
    let mut scenario = test_scenario::begin(sender!());
    let mut manager = setup_round_manager(&mut scenario);
    let resolver_cap = setup_resolver_cap(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());

    // Storage should not be initialized initially
    assert!(!manager.current_round(&clock, scenario.ctx()).is_storage_initialized(&resolver_cap));

    test_utils::destroy(manager);
    test_utils::destroy(resolver_cap);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun round_transition_timing() {
    let mut scenario = test_scenario::begin(sender!());
    let manager = setup_custom_round_manager(&mut scenario, 1000); // 1 second rounds
    let mut clock = clock::create_for_testing(scenario.ctx());

    // Current round should be 0
    assert!(manager.current_round_no(&clock) == 0);

    // Advance to next round
    clock.increment_for_testing(1000);
    assert!(manager.current_round_no(&clock) == 1);

    // Advance to round 5
    clock.increment_for_testing(4000);
    assert!(manager.current_round_no(&clock) == 5);

    test_utils::destroy(manager);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun is_round_active_detection() {
    let mut scenario = test_scenario::begin(sender!());
    let mut manager = setup_custom_round_manager(&mut scenario, 1000); // 1 second rounds
    let mut clock = clock::create_for_testing(scenario.ctx());

    // Create round 0
    let _round0 = manager.current_round(&clock, scenario.ctx());

    // Round 0 should be active at start
    assert!(manager.is_round_active(0, &clock));

    // Round 1 should not be active yet
    assert!(!manager.is_round_active(1, &clock));

    // Advance to round 1
    clock.increment_for_testing(1000);

    // Create round 1 so it exists before checking if it's active
    let _round1 = manager.current_round(&clock, scenario.ctx());

    // Now round 1 should be active, round 0 should not be
    assert!(!manager.is_round_active(0, &clock));
    assert!(manager.is_round_active(1, &clock));

    test_utils::destroy(manager);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun round_phase_detection_basic() {
    let mut scenario = test_scenario::begin(sender!());
    let mut manager = setup_custom_round_manager(&mut scenario, 2000); // 2 second rounds
    let clock = clock::create_for_testing(scenario.ctx());

    let round = manager.current_round(&clock, scenario.ctx());

    // At start of round should be in commit phase
    assert!(round.is_in_commit_phase(&clock));
    assert!(!round.is_in_reveal_phase(&clock));

    test_utils::destroy(manager);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun sequential_round_creation() {
    let mut scenario = test_scenario::begin(sender!());
    let mut manager = setup_custom_round_manager(&mut scenario, 1000); // 1 second rounds
    let mut clock = clock::create_for_testing(scenario.ctx());

    // Create rounds 0-4 sequentially
    let mut i = 0;
    while (i < 5) {
        if (i > 0) {
            clock.increment_for_testing(1000);
        };
        let round = manager.current_round(&clock, scenario.ctx());
        assert!(round.round_no() == i);
        i = i + 1;
    };

    test_utils::destroy(manager);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun round_manager_state_consistency() {
    let mut scenario = test_scenario::begin(sender!());
    let mut manager = setup_custom_round_manager(&mut scenario, 5000); // 5 second rounds
    let clock = clock::create_for_testing(scenario.ctx());

    let _start0;
    let _end0;
    let _start1;
    let _end1;
    let _start2;

    // Create several rounds and verify consistency
    {
        let round0 = manager.current_round(&clock, scenario.ctx());
        assert!(round0.round_no() == 0);
        _start0 = round0.start_time_ms();
        _end0 = round0.end_time_ms();
    };

    {
        let round1 = manager.next_round(&clock, scenario.ctx());
        assert!(round1.round_no() == 1);
        _start1 = round1.start_time_ms();
        _end1 = round1.end_time_ms();
    };

    {
        let round2 = manager.get_or_create_round(2, scenario.ctx());
        assert!(round2.round_no() == 2);
        _start2 = round2.start_time_ms();
    };

    // Check time relationships
    assert!(_start1 == _end0);
    assert!(_start2 == _end1);

    test_utils::destroy(manager);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun genesis_timestamp_edge_cases() {
    let mut scenario = test_scenario::begin(sender!());
    let mut clock = clock::create_for_testing(scenario.ctx());

    // Set specific timestamp
    clock.increment_for_testing(1000000);
    let genesis_time = clock.timestamp_ms();

    let manager = round::new_round_manager(
        option::some(1000),
        &clock,
        scenario.ctx(),
    );

    // Genesis should match clock time
    assert!(manager.genesis_timestamp_ms() == genesis_time);

    // Round 0 should start at genesis
    let (start0, _) = manager.round_boundaries(0);
    assert!(start0 == genesis_time);

    test_utils::destroy(manager);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun timestamp_calculations_precision() {
    let mut scenario = test_scenario::begin(sender!());
    let manager = setup_custom_round_manager(&mut scenario, 1000); // 1 second rounds

    let genesis = manager.genesis_timestamp_ms();

    // Test precise boundary calculations
    assert!(manager.round_no_for_timestamp(genesis + 0) == 0);
    assert!(manager.round_no_for_timestamp(genesis + 999) == 0);
    assert!(manager.round_no_for_timestamp(genesis + 1000) == 1);
    assert!(manager.round_no_for_timestamp(genesis + 1001) == 1);
    assert!(manager.round_no_for_timestamp(genesis + 1999) == 1);
    assert!(manager.round_no_for_timestamp(genesis + 2000) == 2);

    test_utils::destroy(manager);
    scenario.end();
}

#[test]
fun large_round_numbers() {
    let mut scenario = test_scenario::begin(sender!());
    let mut manager = setup_custom_round_manager(&mut scenario, 1000); // 1 second rounds
    let clock = clock::create_for_testing(scenario.ctx());

    // Test large round number
    let large_round_no = 1000000;
    let round = manager.get_or_create_round(large_round_no, scenario.ctx());

    assert!(round.round_no() == large_round_no);

    // Verify boundaries calculation works for large numbers
    let (start, end) = manager.round_boundaries(large_round_no);
    assert!(end == start + 1000);

    test_utils::destroy(manager);
    clock.destroy_for_testing();
    scenario.end();
}

macro fun sender(): address {
    @0xBaBe
}
