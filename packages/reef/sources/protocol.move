module reef::protocol {
    use std::type_name::{Self, TypeName};


    use sui::coin::Coin;
    use sui::dynamic_field;
    use sui::balance::Balance;
    use sui::vec_map::{Self, VecMap};
    use sui::vec_set::{Self, VecSet};
    use sui::package::{Self, Publisher};

    const EInvalidPublisher: u64 = 0;
    const EBondTypeNotAllowed: u64 = 1;

    public struct PROTOCOL() has drop;

    public struct Protocol has key {
        id: UID,
        resolver_proofs: VecSet<TypeName>,
        fee_amounts: VecMap<TypeName, u64>,
        allowed_coin_types: VecSet<TypeName>,
        minimum_bond_map: VecMap<TypeName, u64>,
    }

    public struct ProtocolCap has key {
        id: UID,
    }

    public struct FeeKey(TypeName) has copy, store, drop;

    fun init(p: PROTOCOL, ctx: &mut TxContext) {
        package::claim_and_keep(p, ctx);
    }

   public fun initialize(publisher: Publisher, ctx: &mut TxContext): (Protocol, ProtocolCap) {
        assert!(publisher.from_module<PROTOCOL>(), EInvalidPublisher);

        let protocol = Protocol {
            id: object::new(ctx),
            fee_amounts: vec_map::empty(),
            resolver_proofs: vec_set::empty(),
            minimum_bond_map: vec_map::empty(),
            allowed_coin_types: vec_set::empty(),
        };
        
        publisher.burn();
        (protocol, ProtocolCap { id: object::new(ctx) })
    }

    public fun set_minimum_bond(protocol: &mut Protocol, _: &ProtocolCap, coin_type: TypeName, minimum_bond: u64) {
        assert!(protocol.is_allowed_coin_type(coin_type), EBondTypeNotAllowed);

        if (!protocol.minimum_bond_map.contains(&coin_type)) {
            protocol.minimum_bond_map.insert(coin_type, minimum_bond);
        } else {
            let current_minimum = &mut protocol.minimum_bond_map[&coin_type];
            *current_minimum = minimum_bond;
        }
    }

    public fun set_fee_amount(protocol: &mut Protocol, _: &ProtocolCap, fee_type: TypeName, fee_amount: u64) {
        if (!protocol.fee_amounts.contains(&fee_type)) {
            protocol.fee_amounts.insert(fee_type, fee_amount);
        } else {
            let current_minimum = &mut protocol.fee_amounts[&fee_type];
            *current_minimum = fee_amount;
        }
    }

    public(package) fun collect_fee<CoinType>(protocol: &mut Protocol, fee: Coin<CoinType>) {
        let fee_key = FeeKey(type_name::get<CoinType>());
        if (!dynamic_field::exists_(&mut protocol.id, fee_key)) {
            dynamic_field::add(&mut protocol.id, fee_key, fee.into_balance());
        } else {
            let fee_balance = dynamic_field::borrow_mut<FeeKey, Balance<CoinType>>(&mut protocol.id, fee_key);
            fee_balance.join(fee.into_balance());
        }
    }

    /// Adds a new resolver proof type to the protocol.
    /// This allows the system to recognize and validate resolutions for claims and challenges.
    public fun add_resolver_proof(protocol: &mut Protocol, _: &ProtocolCap, resolver_proof: TypeName) {
        protocol.resolver_proofs.insert(resolver_proof);
    }

    /// Removes a resolver proof type from the protocol.
    /// This is used to clean up resolver proofs that are no longer valid or needed.
    public fun remove_resolver_proof(protocol: &mut Protocol, _: &ProtocolCap, resolver_proof: TypeName) {
        protocol.resolver_proofs.remove(&resolver_proof);
    }

    /// Adds a new allowed reward type to the protocol.
    /// This allows the system to recognize and accept rewards of this type for queries.
    public fun add_allowed_coin_type(protocol: &mut Protocol, _: &ProtocolCap, reward_type: TypeName) {
        protocol.allowed_coin_types.insert(reward_type);
    }

    /// Removes an allowed reward type from the protocol.
    /// This is used to clean up reward types that are no longer valid or needed.
    public fun remove_allowed_coin_type(protocol: &mut Protocol, _: &ProtocolCap, reward_type: TypeName) {
        protocol.allowed_coin_types.remove(&reward_type);
    }

    // === View Functions ===

    /// Checks if the given resolver proof type is recognized by the protocol.
    public fun is_resolver_proof(protocol: &Protocol, resolver_proof: TypeName): bool {
        protocol.resolver_proofs.contains(&resolver_proof)
    }

    /// Checks if the given reward type is allowed in the system.
    public fun is_allowed_coin_type(protocol: &Protocol, reward_type: TypeName): bool {
        protocol.allowed_coin_types.contains(&reward_type)
    }

    /// Retrieves the minimum bond amount required for a specific coin type.
    public fun minimum_bond(protocol: &Protocol, coin_type: TypeName): u64 {
        protocol.minimum_bond_map[&coin_type]
    }

    /// Retrieves the fee amount for a specific coin type.
    public fun fee_amount(protocol: &Protocol, coin_type: TypeName): u64 {
        protocol.fee_amounts[&coin_type]
    }
}