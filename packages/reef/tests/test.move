#[test_only]
module reef::test;

use sui::test_scenario::{Self, Scenario};

public struct Test {
    scenario: Scenario
}

public fun begin(sender: address): Test {
    Test {
        scenario: test_scenario::begin(sender)
    }
}

public fun end(test: Test) {
    let Test { scenario } = test;
    scenario.end();
}

public fun scenario(test: &mut Test): &mut Scenario {
    &mut test.scenario
}