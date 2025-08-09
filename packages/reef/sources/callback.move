/// This module provides a way for query creators to get notified when important events happen to queries they created.
///
/// The callback system allows query creator:
/// 1. Get notified when someone submits a claim to their query
/// 2. Get notified when someone challenges that claim
/// 3. Get notified when the query is finally settled
/// 4. Verify that callbacks have been received and the witness match
///
/// The verification functions prevent callback spoofing by checking that the
/// callback came from a query created with the right witness type.
module reef::callback;

use std::type_name::{Self, TypeName};

/// Invalid callback type
const EInvalidCallbackType: u64 = 0;

/// Notification that someone submitted a claim to a query.
///
/// This gets returned when someone calls the submit_claim_with_callback function.
public struct ClaimSubmitted {
    query_id: ID,
    submitter: address,
    claim: vector<u8>,
    creator_witness: TypeName,
}

/// Notification that someone challenged a claim to a query.
///
/// This means a challenge has created a dispute and the query will need to be
/// resolved by a resolver.
public struct ClaimChallenged {
    query_id: ID,
    challenger: address,
    creator_witness: TypeName,
}

/// Notification that a query has reached its final state.
///
/// The means the oracle process is complete, bonds have been
/// distributed, and we now know the resolved claim.
public struct QuerySettled {
    query_id: ID,
    claim: vector<u8>,
    creator_witness: TypeName,
}

public(package) fun new_claim_submitted(
    query_id: ID,
    submitter: address,
    claim: vector<u8>,
    creator_witness: TypeName,
): ClaimSubmitted {
    ClaimSubmitted {
        creator_witness,
        query_id,
        submitter,
        claim,
    }
}

public(package) fun new_claim_challenged(
    query_id: ID,
    challenger: address,
    creator_witness: TypeName,
): ClaimChallenged {
    ClaimChallenged {
        query_id,
        creator_witness,
        challenger,
    }
}

public(package) fun new_query_settled(
    query_id: ID,
    claim: vector<u8>,
    creator_witness: TypeName,
): QuerySettled {
    QuerySettled {
        query_id,
        creator_witness,
        claim,
    }
}

public fun verify_claim_submitted<T: drop>(callback: ClaimSubmitted, _: T) {
    let ClaimSubmitted { creator_witness, .. } = callback;
    assert!(creator_witness == type_name::get<T>(), EInvalidCallbackType);
}

public fun verify_claim_challenged<T: drop>(callback: ClaimChallenged, _: T) {
    let ClaimChallenged { creator_witness, .. } = callback;
    assert!(creator_witness == type_name::get<T>(), EInvalidCallbackType);
}

public fun verify_query_settled<T: drop>(callback: QuerySettled, _: T) {
    let QuerySettled { creator_witness, .. } = callback;
    assert!(creator_witness == type_name::get<T>(), EInvalidCallbackType);
}