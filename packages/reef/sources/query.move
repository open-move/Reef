module reef::query {
    use std::type_name::{Self, TypeName};

    use sui::clock::Clock;
    use sui::dynamic_field;
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};

    use reef::protocol::Protocol;
    use reef::protocol;

    const EInsufficientBond: u64 = 0;
    const EInvalidQueryStatus: u64 = 1;
    const ELivenessNotExpired: u64 = 3;
    const ENotAuthorized: u64 = 5;
    const EInvalidCoinType: u64 = 6;
    const EInvalidLiveness: u64 = 9;
    const EEmptyTopic: u64 = 10;
    const EEmptyMessage: u64 = 10;
    const EClaimNotSubmitted: u64 = 12;
    const EInvalidResolverProofType: u64 = 14;
    const EInsufficientFeeAmount: u64 = 15;

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

        bond_amount: u64,
        coin_type: TypeName,
        
        /// The address of the claim submitter
        submitter: Option<address>,
        submitted_claim: Option<vector<u8>>,
        submission_time_ms: Option<u64>,
        
        /// The address of the challenger
        challenger: Option<address>,
        challenge_time_ms: Option<u64>,
        
        /// The status of the query
        status: QueryStatus,

        /// The claim that is finalized after resolution
        resolved_claim: Option<vector<u8>>,
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

    public fun submit_query<CoinType>(
        protocol: &mut Protocol,
        fee: Coin<CoinType>,
        bond_amount: u64,
        topic: vector<u8>,
        metadata: vector<u8>,
        liveness_ms: u64,
        ctx: &mut TxContext
    ): Query {
        let coin_type = type_name::get<CoinType>();

        assert!(liveness_ms > 0, EInvalidLiveness);
        assert!(vector::length(&topic) > 0, EEmptyTopic);
        assert!(vector::length(&metadata) > 0, EEmptyMessage);
        assert!(protocol.is_allowed_coin_type(coin_type), EInvalidCoinType);
        assert!(bond_amount >= protocol.minimum_bond(coin_type), EInsufficientBond);
        assert!(fee.value() >= protocol.fee_amount(coin_type), EInsufficientFeeAmount);

        protocol.collect_fee(fee);

        Query {
            id: object::new(ctx),
            creator: ctx.sender(),

            topic,
            metadata,
            liveness_ms,

            coin_type,
            bond_amount,
            
            submitter: option::none(),
            submitted_claim: option::none(),
            submission_time_ms: option::none(),
            
            challenger: option::none(),
            challenge_time_ms: option::none(),

            resolved_claim: option::none(),
            status: QueryStatus::Requested,
        }
    }

    public fun submit_claim<CoinType>(query: &mut Query, claim: vector<u8>, bond: Coin<CoinType>, clock: &Clock, ctx: &mut TxContext) {
        assert!(query.coin_type == type_name::get<CoinType>(), EInvalidCoinType);
        assert!(query.status == QueryStatus::Requested, EInvalidQueryStatus);
        assert!(bond.value() >= query.bond_amount, EInsufficientBond);

        query.collect_bond(bond);

        query.submission_time_ms.fill(clock.timestamp_ms());
        query.submitter.fill(ctx.sender());
        query.submitted_claim.fill(claim);

        query.status = QueryStatus::Submitted;
    }

    public fun challenge_claim<CoinType>(query: &mut Query, bond: Coin<CoinType>, clock: &Clock, ctx: &mut TxContext) {
        assert!(query.status == QueryStatus::Submitted, EInvalidQueryStatus);
        assert!(query.submission_time_ms.is_some(), EClaimNotSubmitted);
        
        let current_time_ms = clock.timestamp_ms();
        let elapsed_time_ms = current_time_ms - *query.submission_time_ms.borrow();
        assert!(elapsed_time_ms < query.liveness_ms, ELivenessNotExpired);
        
        query.collect_bond(bond);

        query.challenge_time_ms.fill(current_time_ms);
        query.challenger.fill(ctx.sender());

        query.status = QueryStatus::Challenged;
    }

    public fun resolve_query<CoinType>(
        query: &mut Query,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let proof_type_name = type_name::get<Proof>();
        assert!(query.resolver_proof == proof_type_name, EInvalidResolverProofType);
        
        if (query.status == QueryStatus::Submitted) {
            // Unchallenged resolution - submitter wins after liveness period
            let current_time_ms = clock.timestamp_ms();
            let submission_time_ms = *query.submission_time_ms.borrow();
            let elapsed_time_ms = current_time_ms - submission_time_ms;
            assert!(elapsed_time_ms >= query.liveness_ms, ELivenessNotExpired);

            // Accept submitted claim as final
            query.resolved_claim = query.submitted_claim;
            
            // Pay out all bonds to submitter (creator bond + submitter bond)
            let bond_balance = dynamic_field::remove<BondKey, Balance<Bond>>(&mut query.id, BondKey());
            let payout_coin = coin::from_balance(bond_balance, ctx);
            let submitter_addr = *query.submitter.borrow();
            transfer::public_transfer(payout_coin, submitter_addr);
            
            // Handle reward if it exists - goes to submitter
            if (query.reward_type.is_some() && type_name::get<Reward>() == *query.reward_type.borrow()) {
                if (dynamic_field::exists_(&query.id, RewardKey())) {
                    let reward_balance = dynamic_field::remove<RewardKey, Balance<Reward>>(&mut query.id, RewardKey());
                    let reward_coin = coin::from_balance(reward_balance, ctx);
                    transfer::public_transfer(reward_coin, submitter_addr);
                };
            };
            
        } else if (query.status == QueryStatus::Challenged) {
            // Disputed resolution - resolver decides winner
            assert!(query.submitted_claim.is_some(), EClaimNotSubmitted);
            assert!(query.challenger.is_some(), ENotAuthorized);
            
            let submitter_addr = *query.submitter.borrow();
            let challenger_addr = *query.challenger.borrow();
            let submitted_claim = *query.submitted_claim.borrow();
            
            // Determine winner by comparing resolver claim to submitted claim
            let submitter_wins = if (resolver_claim.is_some()) {
                let resolver_claim = *resolver_claim.borrow();
                // Submitter wins if resolver claim matches their submitted claim
                submitted_claim == resolver_claim
            } else {
                // If no resolver claim provided, challenger wins (submitted claim is invalid)
                false
            };
            
            if (submitter_wins) {
                // Submitter wins: gets all bonds (creator + submitter + challenger)
                query.resolved_claim = query.submitted_claim;
                let bond_balance = dynamic_field::remove<BondKey, Balance<Bond>>(&mut query.id, BondKey());
                let payout_coin = coin::from_balance(bond_balance, ctx);
                transfer::public_transfer(payout_coin, submitter_addr);
                
                // Submitter also gets reward if it exists
                if (query.reward_type.is_some() && type_name::get<Reward>() == *query.reward_type.borrow()) {
                    if (dynamic_field::exists_(&query.id, RewardKey())) {
                        let reward_balance = dynamic_field::remove<RewardKey, Balance<Reward>>(&mut query.id, RewardKey());
                        let reward_coin = coin::from_balance(reward_balance, ctx);
                        transfer::public_transfer(reward_coin, submitter_addr);
                    };
                };
            } else {
                // Challenger wins: submitted claim was wrong, resolver claim becomes final
                query.resolved_claim = resolver_claim;
                let bond_balance = dynamic_field::remove<BondKey, Balance<Bond>>(&mut query.id, BondKey());
                let payout_coin = coin::from_balance(bond_balance, ctx);
                transfer::public_transfer(payout_coin, challenger_addr);
                
                // Creator gets reward back if it exists (challenger doesn't get reward)
                if (query.reward_type.is_some() && type_name::get<Reward>() == *query.reward_type.borrow()) {
                    if (dynamic_field::exists_(&query.id, RewardKey())) {
                        let reward_balance = dynamic_field::remove<RewardKey, Balance<Reward>>(&mut query.id, RewardKey());
                        let reward_coin = coin::from_balance(reward_balance, ctx);
                        transfer::public_transfer(reward_coin, query.creator);
                    };
                };
            };
            
        } else {
            abort EInvalidQueryStatus
        };
        
        query.status = QueryStatus::Resolved;
    }

    public fun add_reward<Reward>(query: &mut Query, reward: Coin<Reward>, _ctx: &mut TxContext) {
        let reward_type = type_name::get<Reward>();
        assert!(query.status == QueryStatus::Requested, EInvalidQueryStatus);
        
        // Initialize reward storage if it doesn't exist
        if (!dynamic_field::exists_(&query.id, RewardKey())) {
            dynamic_field::add(&mut query.id, RewardKey(), balance::zero<Reward>());
        };
        
        let reward_balance = dynamic_field::borrow_mut<RewardKey, Balance<Reward>>(&mut query.id, RewardKey());
        reward_balance.join(reward.into_balance());
        
        query.reward_type.fill(reward_type);
    }

    fun collect_bond<CoinType>(query: &mut Query, bond: Coin<CoinType>) {
        let bond_key = BondKey();
        if (!dynamic_field::exists_(&mut query.id, bond_key)) {
            dynamic_field::add(&mut query.id, bond_key, bond.into_balance());
        } else {
            let bond_balance = dynamic_field::borrow_mut<BondKey, Balance<CoinType>>(&mut query.id, bond_key);
            bond_balance.join(bond.into_balance());
        }
    }

    // === Getter Functions ===
    
    public fun status(query: &Query): QueryStatus {
        query.status
    }
    
    public fun creator(query: &Query): address {
        query.creator
    }
    
    public fun topic(query: &Query): vector<u8> {
        query.topic
    }
    
    public fun metadata(query: &Query): vector<u8> {
        query.metadata
    }
    
    
    public fun liveness_ms(query: &Query): u64 {
        query.liveness_ms
    }
    
    public fun bond_type(query: &Query): TypeName {
        query.bond_type
    }
    
    public fun reward_type(query: &Query): Option<TypeName> {
        query.reward_type
    }
    
    public fun submitter(query: &Query): Option<address> {
        query.submitter
    }
    
    public fun submitted_claim(query: &Query): Option<vector<u8>> {
        query.submitted_claim
    }
    
    public fun submission_time_ms(query: &Query): Option<u64> {
        query.submission_time_ms
    }
    
    public fun challenger(query: &Query): Option<address> {
        query.challenger
    }
    
    public fun challenge_time_ms(query: &Query): Option<u64> {
        query.challenge_time_ms
    }
    
    public fun resolver_proof(query: &Query): TypeName {
        query.resolver_proof
    }
    
    public fun resolved_claim(query: &Query): Option<vector<u8>> {
        query.resolved_claim
    }
    
    public fun bond_amount<Bond>(query: &Query): u64 {
        if (dynamic_field::exists_(&query.id, BondKey())) {
            let bond_balance = dynamic_field::borrow<BondKey, Balance<Bond>>(&query.id, BondKey());
            bond_balance.value()
        } else {
            0
        }
    }
    
    public fun reward_amount<Reward>(query: &Query): u64 {
        if (dynamic_field::exists_(&query.id, RewardKey())) {
            let reward_balance = dynamic_field::borrow<RewardKey, Balance<Reward>>(&query.id, RewardKey());
            reward_balance.value()
        } else {
            0
        }
    }
}