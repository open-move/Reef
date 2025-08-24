#[test_only]
module reef::test_utils;

use reef::callback;
use reef::dummy_creator;
use reef::dummy_resolver;
use reef::protocol::{Self, Protocol};
use reef::reef::{Self, Query};
use reef::resolver::{Self, Resolver};
use std::type_name;
use sui::clock::{Self, Clock};
use sui::coin;
use sui::test_scenario::{Self, Scenario};

public struct USDC() has drop;

public fun setup_protocol(scenario: &mut Scenario, topics: vector<vector<u8>>) {
    let (mut protocol, cap) = protocol::initialize_for_testing(scenario.ctx());

    let usdc_type = type_name::get<USDC>();
    protocol.add_allowed_coin_type(&cap, usdc_type);

    protocol.set_resolution_fee(&cap, usdc_type, default_fee!());
    topics.do!(|topic| { protocol.add_allowed_topic(&cap, topic); });

    protocol.share_protocol();
    cap.transfer_protocol_cap(admin!());
}

public fun setup_dummy_resolver(scenario: &mut Scenario) {
    let cap = scenario.take_from_address(admin!());

    let mut resolver = dummy_resolver::create_resolver(scenario.ctx());
    resolver.enable(&cap);
    resolver.share();

    test_scenario::return_to_address(admin!(), cap)
}

public fun setup_clock(scenario: &mut Scenario) {
    let clock = clock::create_for_testing(scenario.ctx());
    clock::share_for_testing(clock);
}

public fun submit_test_claim<CoinType>(
    query: &mut Query,
    claim: vector<u8>,
    clock: &mut Clock,
    ctx: &mut TxContext,
) {
    let bond = coin::mint_for_testing<CoinType>(query.bond_amount(), ctx);
    query.submit_claim<CoinType>(claim, bond, clock, ctx);
}

public fun submit_claim_with_callback<CoinType>(
    query: &mut Query,
    claim: vector<u8>,
    clock: &mut Clock,
    ctx: &mut TxContext,
) {
    let bond = coin::mint_for_testing<CoinType>(query.bond_amount(), ctx);
    let callback = reef::submit_claim_with_callback<CoinType>(
        query,
        claim,
        bond,
        clock,
        ctx,
    );

    callback::verify_claim_submitted(callback, dummy_creator::make_witness());
}

public fun create_challenge<CoinType>(
    query: &mut Query,
    protocol: &Protocol,
    clock: &Clock,
    ctx: &mut TxContext,
): resolver::Challenge<CoinType> {
    let challenge_bond = coin::mint_for_testing<CoinType>(query.bond_amount(), ctx);
    reef::challenge_claim<CoinType>(query, protocol, challenge_bond, clock, ctx)
}

public fun challenge_challenger_wins<CoinType>(
    query: &mut Query,
    protocol: &Protocol,
    resolver: &Resolver,
    new_claim: vector<u8>,
    clock: &mut Clock,
    ctx: &mut TxContext,
): resolver::Resolution {
    let challenge_bond = coin::mint_for_testing<CoinType>(query.bond_amount(), ctx);
    let challenge_request = reef::challenge_claim<CoinType>(query, protocol, challenge_bond, clock, ctx);
    clock.increment_for_testing(1000);
    dummy_resolver::resolve_challenger_wins(resolver, challenge_request, new_claim, clock)
}

public fun challenge_submitter_wins<CoinType>(
    query: &mut Query,
    protocol: &Protocol,
    resolver: &Resolver,
    original_claim: vector<u8>,
    clock: &mut Clock,
    ctx: &mut TxContext,
): resolver::Resolution {
    let challenge_bond = coin::mint_for_testing<CoinType>(query.bond_amount(), ctx);
    let challenge_request = reef::challenge_claim<CoinType>(query, protocol, challenge_bond, clock, ctx);
    clock.increment_for_testing(1000);
    dummy_resolver::resolve_submitter_wins(resolver, challenge_request, original_claim, clock)
}

public fun submit_claim_with_callback_and_verify<CoinType, Oracle: drop>(
    query: &mut Query,
    claim: vector<u8>,
    oracle: Oracle,
    clock: &mut Clock,
    ctx: &mut TxContext,
) {
    let bond = coin::mint_for_testing<CoinType>(query.bond_amount(), ctx);
    let callback = reef::submit_claim_with_callback<CoinType>(
        query,
        claim,
        bond,
        clock,
        ctx,
    );

    callback::verify_claim_submitted(callback, oracle);
}

public fun challenge_claim_with_callback_and_verify<CoinType, Oracle: drop>(
    query: &mut Query,
    protocol: &Protocol,
    oracle: Oracle,
    clock: &Clock,
    ctx: &mut TxContext,
): resolver::Challenge<CoinType> {
    let challenge_bond = coin::mint_for_testing<CoinType>(query.bond_amount(), ctx);
    let (challenge_request, callback) = reef::challenge_claim_with_callback<CoinType>(
        query,
        protocol,
        challenge_bond,
        clock,
        ctx,
    );

    callback::verify_claim_challenged(callback, oracle);
    challenge_request
}

public fun settle_query_with_callback_and_verify<CoinType, Oracle: drop>(
    query: &mut Query,
    resolution: resolver::Resolution,
    oracle: Oracle,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let callback = reef::settle_query_with_callback<CoinType>(
        query,
        option::some(resolution),
        clock,
        ctx,
    );

    callback::verify_query_settled(callback, oracle);
}

public macro fun admin(): address { @0xAd319 }
public macro fun submitter(): address { @0xFaDe }
public macro fun challenger(): address { @0xBaBe }

public macro fun one_hour_ms(): u64 { 3600000 }
public macro fun one_day_ms(): u64 { 86400000 }
public macro fun default_bond(): u64 { 1000000 }
public macro fun default_fee(): u64 { 100000 }
