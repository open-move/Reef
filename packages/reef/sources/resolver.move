module reef::resolver {
    use std::option::{Self, Option};
    use std::type_name;

    use reef::protocol::Protocol;
    use reef::query::{Query, QueryStatus};

    public struct Resolution<Proof: drop + store> has key {
        id: UID,
        query_id: ID,
        claim: vector<u8>,
        proof: Option<Proof>
    }

    

    const EInvalidQueryID: u64 = 0;
    const EInvalidResolver: u64 = 1;


    // public fun add<Proof: drop + store>(request: &mut Resolution<Proof>, proof: Proof, claim: Claim) {
    //     // assert!(object::id(query) == request.query_id, EInvalidQueryID);

    //     // let type_name = type_name::get<Proof>();
    //     // assert!(protocol.is_valid_resolver(type_name.get_address()), EInvalidResolver);

    //     // Add the proof to the resolver request
    //     request.proof.fill(proof);
    //     request.claim.fill(claim);
    // }

    // public fun verify_proof<Proof: drop + store>(
    //     request: &Resolution<Proof>,
    //     query: &Query,
    // ): bool {
    //     // Check if the proof is valid for the given query ID
    //     assert!(request.query_id != ID::zero(), EInvalidQueryID);

    //     // Verify the resolver type and proof
    //     let type_name = type_name::get<Proof>();
    //     let resolver_proof_type =

    //     // Additional verification logic can be added here

    //     true // Return true if the proof is valid
    // }
}