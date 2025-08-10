#[test_only]
module reef::dummy_creator;

use reef::callback::{ClaimSubmitted, ClaimChallenged, QuerySettled};
use std::type_name;

public struct DummyCreator() has drop;

public struct CreatorState has key, store {
    id: UID,
}

public fun create_creator_state(ctx: &mut TxContext): CreatorState {
    CreatorState {
        id: object::new(ctx)
    }
}

public fun handle_claim_submitted(callback: ClaimSubmitted) {
    callback.verify_claim_submitted(DummyCreator());
}

public fun handle_claim_challenged(callback: ClaimChallenged) {
    callback.verify_claim_challenged(DummyCreator());
}

public fun handle_query_settled(callback: QuerySettled) {
    callback.verify_query_settled(DummyCreator());
}

// public fun verify_claim_submitted_callback(callback: &ClaimSubmitted): bool {
//     callback::claim_submitted_creator_witness(callback) == type_name::get<DummyCreator>()
// }

// public fun verify_claim_challenged_callback(callback: &ClaimChallenged): bool {
//     callback::claim_challenged_creator_witness(callback) == type_name::get<DummyCreator>()
// }

// public fun verify_query_settled_callback(callback: &QuerySettled): bool {
//     callback::query_settled_creator_witness(callback) == type_name::get<DummyCreator>()
// }

// public fun get_submitted_claims_count(state: &CreatorState): u64 {
//     state.claims_submitted.length()
// }

// public fun get_challenged_claims_count(state: &CreatorState): u64 {
//     state.claims_challenged.length()
// }

// public fun get_settled_queries_count(state: &CreatorState): u64 {
//     state.queries_settled_ids.length()
// }

// public fun get_last_claim_submitted(state: &CreatorState): &ClaimSubmitted {
//     let len = state.claims_submitted.length();
//     assert!(len > 0, 0);
//     &state.claims_submitted[len - 1]
// }

// public fun get_last_claim_challenged(state: &CreatorState): &ClaimChallenged {
//     let len = state.claims_challenged.length();
//     assert!(len > 0, 0);
//     &state.claims_challenged[len - 1]
// }

// public fun get_last_query_settled(state: &CreatorState): &QuerySettled {
//     let len = state.queries_settled_ids.length();
//     assert!(len > 0, 0);
//     &state.queries_settled_ids[len - 1]
// }

public fun get_creator_type(): std::type_name::TypeName {
    type_name::get<DummyCreator>()
}

public fun make_witness(): DummyCreator {
    DummyCreator()
}
