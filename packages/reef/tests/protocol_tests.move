#[test_only]
module reef::protocol_tests;

use reef::protocol::{Self, Protocol, ProtocolCap};
use reef::test;
use reef::test_utils::{admin, USDC};
use std::type_name;
use std::unit_test::assert_eq;
use sui::sui::SUI;
use sui::test_scenario;

public struct PROTOCOL_TESTS() has drop;
public struct ETH() has drop;
public struct SimpleResolver() has drop;
public struct CommitteeResolver() has drop;

#[test]
fun protocol_initialization() {
    let mut test = test::begin(admin!());
    let scenario = test.scenario();

    scenario.next_tx(admin!());
    {
        let (protocol, cap) = protocol::initialize_for_testing(scenario.ctx());

        assert_eq!(protocol.burn_rate_bps(), protocol::default_burn_rate!());
        assert_eq!(protocol.minimum_liveness_ms(), protocol::default_minimum_liveness_ms!());
        assert_eq!(
            protocol.minimum_submission_delay_ms(),
            protocol::default_minimum_submission_delay_ms!(),
        );

        protocol.share_protocol();
        cap.transfer_protocol_cap(admin!());
    };

    test.end()
}

#[test]
fun burn_rate_management() {
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

        // Test setting valid burn rate
        protocol.set_burn_rate(&cap, 2500); // 25%
        assert_eq!(protocol.burn_rate_bps(), 2500);

        // Test setting maximum burn rate
        protocol.set_burn_rate(&cap, 10000); // 100%
        assert_eq!(protocol.burn_rate_bps(), 10000);

        // Test setting zero burn rate
        protocol.set_burn_rate(&cap, 0);
        assert_eq!(protocol.burn_rate_bps(), 0);

        test_scenario::return_shared(protocol);
        scenario.return_to_sender(cap);
    };

    test.end()
}

#[test, expected_failure(abort_code = reef::protocol::EInvalidBurnRate)]
fun burn_rate_validation() {
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

        protocol.set_burn_rate(&cap, 10001); // > 100%, should fail

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
fun fee_management() {
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

        // Set fee amounts
        protocol.set_fee_amount(&cap, usdc_type, 1000000); // 1 USDC
        protocol.set_fee_amount(&cap, sui_type, 100000000); // 0.1 SUI

        assert_eq!(protocol.fee_amount(usdc_type), 1000000);
        assert_eq!(protocol.fee_amount(sui_type), 100000000);

        // Update existing fee
        protocol.set_fee_amount(&cap, usdc_type, 2000000); // 2 USDC
        assert_eq!(protocol.fee_amount(usdc_type), 2000000);

        test_scenario::return_shared(protocol);
        scenario.return_to_sender(cap);
    };

    test.end()
}

#[test]
fun minimum_bond_management() {
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

        // Set minimum bond
        protocol.set_minimum_bond(&cap, usdc_type, 10000000); // 10 USDC
        assert_eq!(protocol.minimum_bond(usdc_type), 10000000);

        // Update minimum bond
        protocol.set_minimum_bond(&cap, usdc_type, 5000000); // 5 USDC
        assert_eq!(protocol.minimum_bond(usdc_type), 5000000);

        test_scenario::return_shared(protocol);
        scenario.return_to_sender(cap);
    };

    test.end()
}

#[test, expected_failure(abort_code = protocol::EBondTypeNotAllowed)]
fun minimum_bond_unauthorized_coin() {
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

        // Try to set minimum bond without whitelisting coin type first
        protocol.set_minimum_bond(&cap, usdc_type, 10000000);

        test_scenario::return_shared(protocol);
        scenario.return_to_sender(cap);
    };

    test.end()
}
