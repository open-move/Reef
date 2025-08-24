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

public fun get_creator_type(): std::type_name::TypeName {
    type_name::get<DummyCreator>()
}

public fun make_witness(): DummyCreator {
    DummyCreator()
}
