#[test_only]
module reef::test;

use sui::clock::{Self, Clock};
use sui::test_scenario::{Self, Scenario};

public struct Test {
    clock: Clock,
    scenario: Scenario,
}

public fun begin(sender: address): Test {
    let mut scenario = test_scenario::begin(sender);
    let clock = clock::create_for_testing(scenario.ctx());

    Test {
        clock,
        scenario,
    }
}

public fun end(test: Test) {
    let Test { scenario, clock } = test;

    scenario.end();
    clock.destroy_for_testing();
}

public fun scenario(test: &mut Test): &mut Scenario {
    &mut test.scenario
}

public fun clock(test: &Test): &Clock {
    &test.clock
}

public fun clock_mut(test: &mut Test): &mut Clock {
    &mut test.clock
}
