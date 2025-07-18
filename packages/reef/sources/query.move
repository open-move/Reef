module reef::query {
    use std::vector;
    use std::option::{Self, Option};
    use std::string::{Self, String};
    use std::type_name::{Self, TypeName};

    use sui::bcs;
    use sui::dynamic_field;
    use sui::coin::{Self, Coin};
    use sui::clock::{Self, Clock};
    use sui::balance::{Self, Balance};

    use reef::claim::{Self, Claim, ClaimType};
    use reef::config::{Self, Config};

    const EInsufficientBond: u64 = 0;
    const EInvalidQueryStatus: u64 = 1;
    const ELivenessNotExpired: u64 = 3;
    const ENotAuthorized: u64 = 5;
    const EInvalidClaimType: u64 = 6;
    const EInvalidLiveness: u64 = 9;
    const EEmptyTopic: u64 = 10;
    const EEmptyMessage: u64 = 10;
    const EClaimNotSubmitted: u64 = 12;
    const EInvalidResolverProofType: u64 = 14;
    const EInvalidBondType: u64 = 15;

    // use fun get_claim_data as Claim.data;

    public struct Query has key {
        id: UID,
        /// The address of the creator of the query
        creator: address,
        /// The query topic, may be useful for indentifications and offchain processing
        topic: vector<u8>,
        /// The query metadata, which contains more data about the query
        metadata: vector<u8>,
        /// The liveness period in milliseconds
        liveness_ms: u64,
        /// The claim type of the query
        claim_type: ClaimType,

        bond_type_name: TypeName,
        reward_type_name: Option<TypeName>, 
        
        /// The address of the claim submitter
        submitter: Option<address>,
        submitted_claim: Option<Claim>,
        submission_time_ms: Option<u64>,
        
        /// The address of the challenger
        challenger: Option<address>,
        challenge_time_ms: Option<u64>,
        
        /// The expected resolver proof
        resolver_proof: TypeName,
        
        /// The status of the query
        status: QueryStatus,

        /// The claim that is finalized after resolution
        resolved_claim: Option<Claim>,
    }

    public enum QueryStatus has copy, store, drop {
        Requested,
        Submitted,
        Committed,
        Challenged,
        Resolved,
    }


    public struct BondKey() has copy, store, drop;
    public struct RewardKey() has copy, store, drop;
    public struct ChallengeKey() has copy, store, drop;

    public fun submit_query<Bond, Proof: drop>(
        config: &Config,
        topic: vector<u8>,
        metadata: vector<u8>,
        claim_type: ClaimType,
        bond_amount: u64,
        liveness_ms: u64,
        ctx: &mut TxContext,
    ): Query {
        let creator = ctx.sender();
        let bond_type_name = type_name::get<Bond>();
        let resolver_proof = type_name::get<Proof>();

        assert!(liveness_ms > 0, EInvalidLiveness);
        assert!(vector::length(&topic) > 0, EEmptyTopic);
        assert!(vector::length(&metadata) > 0, EEmptyMessage);
        assert!(config.is_allowed_bond_type(bond_type_name), EInvalidBondType);
        assert!(config.is_resolver_proof(resolver_proof), EInvalidResolverProofType);
        assert!(bond_amount >= config.get_minimum_bond(bond_type_name), EInsufficientBond);

        Query {
            id: object::new(ctx),
            creator,

            topic,
            metadata,
            claim_type,
            liveness_ms,

            bond_type_name,
            reward_type_name: option::none(),
            
            submitter: option::none(),
            submitted_claim: option::none(),
            submission_time_ms: option::none(),
            
            challenger: option::none(),
            challenge_time_ms: option::none(),

            resolver_proof,

            resolved_claim: option::none(),
            status: QueryStatus::Requested,
        }
    }

    public fun submit_claim<Bond>(query: &mut Query, claim: Claim, bond: Coin<Bond>, clock: &Clock, ctx: &mut TxContext) {
        assert!(query.bond_type_name == type_name::get<Bond>(), EInvalidClaimType);
        assert!(query.status == QueryStatus::Requested, EInvalidQueryStatus);
        assert!(claim.type_() == query.claim_type, EInvalidClaimType);

        query.validate_and_collect_bond(bond, ctx);

        query.submission_time_ms.fill(clock.timestamp_ms());
        query.submitter.fill(ctx.sender());
        query.submitted_claim.fill(claim);

        query.status = QueryStatus::Submitted;
    }

    public fun challenge_claim<Bond>(query: &mut Query, bond: Coin<Bond>, clock: &Clock, ctx: &mut TxContext) {
        assert!(query.status == QueryStatus::Submitted, EInvalidQueryStatus);
        assert!(query.submission_time_ms.is_some(), EClaimNotSubmitted);
        
        let current_time_ms = clock.timestamp_ms();
        let elapsed_time_ms = current_time_ms - *query.submission_time_ms.borrow();
        assert!(elapsed_time_ms >= query.liveness_ms, ELivenessNotExpired);
        
        query.validate_and_collect_bond(bond, ctx);

        query.challenge_time_ms.fill(current_time_ms);
        query.challenger.fill(ctx.sender());

        query.status = QueryStatus::Challenged;
    }

    public fun resolve_query<Bond, Reward, Proof: drop>(query: &mut Query, proof: Proof, clock: &Clock) {
        if (query.status == QueryStatus::Submitted) { // Submitted
            let current_time_ms = clock.timestamp_ms();
            let submission_time_ms = *query.submission_time_ms.borrow();
            let elapsed_time_ms = current_time_ms - submission_time_ms;
            assert!(elapsed_time_ms >= query.liveness_ms, ELivenessNotExpired);

            // TODO: Validate claim type against query claim type
            // And also send the bond and reward to the submitter
            
            query.final_claim = query.submitted_claim;
            query.status = QueryStatus::Resolved;
        } else if (query.status == QueryStatus::Challenged) { // Challenged
            // Delegate to resolver - this will be handled by resolver modules
            // For now, just mark as resolved
            assert!(query.submitted_claim.is_some(), EClaimNotSubmitted);
            assert!(query.challenger.is_some(), ENotAuthorized);
            let proof_type_name = type_name::get<Proof>();
            assert!(query.resolver_proof_type == proof_type_name, EInvalidResolverProofType);
            
            query.status = QueryStatus::Resolved;
        } else {
            abort EInvalidQueryStatus
        }
    }

    fun validate_and_collect_bond<Bond>(query: &mut Query, bond: Coin<Bond>, ctx: &mut TxContext): u64 {
        assert!(query.bond_type_name == type_name::get<Bond>(), EInvalidClaimType);

        let bond_balance = dynamic_field::borrow_mut<BondKey, Balance<Bond>>(&mut query.id, BondKey());
        assert!(bond.value() >= bond_balance.value(), EInsufficientBond);

        bond_balance.join(bond.into_balance());
        bond_balance.value()
    }
}