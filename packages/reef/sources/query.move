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
    const EQueryNotFound: u64 = 2;
    const ELivenessNotExpired: u64 = 3;
    const EAlreadyClaimed: u64 = 4;
    const ENotAuthorized: u64 = 5;
    const EInvalidClaimType: u64 = 6;
    const EInvalidCommitHash: u64 = 7;
    const ERevealPeriodExpired: u64 = 8;
    const EInvalidLiveness: u64 = 9;
    const EInvalidQueryID: u64 = 10;
    const EInvalidResolver: u64 = 11;
    const EClaimNotSubmitted: u64 = 12;
    const EInvalidBondState: u64 = 13;
    const EInvalidResolverProofType: u64 = 14;

    // use fun get_claim_data as Claim.data;

    public struct Query has key {
        id: UID,
        creator: address,
        identifier: vector<u8>,
        
        liveness_ms: u64,
        claim_type: ClaimType,

        bond_type_name: TypeName,
        reward_type_name: TypeName, 
        
        commit_mode: bool,
        commit_hash: Option<vector<u8>>,
        
        submitter: Option<address>,
        submitted_claim: Option<Claim>,
        submission_time_ms: Option<u64>,
        
        challenger: Option<address>,
        challenge_time_ms: Option<u64>,
        
        // validator: Option<address>,
        resolver_proof_type: TypeName,
        
        final_claim: Option<Claim>,
        status: QueryStatus,
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

    public fun submit_query<Bond, Reward>(
        config: &Config,
        identifier: vector<u8>,
        claim_type: ClaimType,
        liveness_ms: u64,
        bond: Coin<Bond>,
        reward: Option<Coin<Reward>>,
        resolver_proof_type: TypeName,
        ctx: &mut TxContext,
    ): Query {
        let bond_type_name = type_name::get<Bond>();
        let reward_type_name = type_name::get<Reward>();

        assert!(liveness_ms > 0, EInvalidLiveness);
        assert!(vector::length(&identifier) > 0, EInvalidQueryID);
        assert!(bond.value() >= config.get_minimum_bond(reward_type_name), EInsufficientBond);
        
        let mut query = Query {
            id: object::new(ctx),
            creator: ctx.sender(),

            identifier,
            claim_type,
            liveness_ms,

            bond_type_name,
            reward_type_name,
            
            commit_mode: true,
            commit_hash: option::none(),
            
            submitter: option::none(),
            submitted_claim: option::none(),
            submission_time_ms: option::none(),
            
            challenger: option::none(),
            challenge_time_ms: option::none(),

            resolver_proof_type,

            final_claim: option::none(),
            status: QueryStatus::Requested,
        };

        dynamic_field::add(&mut query.id, BondKey(), bond.into_balance());
        reward.do!(|r| {
            assert!(r.value() > 0, EInsufficientBond);
            dynamic_field::add(&mut query.id, RewardKey(), r.into_balance());
        });

        query
    }

    public fun get_resolver_proof_type(query: &Query): TypeName {
        query.resolver_proof_type
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
        
        // let bond_amount = coin::value(&bond);
        // let required_bond = balance::value(&query.bond);
        // assert!(bond_amount >= required_bond, EInsufficientBond);
        
        bond.destroy_zero();

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