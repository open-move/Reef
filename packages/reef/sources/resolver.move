module reef::resolver {
    use std::option::{Self, Option};
    use std::type_name;

    use reef::config::Config;
    use reef::query::{Query, QueryStatus};
    use reef::claim::{Self, Claim, ClaimType};

    public struct Resolution<Proof: drop + store> {
        query_id: ID,
        proof: Option<Proof>,
        claim: Option<Claim>
    }

    const EInvalidQueryID: u64 = 0;
    const EInvalidResolver: u64 = 1;

    public fun new_resolver_request<Proof: drop + store>(query: &Query): Resolution<Proof> {
        Resolution {
            claim: option::none(),
            proof: option::none(),
            query_id: object::id(query)
        }
    }

    // public fun add<Proof: drop + store>(request: &mut Resolution<Proof>, proof: Proof, claim: Claim) {
    //     // assert!(object::id(query) == request.query_id, EInvalidQueryID);

    //     // let type_name = type_name::get<Proof>();
    //     // assert!(config.is_valid_resolver(type_name.get_address()), EInvalidResolver);

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