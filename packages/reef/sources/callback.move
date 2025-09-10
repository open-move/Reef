module reef::callback;

use std::type_name::{Self, TypeName};

const EInvalidCallbackType: u64 = 0;

public struct DataProposed {
    query_id: ID,
    data: vector<u8>,
    submitter: address,
    creator_witness: TypeName,
}

public struct ProposalDisputed {
    query_id: ID,
    disputer: address,
    creator_witness: TypeName,
}

public struct QuerySettled {
    query_id: ID,
    data: vector<u8>,
    creator_witness: TypeName,
}

public(package) fun new_data_proposed(
    query_id: ID,
    submitter: address,
    data: vector<u8>,
    creator_witness: TypeName,
): DataProposed {
    DataProposed {
        creator_witness,
        query_id,
        submitter,
        data,
    }
}

public(package) fun new_proposal_disputed(
    query_id: ID,
    disputer: address,
    creator_witness: TypeName,
): ProposalDisputed {
    ProposalDisputed {
        query_id,
        creator_witness,
        disputer,
    }
}

public(package) fun new_query_settled(
    query_id: ID,
    data: vector<u8>,
    creator_witness: TypeName,
): QuerySettled {
    QuerySettled {
        query_id,
        creator_witness,
        data,
    }
}

public fun verify_data_proposed<T: drop>(callback: DataProposed, _: T) {
    let DataProposed { creator_witness, .. } = callback;
    assert!(creator_witness == type_name::with_defining_ids<T>(), EInvalidCallbackType);
}

public fun verify_proposal_disputed<T: drop>(callback: ProposalDisputed, _: T) {
    let ProposalDisputed { creator_witness, .. } = callback;
    assert!(creator_witness == type_name::with_defining_ids<T>(), EInvalidCallbackType);
}

public fun verify_query_settled<T: drop>(callback: QuerySettled, _: T) {
    let QuerySettled { creator_witness, .. } = callback;
    assert!(creator_witness == type_name::with_defining_ids<T>(), EInvalidCallbackType);
}

public fun settled_data(callback: &QuerySettled): vector<u8> {
    callback.data
}

public fun settled_query_id(callback: &QuerySettled): ID {
    callback.query_id
}