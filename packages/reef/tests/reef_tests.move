#[test_only]
module reef::reef_tests;

use reef::dummy_creator;
use reef::dummy_resolver;
use reef::protocol::Protocol;
use reef::reef::{Self, Query};
use reef::resolver::{Self, Resolver};
use reef::test_utils::{
    admin,
    default_bond,
    default_fee,
    USDC,
    setup_dummy_resolver,
    setup_protocol as setup_basic_protocol,
    one_hour_ms,
    one_day_ms,
    submit_test_claim,
    challenge_challenger_wins,
    submit_claim_with_callback_and_verify,
    challenge_claim_with_callback_and_verify,
    submitter,
    challenger,
    setup_clock
};
use std::type_name;
use std::unit_test::assert_eq;
use sui::balance;
use sui::clock::Clock;
use sui::coin;
use sui::test_scenario::{Self, Scenario};

fun setup_protocol(scenario: &mut Scenario) {
    setup_basic_protocol(scenario, vector[b"ETH/USD", b"BTC/USD"])
}

fun create_query<CoinType, CreatorWitness: drop>(
    scenario: &mut Scenario,
    protocol: &mut Protocol,
    creator_witness: CreatorWitness,
    clock: &Clock,
): Query {
    let resolver = scenario.take_shared<Resolver>();

    let ctx = scenario.ctx();
    let fee = coin::mint_for_testing<CoinType>(default_fee!(), ctx);
    let config = reef::create_query_config(
        default_bond!(),
        option::some(one_hour_ms!()),
        clock.timestamp_ms() + one_day_ms!(),
        option::none(),
    );

    let query = reef::create_query<CoinType, CreatorWitness>(
        protocol,
        &resolver,
        creator_witness,
        fee,
        config,
        b"ETH/USD",
        b"Test query metadata",
        option::none(),
        clock,
        ctx,
    );

    test_scenario::return_shared(resolver);
    query
}

// ===== Basic Query Lifecycle Tests =====

#[test]
fun create_query_basic() {
    let mut scenario = test_scenario::begin(admin!());

    setup_clock(&mut scenario);
    scenario.next_tx(admin!());

    setup_protocol(&mut scenario);
    scenario.next_tx(admin!());

    setup_dummy_resolver(&mut scenario);

    scenario.next_tx(submitter!());
    {
        let mut protocol = scenario.take_shared<Protocol>();
        let clock = scenario.take_shared<Clock>();

        let query = create_query<USDC, _>(
            &mut scenario,
            &mut protocol,
            dummy_creator::make_witness(),
            &clock,
        );

        assert_eq!(query.topic(), b"ETH/USD");
        assert_eq!(query.metadata(), b"Test query metadata");
        assert_eq!(query.coin_type(), type_name::get<USDC>());
        assert_eq!(query.submitter(), option::none());
        assert_eq!(query.status(&clock), reef::query_status_created());

        query.share_query();

        test_scenario::return_shared(protocol);
        test_scenario::return_shared(clock);
    };

    scenario.end();
}

#[test]
fun submit_claim() {
    let mut scenario = test_scenario::begin(admin!());

    setup_clock(&mut scenario);
    scenario.next_tx(admin!());

    setup_protocol(&mut scenario);
    scenario.next_tx(admin!());

    setup_dummy_resolver(&mut scenario);

    scenario.next_tx(submitter!());
    {
        let clock = scenario.take_shared<Clock>();
        let mut protocol = scenario.take_shared<Protocol>();

        let query = create_query<USDC, _>(
            &mut scenario,
            &mut protocol,
            dummy_creator::make_witness(),
            &clock,
        );
        query.share_query();

        test_scenario::return_shared(clock);
        test_scenario::return_shared(protocol);
    };

    scenario.next_tx(submitter!());
    {
        let protocol = scenario.take_shared<Protocol>();
        let mut query = scenario.take_shared<Query>();
        let mut clock = scenario.take_shared<Clock>();

        submit_test_claim<USDC>(&mut query, &protocol, b"340934000000", &mut clock, scenario.ctx());

        assert_eq!(query.status(&clock), reef::query_status_submitted());
        assert_eq!(query.submitter(), option::some(submitter!()));
        assert_eq!(query.submitted_claim(), option::some(b"340934000000"));
        assert_eq!(query.bond_amount<USDC>(), default_bond!());

        test_scenario::return_shared(protocol);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(query);
    };

    scenario.end();
}

#[test]
fun challenge_and_resolve() {
    let mut scenario = test_scenario::begin(admin!());

    setup_clock(&mut scenario);
    scenario.next_tx(admin!());

    setup_protocol(&mut scenario);
    scenario.next_tx(admin!());

    setup_dummy_resolver(&mut scenario);

    scenario.next_tx(submitter!());
    {
        let mut protocol = scenario.take_shared<Protocol>();
        let clock = scenario.take_shared<Clock>();

        let query = create_query<USDC, _>(
            &mut scenario,
            &mut protocol,
            dummy_creator::make_witness(),
            &clock,
        );
        query.share_query();

        test_scenario::return_shared(clock);
        test_scenario::return_shared(protocol);
    };

    scenario.next_tx(submitter!());
    {
        let protocol = scenario.take_shared<Protocol>();
        let mut clock = scenario.take_shared<Clock>();

        let mut query = scenario.take_shared<Query>();

        submit_test_claim<USDC>(&mut query, &protocol, b"340934000000", &mut clock, scenario.ctx());

        test_scenario::return_shared(protocol);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(query);
    };

    scenario.next_tx(challenger!());
    {
        let mut query = scenario.take_shared<Query>();
        let resolver = scenario.take_shared<Resolver>();
        let mut clock = scenario.take_shared<Clock>();

        let resolution = challenge_challenger_wins<USDC>(
            &mut query,
            &resolver,
            b"295025000000",
            &mut clock,
            scenario.ctx(),
        );

        assert_eq!(query.status(&clock), reef::query_status_challenged());
        assert_eq!(query.challenger(), option::some(challenger!()));
        assert_eq!(query.bond_amount<USDC>(), default_bond!() * 2);

        // Settle the query
        let mut protocol = scenario.take_shared<Protocol>();
        query.settle_query<USDC>(&mut protocol, option::some(resolution), &clock, scenario.ctx());

        assert_eq!(query.is_settled(), true);
        assert_eq!(query.resolved_claim(), option::some(b"295025000000"));

        test_scenario::return_shared(protocol);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(query);
        test_scenario::return_shared(resolver);
    };

    scenario.end();
}

// ===== Validation Tests (Error Conditions) =====

#[test, expected_failure(abort_code = reef::EInsufficientBond)]
fun submit_claim_insufficient_bond() {
    let mut scenario = test_scenario::begin(admin!());

    setup_clock(&mut scenario);
    scenario.next_tx(admin!());

    setup_protocol(&mut scenario);
    scenario.next_tx(admin!());

    setup_dummy_resolver(&mut scenario);

    // Create query
    scenario.next_tx(submitter!());
    {
        let mut protocol = scenario.take_shared<Protocol>();
        let clock = scenario.take_shared<Clock>();

        let query = create_query<USDC, _>(
            &mut scenario,
            &mut protocol,
            dummy_creator::make_witness(),
            &clock,
        );
        query.share_query();

        test_scenario::return_shared(clock);
        test_scenario::return_shared(protocol);
    };

    // Try to submit claim with insufficient bond
    scenario.next_tx(submitter!());
    {
        let protocol = scenario.take_shared<Protocol>();
        let mut query = scenario.take_shared<Query>();
        let mut clock = scenario.take_shared<Clock>();

        clock.increment_for_testing(protocol.minimum_submission_delay_ms() + 1000);
        let bond = coin::mint_for_testing<USDC>(default_bond!() / 2, scenario.ctx());
        query.submit_claim<USDC>(&protocol, b"3000.50", bond, &clock, scenario.ctx());

        test_scenario::return_shared(protocol);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(query);
    };

    scenario.end();
}

#[test, expected_failure(abort_code = reef::ECannotChallengeSelf)]
fun challenge_own_claim() {
    let mut scenario = test_scenario::begin(admin!());

    setup_clock(&mut scenario);
    scenario.next_tx(admin!());

    setup_protocol(&mut scenario);
    scenario.next_tx(admin!());

    setup_dummy_resolver(&mut scenario);

    // Create query
    scenario.next_tx(submitter!());
    {
        let clock = scenario.take_shared<Clock>();
        let mut protocol = scenario.take_shared<Protocol>();

        let query = create_query<USDC, _>(
            &mut scenario,
            &mut protocol,
            dummy_creator::make_witness(),
            &clock,
        );
        query.share_query();

        test_scenario::return_shared(clock);
        test_scenario::return_shared(protocol);
    };

    // Submit claim
    scenario.next_tx(submitter!());
    {
        let protocol = scenario.take_shared<Protocol>();
        let mut query = scenario.take_shared<Query>();
        let mut clock = scenario.take_shared<Clock>();

        submit_test_claim<USDC>(&mut query, &protocol, b"3000.50", &mut clock, scenario.ctx());

        test_scenario::return_shared(protocol);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(query);
    };

    // Try to challenge own claim (same transaction sender)
    scenario.next_tx(submitter!());
    {
        let mut query = scenario.take_shared<Query>();
        let clock = scenario.take_shared<Clock>();

        let challenge_bond = coin::mint_for_testing<USDC>(default_bond!(), scenario.ctx());
        let challenge_request = reef::challenge_claim<USDC>(
            &mut query,
            challenge_bond,
            &clock,
            scenario.ctx(),
        );

        // Clean up challenge request by resolving it
        let resolver = scenario.take_shared<Resolver>();
        let _resolution = dummy_resolver::resolve_challenger_wins(
            &resolver,
            challenge_request,
            b"different_claim",
            &clock,
        );
        test_scenario::return_shared(resolver);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(query);
    };

    scenario.end();
}

// ===== Callback Integration Tests =====

#[test]
fun test_submit_claim_with_callback() {
    let mut scenario = test_scenario::begin(admin!());

    setup_clock(&mut scenario);
    scenario.next_tx(admin!());

    setup_protocol(&mut scenario);
    scenario.next_tx(admin!());

    setup_dummy_resolver(&mut scenario);

    // Create query
    scenario.next_tx(submitter!());
    {
        let mut protocol = scenario.take_shared<Protocol>();
        let clock = scenario.take_shared<Clock>();

        let query = create_query<USDC, _>(
            &mut scenario,
            &mut protocol,
            dummy_creator::make_witness(),
            &clock,
        );
        query.share_query();

        test_scenario::return_shared(clock);
        test_scenario::return_shared(protocol);
    };

    // Submit claim with callback
    scenario.next_tx(submitter!());
    {
        let protocol = scenario.take_shared<Protocol>();
        let mut query = scenario.take_shared<Query>();
        let mut clock = scenario.take_shared<Clock>();

        submit_claim_with_callback_and_verify<USDC, _>(
            &protocol,
            &mut query,
            b"3405.25",
            dummy_creator::make_witness(),
            &mut clock,
            scenario.ctx(),
        );

        assert_eq!(query.status(&clock), reef::query_status_submitted());
        assert_eq!(query.submitter(), option::some(submitter!()));
        assert_eq!(query.submitted_claim(), option::some(b"3405.25"));

        test_scenario::return_shared(protocol);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(query);
    };

    scenario.end();
}

#[test]
fun test_challenge_claim_with_callback() {
    let mut scenario = test_scenario::begin(admin!());

    setup_clock(&mut scenario);
    scenario.next_tx(admin!());

    setup_protocol(&mut scenario);
    scenario.next_tx(admin!());

    setup_dummy_resolver(&mut scenario);

    // Create and submit query
    scenario.next_tx(submitter!());
    {
        let mut protocol = scenario.take_shared<Protocol>();
        let clock = scenario.take_shared<Clock>();

        let query = create_query<USDC, _>(
            &mut scenario,
            &mut protocol,
            dummy_creator::make_witness(),
            &clock,
        );
        query.share_query();

        test_scenario::return_shared(clock);
        test_scenario::return_shared(protocol);
    };

    scenario.next_tx(submitter!());
    {
        let protocol = scenario.take_shared<Protocol>();
        let mut query = scenario.take_shared<Query>();
        let mut clock = scenario.take_shared<Clock>();

        submit_test_claim<USDC>(&mut query, &protocol, b"3405.25", &mut clock, scenario.ctx());

        test_scenario::return_shared(protocol);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(query);
    };

    // Challenge with callback
    scenario.next_tx(challenger!());
    {
        let mut query = scenario.take_shared<Query>();
        let clock = scenario.take_shared<Clock>();
        let challenge_request = challenge_claim_with_callback_and_verify<USDC, _>(
            &mut query,
            dummy_creator::make_witness(),
            &clock,
            scenario.ctx(),
        );

        // Unpack and dispose of the challenge request
        let resolver = scenario.take_shared<Resolver>();
        let (
            _query_id,
            balance,
            _challenger,
            _timestamp,
            _witness_type,
        ) = resolver::unpack_challenge_request(challenge_request);
        balance::destroy_for_testing(balance);
        test_scenario::return_shared(resolver);

        assert_eq!(query.status(&clock), reef::query_status_challenged());
        assert_eq!(query.challenger(), option::some(challenger!()));

        test_scenario::return_shared(query);
        test_scenario::return_shared(clock);
    };

    scenario.end();
}

// ===== Reward System Tests =====

#[test]
fun test_add_reward() {
    let mut scenario = test_scenario::begin(admin!());

    setup_clock(&mut scenario);
    scenario.next_tx(admin!());

    setup_protocol(&mut scenario);
    scenario.next_tx(admin!());

    setup_dummy_resolver(&mut scenario);

    scenario.next_tx(submitter!());
    {
        let mut protocol = scenario.take_shared<Protocol>();
        let clock = scenario.take_shared<Clock>();

        let mut query = create_query<USDC, _>(
            &mut scenario,
            &mut protocol,
            dummy_creator::make_witness(),
            &clock,
        );

        // Initially no reward
        assert_eq!(query.reward_amount<USDC>(), 0);

        // Add reward
        let reward = coin::mint_for_testing<USDC>(500000, scenario.ctx());
        query.add_reward(&dummy_creator::make_witness(), reward, &clock);

        // Verify reward was added
        assert_eq!(query.reward_amount<USDC>(), 500000);

        query.share_query();

        test_scenario::return_shared(protocol);
        test_scenario::return_shared(clock);
    };

    scenario.end();
}

// ===== Query Expiration Tests =====

#[test]
fun test_query_expiration() {
    let mut scenario = test_scenario::begin(admin!());

    setup_clock(&mut scenario);
    scenario.next_tx(admin!());

    setup_protocol(&mut scenario);
    scenario.next_tx(admin!());

    setup_dummy_resolver(&mut scenario);

    scenario.next_tx(submitter!());
    {
        let mut protocol = scenario.take_shared<Protocol>();
        let mut clock = scenario.take_shared<Clock>();

        let query = create_query<USDC, _>(
            &mut scenario,
            &mut protocol,
            dummy_creator::make_witness(),
            &clock,
        );
        let expires_at = query.expires_at_ms();

        // Initially not expired
        assert_eq!(query.is_expired(&clock), false);
        assert_eq!(query.status(&clock), reef::query_status_created());

        // Fast forward past expiration
        clock.increment_for_testing(expires_at + 1000);

        // Now expired
        assert_eq!(query.is_expired(&clock), true);
        assert_eq!(query.status(&clock), reef::query_status_expired());

        query.share_query();

        test_scenario::return_shared(protocol);
        test_scenario::return_shared(clock);
    };

    scenario.end();
}

// ===== Getter Function Tests =====

#[test]
fun test_query_getters() {
    let mut scenario = test_scenario::begin(admin!());

    setup_clock(&mut scenario);
    scenario.next_tx(admin!());

    setup_protocol(&mut scenario);
    scenario.next_tx(admin!());

    setup_dummy_resolver(&mut scenario);

    scenario.next_tx(submitter!());
    {
        let mut protocol = scenario.take_shared<Protocol>();
        let clock = scenario.take_shared<Clock>();

        let query = create_query<USDC, _>(
            &mut scenario,
            &mut protocol,
            dummy_creator::make_witness(),
            &clock,
        );
        let creation_time = clock.timestamp_ms();

        // Test basic getters
        assert_eq!(query.topic(), b"ETH/USD");
        assert_eq!(query.metadata(), b"Test query metadata");
        assert_eq!(query.coin_type(), type_name::get<USDC>());
        assert_eq!(query.created_at_ms(), creation_time);
        assert_eq!(query.bond_amount<USDC>(), 0); // No bond submitted yet

        // Initially unsubmitted
        assert_eq!(query.submitter(), option::none());
        assert_eq!(query.submitted_claim(), option::none());
        assert_eq!(query.submitted_at_ms(), option::none());
        assert_eq!(query.challenger(), option::none());
        assert_eq!(query.challenged_at_ms(), option::none());
        assert_eq!(query.resolved_claim(), option::none());
        assert_eq!(query.is_settled(), false);

        query.share_query();

        test_scenario::return_shared(protocol);
        test_scenario::return_shared(clock);
    };

    scenario.end();
}

#[test]
fun test_query_lifecycle_getters() {
    let mut scenario = test_scenario::begin(admin!());

    setup_clock(&mut scenario);
    scenario.next_tx(admin!());

    setup_protocol(&mut scenario);
    scenario.next_tx(admin!());

    setup_dummy_resolver(&mut scenario);

    // Create query
    scenario.next_tx(submitter!());
    {
        let mut protocol = scenario.take_shared<Protocol>();
        let clock = scenario.take_shared<Clock>();

        let query = create_query<USDC, _>(
            &mut scenario,
            &mut protocol,
            dummy_creator::make_witness(),
            &clock,
        );

        query.share_query();
        test_scenario::return_shared(protocol);
        test_scenario::return_shared(clock);
    };

    // Submit claim and test getters
    scenario.next_tx(submitter!());
    {
        let protocol = scenario.take_shared<Protocol>();
        let mut clock = scenario.take_shared<Clock>();
        let mut query = scenario.take_shared<Query>();

        submit_test_claim<USDC>(&mut query, &protocol, b"3405.25", &mut clock, scenario.ctx());
        let submit_time = clock.timestamp_ms();

        // Test submitted state getters
        assert_eq!(query.submitter(), option::some(submitter!()));
        assert_eq!(query.submitted_claim(), option::some(b"3405.25"));
        assert_eq!(query.submitted_at_ms(), option::some(submit_time));
        assert_eq!(query.challenger(), option::none());
        assert_eq!(query.challenged_at_ms(), option::none());

        test_scenario::return_shared(protocol);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(query);
    };

    // Challenge and test getters
    scenario.next_tx(challenger!());
    {
        let mut query = scenario.take_shared<Query>();
        let resolver = scenario.take_shared<Resolver>();
        let mut clock = scenario.take_shared<Clock>();

        let challenge_time_before = clock.timestamp_ms();
        let resolution = challenge_challenger_wins<USDC>(
            &mut query,
            &resolver,
            b"3200.00",
            &mut clock,
            scenario.ctx(),
        );

        // Test challenged state getters
        assert_eq!(query.challenger(), option::some(challenger!()));
        // The challenge was recorded at challenge_time_before, not after clock increment
        assert_eq!(query.challenged_at_ms(), option::some(challenge_time_before));

        // Settle and test final getters
        let mut protocol = scenario.take_shared<Protocol>();
        query.settle_query<USDC>(&mut protocol, option::some(resolution), &clock, scenario.ctx());

        assert_eq!(query.is_settled(), true);
        assert_eq!(query.resolved_claim(), option::some(b"3200.00"));

        test_scenario::return_shared(protocol);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(query);
        test_scenario::return_shared(resolver);
    };

    scenario.end();
}

// ===== Refund System Tests =====

#[test]
fun test_set_refund_address() {
    let mut scenario = test_scenario::begin(admin!());

    setup_clock(&mut scenario);
    scenario.next_tx(admin!());

    setup_protocol(&mut scenario);
    scenario.next_tx(admin!());

    setup_dummy_resolver(&mut scenario);

    scenario.next_tx(submitter!());
    {
        let mut protocol = scenario.take_shared<Protocol>();
        let clock = scenario.take_shared<Clock>();

        let mut query = create_query<USDC, _>(
            &mut scenario,
            &mut protocol,
            dummy_creator::make_witness(),
            &clock,
        );

        // Set refund address
        reef::set_refund_address(
            &mut query,
            &dummy_creator::make_witness(),
            option::some(challenger!()),
            &clock,
        );

        // Verify query still works normally
        assert_eq!(query.topic(), b"ETH/USD");
        assert_eq!(query.coin_type(), type_name::get<USDC>());

        query.share_query();

        test_scenario::return_shared(protocol);
        test_scenario::return_shared(clock);
    };

    scenario.end();
}
