module reef::epoch;

use std::type_name::TypeName;
use sui::clock::Clock;
use sui::event;
use sui::table::{Self, Table};
use sui::vec_map::{Self, VecMap};
use sui::vec_set::{Self, VecSet};

// Error codes
const EEpochNotFound: u64 = 0;

public struct EpochManager has key, store {
    id: UID,
    /// Duration of each epoch in milliseconds
    epoch_duration_ms: u64,
    /// Timestamp when the first epoch started
    genesis_timestamp_ms: u64,
    /// All store of all epochs
    epochs: Table<u64, Epoch>,
    /// Track which epochs are not yet finalized
    unfinalized_epochs: VecSet<u64>,
}

public struct Epoch has store {
    /// ID of this epoch (same as index in EpochManager.epochs)
    epoch_id: u64,
    /// Start and end time of this epoch
    start_time_ms: u64,
    /// End time of this epoch
    end_time_ms: u64,
    /// Challenges to be resolved in this epoch
    total_challenges: u64,
    /// Total resolutions completed in this epoch
    total_resolutions: u64,
    /// Total queries created in this epoch
    total_queries: u64,
    /// Whether this epoch has been finalized
    finalized: bool,
    total_fees: VecMap<TypeName, u64>,
    total_bonds_posted: VecMap<TypeName, u64>,
    resolver_metrics: Table<ID, ResolverMetrics>,
}

public struct ResolverMetrics has store {
    disputes_handled: u64,
    resolutions_made: u64,
}

// Events
public struct EpochStarted has copy, drop {
    epoch_id: u64,
    end_time_ms: u64,
    start_time_ms: u64,
}

public struct EpochFinalized has copy, drop {
    epoch_id: u64,
    total_queries: u64,
    finalized_at_ms: u64,
    total_challenges: u64,
    total_resolutions: u64,
}

public(package) fun new_epoch_manager(
    epoch_duration_ms: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): EpochManager {
    let duration_ms = epoch_duration_ms.destroy_with_default(default_epoch_duration_ms!());
    let genesis_time_ms = clock.timestamp_ms();

    let manager = EpochManager {
        id: object::new(ctx),
        epochs: table::new(ctx),
        epoch_duration_ms: duration_ms,
        genesis_timestamp_ms: genesis_time_ms,
        unfinalized_epochs: vec_set::empty(),
    };

    event::emit(EpochStarted {
        epoch_id: 0,
        start_time_ms: genesis_time_ms,
        end_time_ms: genesis_time_ms + duration_ms,
    });

    manager
}

// Returns the current epoch ID based on the clock time
public fun current_epoch_id(manager: &EpochManager, clock: &Clock): u64 {
    (clock.timestamp_ms() - manager.genesis_timestamp_ms) / manager.epoch_duration_ms
}

/// Returns the start and end time of the given epoch ID
public fun epoch_boundaries(manager: &EpochManager, epoch_id: u64): (u64, u64) {
    let start = manager.genesis_timestamp_ms + (epoch_id * manager.epoch_duration_ms);
    (start, start + manager.epoch_duration_ms)
}

// Ensures the given epoch exists. If not, creates it.
fun ensure_epoch_exists(
    manager: &mut EpochManager,
    epoch_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): &mut Epoch {
    finalize_old_epochs(manager, clock);

    if (!manager.epochs.contains(epoch_id)) {
        let (start_time, end_time) = epoch_boundaries(manager, epoch_id);

        let new_epoch = Epoch {
            epoch_id,
            start_time_ms: start_time,
            end_time_ms: end_time,
            total_queries: 0,
            total_challenges: 0,
            total_resolutions: 0,
            total_fees: vec_map::empty(),
            total_bonds_posted: vec_map::empty(),
            resolver_metrics: table::new(ctx),
            finalized: false,
        };

        manager.epochs.add(epoch_id, new_epoch);
        manager.unfinalized_epochs.insert(epoch_id);

        event::emit(EpochStarted {
            epoch_id,
            start_time_ms: start_time,
            end_time_ms: end_time,
        });
    };

    manager.epochs.borrow_mut(epoch_id)
}

fun finalize_old_epochs(manager: &mut EpochManager, clock: &Clock) {
    let current_time_epoch = current_epoch_id(manager, clock);

    let safe_to_finalize = if (current_time_epoch > 2) { current_time_epoch - 2 } else { 0 };

    let mut epochs_to_finalize = vector::empty<u64>();
    manager.unfinalized_epochs.keys().do_ref!(|epoch_id_ref| {
        let epoch_id = *epoch_id_ref;
        if (epoch_id <= safe_to_finalize) {
            epochs_to_finalize.push_back(epoch_id);
        };
    });

    epochs_to_finalize.do!(|epoch_id| {
        if (manager.epochs.contains(epoch_id)) {
            let epoch = manager.epochs.borrow_mut(epoch_id);

            epoch.finalized = true;
            manager.unfinalized_epochs.remove(&epoch_id);

            event::emit(EpochFinalized {
                epoch_id,
                total_queries: epoch.total_queries,
                finalized_at_ms: clock.timestamp_ms(),
                total_challenges: epoch.total_challenges,
                total_resolutions: epoch.total_resolutions,
            });
        };
    });
}

public fun get_next_epoch_id(manager: &EpochManager, clock: &Clock): u64 {
    current_epoch_id(manager, clock) + 1
}

public(package) fun record_query_created(
    manager: &mut EpochManager,
    epoch_id: u64,
    bond_amount: u64,
    coin_type: TypeName,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let epoch = ensure_epoch_exists(manager, epoch_id, clock, ctx);
    epoch.total_queries = epoch.total_queries + 1;

    if (epoch.total_bonds_posted.contains(&coin_type)) {
        let borr = &mut epoch.total_bonds_posted[&coin_type];
        *borr = *borr + bond_amount;
    } else {
        epoch.total_bonds_posted.insert(coin_type, bond_amount)
    }
}

// Record a challenge in an epoch
public(package) fun record_challenge(
    manager: &mut EpochManager,
    epoch_id: u64,
    bond_amount: u64,
    fee_amount: u64,
    coin_type: TypeName,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let epoch = ensure_epoch_exists(manager, epoch_id, clock, ctx);
    epoch.total_challenges = epoch.total_challenges + 1;

    if (epoch.total_bonds_posted.contains(&coin_type)) {
        let borr = &mut epoch.total_bonds_posted[&coin_type];
        *borr = *borr + bond_amount;
    } else {
        epoch.total_bonds_posted.insert(coin_type, bond_amount)
    };

    if (epoch.total_fees.contains(&coin_type)) {
        let borr = &mut epoch.total_fees[&coin_type];
        *borr = *borr + bond_amount;
    } else {
        epoch.total_fees.insert(coin_type, bond_amount)
    };
}

// Record a resolution in an epoch
public(package) fun record_resolution(
    manager: &mut EpochManager,
    epoch_id: u64,
    resolver_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let epoch = ensure_epoch_exists(manager, epoch_id, clock, ctx);
    epoch.total_resolutions = epoch.total_resolutions + 1;

    // Update resolver metrics
    if (!epoch.resolver_metrics.contains(resolver_id)) {
        epoch
            .resolver_metrics
            .add(
                resolver_id,
                ResolverMetrics {
                    resolutions_made: 0,
                    disputes_handled: 0,
                },
            );
    };

    let metrics = &mut epoch.resolver_metrics[resolver_id];
    metrics.resolutions_made = metrics.resolutions_made + 1;
}

public fun is_epoch_active(manager: &EpochManager, epoch_id: u64, clock: &Clock): bool {
    if (!manager.epochs.contains(epoch_id)) {
        return false
    };

    let epoch = &manager.epochs[epoch_id];
    let current_time_ms = clock.timestamp_ms();

    current_time_ms >= epoch.start_time_ms && current_time_ms < epoch.end_time_ms
}

public fun get_epoch(manager: &EpochManager, epoch_id: u64): &Epoch {
    assert!(manager.epochs.contains(epoch_id), EEpochNotFound);
    &manager.epochs[epoch_id]
}

public(package) fun get_or_create_epoch(
    manager: &mut EpochManager,
    epoch_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): &Epoch {
    ensure_epoch_exists(manager, epoch_id, clock, ctx)
}

public fun start_time_ms(epoch: &Epoch): u64 {
    epoch.start_time_ms
}

public fun end_time_ms(epoch: &Epoch): u64 {
    epoch.end_time_ms
}

public fun commit_end_time_ms(epoch: &Epoch): u64 {
    let duration = epoch.end_time_ms - epoch.start_time_ms;
    epoch.start_time_ms + (duration * 60 / 100)
}

public fun is_in_commit_phase(epoch: &Epoch, clock: &Clock): bool {
    let current_time = clock.timestamp_ms();
    current_time >= epoch.start_time_ms && current_time < epoch.commit_end_time_ms()
}

public fun is_in_reveal_phase(epoch: &Epoch, clock: &Clock): bool {
    let current_time = clock.timestamp_ms();
    current_time >= epoch.commit_end_time_ms() && current_time < epoch.end_time_ms
}

public fun epoch_duration_ms(manager: &EpochManager): u64 {
    manager.epoch_duration_ms
}

public macro fun default_epoch_duration_ms(): u64 {
    24 * 60 * 60 * 1000 // 24 hours
}
