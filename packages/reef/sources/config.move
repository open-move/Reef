module reef::config {
    use std::type_name::{Self, TypeName};

    use sui::package::{Self, Publisher};
    use sui::vec_map::{Self, VecMap};
    use sui::vec_set::{Self, VecSet};

    const EInvalidPublisher: u64 = 0;
    const EInvalidMinBond: u64 = 1;
    const EValidatorNotWhitelisted: u64 = 2;

    public struct CONFIG() has drop;

    public struct Config has key {
        id: UID,
        resolvers: VecSet<address>,
        validator_whitelist: vector<address>,
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
            resolvers: vec_set::empty(),
            minimum_bond_map: vec_map::empty(),
            validator_whitelist: vector::empty(),
        };
        
        publisher.burn();
        (config, ConfigCap { id: object::new(ctx) })
    }

    public fun set_minimum_bond(config: &mut Config, _: &ConfigCap, coin_type: TypeName, minimum_bond: u64) {
        assert!(minimum_bond > 0, EInvalidMinBond);
        if (!config.minimum_bond_map.contains(&coin_type)) {
            config.minimum_bond_map.insert(coin_type, minimum_bond);
        } else {
            let current_minimum = &mut config.minimum_bond_map[&coin_type];
            *current_minimum = minimum_bond;
        }
    }

    public fun add_resolver(config: &mut Config, _: &ConfigCap, resolver: address) {
       config.resolvers.insert(resolver);
    }

    public fun remove_resolver(config: &mut Config, _: &ConfigCap, resolver: address) {
        config.resolvers.remove(&resolver);
    }

    // public fun add_validator(
    //     config: &mut Config,
    //     _: &AdminCap,
    //     validator: address,
    // ) {
    //     if (!vector::contains(&config.validator_whitelist, &validator)) {
    //         vector::push_back(&mut config.validator_whitelist, validator);
    //     }
    // }

    // public fun remove_validator(
    //     config: &mut Config,
    //     _: &AdminCap,
    //     validator: address,
    // ) {
    //     let (found, index) = vector::index_of(&config.validator_whitelist, &validator);
    //     if (found) {
    //         vector::remove(&mut config.validator_whitelist, index);
    //     }
    // }

    // public fun get_stable_coin_type(config: &Config): TypeName {
    //     config.stable_coin_type
    // }

    public fun get_minimum_bond(config: &Config, coin_type: TypeName): u64 {
        config.minimum_bond_map[&coin_type]
    }

    public fun is_valid_resolver(config: &Config, resolver: address): bool {
        config.resolvers.contains(&resolver)
    }

    // public fun is_validator_whitelisted(config: &Config, validator: address): bool {
    //     vector::contains(&config.validator_whitelist, &validator)
    // }

    // public fun assert_validator_whitelisted(config: &Config, validator: address) {
    //     assert!(is_validator_whitelisted(config, validator), EValidatorNotWhitelisted);
    // }
}