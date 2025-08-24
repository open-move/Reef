#[test_only]
module reef::protocol_tests;

use reef::protocol::{Self, Protocol, ProtocolCap};
use reef::test;
use reef::test_utils::{admin, USDC};
use std::type_name;
use std::unit_test::assert_eq;
use sui::sui::SUI;
use sui::test_scenario;

#[test]
fun protocol_initialization() {
    let mut test = test::begin(admin!());
    let scenario = test.scenario();

    scenario.next_tx(admin!());
    {
        let (protocol, cap) = protocol::initialize_for_testing(scenario.ctx());

        assert_eq!(protocol.fee_factor_bps(), protocol::default_fee_factor!());
        assert_eq!(protocol.minimum_liveness_ms(), protocol::default_minimum_liveness_ms!());

        protocol.share_protocol();
        cap.transfer_protocol_cap(admin!());
    };

    test.end()
}

#[test]
fun fee_factor_management() {
    let mut test = test::begin(admin!());
    let scenario = test.scenario();

    scenario.next_tx(admin!());
    {
        let (protocol, cap) = protocol::initialize_for_testing(scenario.ctx());
        protocol.share_protocol();
        cap.transfer_protocol_cap(admin!());
    };

    scenario.next_tx(admin!());
    {
        let mut protocol = scenario.take_shared<Protocol>();
        let cap = scenario.take_from_sender<ProtocolCap>();

        // Test setting valid fee factor
        protocol.set_fee_factor(&cap, 2500); // 25%
        assert_eq!(protocol.fee_factor_bps(), 2500);

        // Test setting maximum fee factor
        protocol.set_fee_factor(&cap, 10000); // 100%
        assert_eq!(protocol.fee_factor_bps(), 10000);

        // Test setting zero fee factor
        protocol.set_fee_factor(&cap, 0);
        assert_eq!(protocol.fee_factor_bps(), 0);

        test_scenario::return_shared(protocol);
        scenario.return_to_sender(cap);
    };

    test.end()
}

#[test, expected_failure(abort_code = reef::protocol::EInvalidFeeFactor)]
fun fee_factor_validation() {
    let mut test = test::begin(admin!());
    let scenario = test.scenario();

    scenario.next_tx(admin!());
    {
        let (protocol, cap) = protocol::initialize_for_testing(scenario.ctx());
        protocol.share_protocol();
        cap.transfer_protocol_cap(admin!());
    };

    scenario.next_tx(admin!());
    {
        let mut protocol = scenario.take_shared<Protocol>();
        let cap = scenario.take_from_sender<ProtocolCap>();

        protocol.set_fee_factor(&cap, 10001); // > 100%, should fail

        test_scenario::return_shared(protocol);
        scenario.return_to_sender(cap);
    };

    test.end()
}

#[test]
fun coin_type_whitelist() {
    let mut test = test::begin(admin!());
    let scenario = test.scenario();

    scenario.next_tx(admin!());
    {
        let (protocol, cap) = protocol::initialize_for_testing(scenario.ctx());
        protocol.share_protocol();
        cap.transfer_protocol_cap(admin!());
    };

    scenario.next_tx(admin!());
    {
        let mut protocol = scenario.take_shared<Protocol>();
        let cap = scenario.take_from_sender<ProtocolCap>();

        let usdc_type = type_name::get<USDC>();
        let sui_type = type_name::get<SUI>();

        // Initially no coin types are allowed
        assert_eq!(protocol.is_allowed_coin_type(usdc_type), false);
        assert_eq!(protocol.is_allowed_coin_type(sui_type), false);

        // Add coin types
        protocol.add_allowed_coin_type(&cap, usdc_type);
        protocol.add_allowed_coin_type(&cap, sui_type);

        assert_eq!(protocol.is_allowed_coin_type(usdc_type), true);
        assert_eq!(protocol.is_allowed_coin_type(sui_type), true);

        // Remove one coin type
        protocol.remove_allowed_coin_type(&cap, usdc_type);
        assert_eq!(protocol.is_allowed_coin_type(usdc_type), false);
        assert_eq!(protocol.is_allowed_coin_type(sui_type), true);

        test_scenario::return_shared(protocol);
        scenario.return_to_sender(cap);
    };

    test.end()
}

#[test]
fun topic_whitelist() {
    let mut test = test::begin(admin!());
    let scenario = test.scenario();

    scenario.next_tx(admin!());
    {
        let (protocol, cap) = protocol::initialize_for_testing(scenario.ctx());
        protocol.share_protocol();
        cap.transfer_protocol_cap(admin!());
    };

    scenario.next_tx(admin!());
    {
        let mut protocol = scenario.take_shared<Protocol>();
        let cap = scenario.take_from_sender<ProtocolCap>();

        let eth_topic = b"ETH/USD";
        let btc_topic = b"BTC/USD";

        // Initially no topics are allowed
        assert_eq!(protocol.is_topic_allowed(&eth_topic), false);
        assert_eq!(protocol.is_topic_allowed(&btc_topic), false);

        // Add topics
        protocol.add_allowed_topic(&cap, eth_topic);
        protocol.add_allowed_topic(&cap, btc_topic);

        assert_eq!(protocol.is_topic_allowed(&eth_topic), true);
        assert_eq!(protocol.is_topic_allowed(&btc_topic), true);

        // Remove one topic
        protocol.remove_allowed_topic(&cap, eth_topic);
        assert_eq!(protocol.is_topic_allowed(&eth_topic), false);
        assert_eq!(protocol.is_topic_allowed(&btc_topic), true);

        test_scenario::return_shared(protocol);
        scenario.return_to_sender(cap);
    };

    test.end()
}

#[test]
fun resolution_fee_management() {
    let mut test = test::begin(admin!());
    let scenario = test.scenario();

    scenario.next_tx(admin!());
    {
        let (protocol, cap) = protocol::initialize_for_testing(scenario.ctx());
        protocol.share_protocol();
        cap.transfer_protocol_cap(admin!());
    };

    scenario.next_tx(admin!());
    {
        let mut protocol = scenario.take_shared<Protocol>();
        let cap = scenario.take_from_sender<ProtocolCap>();

        let usdc_type = type_name::get<USDC>();
        let sui_type = type_name::get<SUI>();

        // Set resolution fee amounts
        protocol.set_resolution_fee(&cap, usdc_type, 1000000); // 1 USDC
        protocol.set_resolution_fee(&cap, sui_type, 100000000); // 0.1 SUI

        assert_eq!(protocol.resolution_fee(usdc_type), 1000000);
        assert_eq!(protocol.resolution_fee(sui_type), 100000000);

        // Update existing fee
        protocol.set_resolution_fee(&cap, usdc_type, 2000000); // 2 USDC
        assert_eq!(protocol.resolution_fee(usdc_type), 2000000);

        test_scenario::return_shared(protocol);
        scenario.return_to_sender(cap);
    };

    test.end()
}

#[test]
fun minimum_bond_calculation() {
    let mut test = test::begin(admin!());
    let scenario = test.scenario();

    scenario.next_tx(admin!());
    {
        let (protocol, cap) = protocol::initialize_for_testing(scenario.ctx());
        protocol.share_protocol();
        cap.transfer_protocol_cap(admin!());
    };

    scenario.next_tx(admin!());
    {
        let mut protocol = scenario.take_shared<Protocol>();
        let cap = scenario.take_from_sender<ProtocolCap>();

        let usdc_type = type_name::get<USDC>();

        // First add the coin type to whitelist
        protocol.add_allowed_coin_type(&cap, usdc_type);

        // Set resolution fee - minimum bond will be calculated from this
        protocol.set_resolution_fee(&cap, usdc_type, 1000000); // 1 USDC resolution fee
        
        // With default fee factor of 50% (5000 bps), minimum bond should be 2 USDC
        // minimum_bond = (resolution_fee * 10000) / fee_factor_bps = (1000000 * 10000) / 5000 = 2000000
        assert_eq!(protocol.minimum_bond(usdc_type), 2000000);

        // Update resolution fee
        protocol.set_resolution_fee(&cap, usdc_type, 500000); // 0.5 USDC resolution fee
        // New minimum bond should be 1 USDC
        assert_eq!(protocol.minimum_bond(usdc_type), 1000000);

        test_scenario::return_shared(protocol);
        scenario.return_to_sender(cap);
    };

    test.end()
}

