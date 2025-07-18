module reef::config {
    use std::type_name::TypeName;

    use sui::vec_map::{Self, VecMap};
    use sui::vec_set::{Self, VecSet};
    use sui::package::{Self, Publisher};

    const EInvalidPublisher: u64 = 0;
    const EBondTypeNotAllowed: u64 = 1;

    public struct CONFIG() has drop;

    public struct Config has key {
        id: UID,
        /// The set of resolver proof types that are recognized by the system
        resolver_proofs: VecSet<TypeName>,
        /// The set of allowed bond types for queries
        allowed_bond_types: VecSet<TypeName>,
        /// The set of allowed reward types for queries
        allowed_reward_types: VecSet<TypeName>,
        /// A map of minimum bond amounts for each coin type
        minimum_bond_map: VecMap<TypeName, u64>,
    }

    public struct ConfigCap has key {
        id: UID,
    }

    fun init(c: CONFIG, ctx: &mut TxContext) {
        package::claim_and_keep(c, ctx);
    }

   public fun initialize(publisher: Publisher, ctx: &mut TxContext): (Config, ConfigCap) {
        assert!(publisher.from_module<CONFIG>(), EInvalidPublisher);

        let config = Config {
            id: object::new(ctx),
            resolver_proofs: vec_set::empty(),
            minimum_bond_map: vec_map::empty(),
            allowed_bond_types: vec_set::empty(),
            allowed_reward_types: vec_set::empty(),
        };
        
        publisher.burn();
        (config, ConfigCap { id: object::new(ctx) })
    }

    public fun set_minimum_bond(config: &mut Config, _: &ConfigCap, bond_type: TypeName, minimum_bond: u64) {
        assert!(config.is_allowed_bond_type(bond_type), EBondTypeNotAllowed);

        if (!config.minimum_bond_map.contains(&bond_type)) {
            config.minimum_bond_map.insert(bond_type, minimum_bond);
        } else {
            let current_minimum = &mut config.minimum_bond_map[&bond_type];
            *current_minimum = minimum_bond;
        }
    }

    /// Adds a new resolver proof type to the config.
    /// This allows the system to recognize and validate resolutions for claims and challenges.
    public fun add_resolver_proof(config: &mut Config, _: &ConfigCap, resolver_proof: TypeName) {
        config.resolver_proofs.insert(resolver_proof);
    }

    /// Removes a resolver proof type from the config.
    /// This is used to clean up resolver proofs that are no longer valid or needed.
    public fun remove_resolver_proof(config: &mut Config, _: &ConfigCap, resolver_proof: TypeName) {
        config.resolver_proofs.remove(&resolver_proof);
    }

    /// Adds a new allowed bond type to the config.
    /// This allows the system to recognize and accept transactions involving this bond type.
    public fun add_allowed_bond_type(config: &mut Config, _: &ConfigCap, bond_type: TypeName) {
        config.allowed_bond_types.insert(bond_type);
    }

    /// Removes an allowed bond type from the config.
    /// This is used to clean up bond types that are no longer valid or needed.
    public fun remove_allowed_bond_type(config: &mut Config, _: &ConfigCap, bond_type: TypeName) {
        config.allowed_bond_types.remove(&bond_type);
    }

    /// Adds a new allowed reward type to the config.
    /// This allows the system to recognize and accept rewards of this type for queries.
    public fun add_allowed_reward_type(config: &mut Config, _: &ConfigCap, reward_type: TypeName) {
        config.allowed_reward_types.insert(reward_type);
    }

    /// Removes an allowed reward type from the config.
    /// This is used to clean up reward types that are no longer valid or needed.
    public fun remove_allowed_reward_type(config: &mut Config, _: &ConfigCap, reward_type: TypeName) {
        config.allowed_reward_types.remove(&reward_type);
    }

    // === View Functions ===

    /// Checks if the given resolver proof type is recognized by the config.
    public fun is_resolver_proof(config: &Config, resolver_proof: TypeName): bool {
        config.resolver_proofs.contains(&resolver_proof)
    }

    /// Checks if the given bond type is allowed in the system.
    public fun is_allowed_bond_type(config: &Config, bond_type: TypeName): bool {
        config.allowed_bond_types.contains(&bond_type)
    }

    /// Checks if the given reward type is allowed in the system.
    public fun is_allowed_reward_type(config: &Config, reward_type: TypeName): bool {
        config.allowed_reward_types.contains(&reward_type)
    }

    /// Retrieves the minimum bond amount required for a specific coin type.
    public fun get_minimum_bond(config: &Config, coin_type: TypeName): u64 {
        config.minimum_bond_map[&coin_type]
    }
}