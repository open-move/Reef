module reef::callback;

use std::type_name::{Self, TypeName};

/// Thrown when callback creator witness doesn't match expected type
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

/// Verifies that a DataProposed callback matches the expected creator witness.
/// Ensures the callback originated from the correct query creator before
/// allowing external contract to process the event.
///
/// @param callback DataProposed callback to verify (consumed)
/// @param _witness Expected creator witness type (consumed)
public fun verify_data_proposed<T: drop>(callback: DataProposed, _: T) {
    let DataProposed { creator_witness, .. } = callback;
    assert!(creator_witness == type_name::with_defining_ids<T>(), EInvalidCallbackType);
}

/// Verifies that a ProposalDisputed callback matches the expected creator witness.
/// Ensures the callback originated from the correct query creator before
/// allowing external contract to process the event.
///
/// @param callback ProposalDisputed callback to verify (consumed)
/// @param _witness Expected creator witness type (consumed)
public fun verify_proposal_disputed<T: drop>(callback: ProposalDisputed, _: T) {
    let ProposalDisputed { creator_witness, .. } = callback;
    assert!(creator_witness == type_name::with_defining_ids<T>(), EInvalidCallbackType);
}

/// Verifies that a QuerySettled callback matches the expected creator witness.
/// Ensures the callback originated from the correct query creator before
/// allowing external contract to process the settlement.
///
/// @param callback QuerySettled callback to verify (consumed)
/// @param _witness Expected creator witness type (consumed)
public fun verify_query_settled<T: drop>(callback: QuerySettled, _: T) {
    let QuerySettled { creator_witness, .. } = callback;
    assert!(creator_witness == type_name::with_defining_ids<T>(), EInvalidCallbackType);
}

/// Returns the resolved data from a QuerySettled callback.
///
/// @param callback QuerySettled callback to read from
///
/// @return Final resolved data bytes
public fun settled_data(callback: &QuerySettled): vector<u8> {
    callback.data
}

/// Returns the query ID from a QuerySettled callback.
///
/// @param callback QuerySettled callback to read from
///
/// @return Query object ID
public fun settled_query_id(callback: &QuerySettled): ID {
    callback.query_id
}