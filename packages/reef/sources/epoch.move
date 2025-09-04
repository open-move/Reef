module reef::epoch;

use reef::resolver::ResolverCap;
use sui::bag::{Self, Bag};
use sui::clock::Clock;
use sui::dynamic_field;
use sui::event;
use sui::table::{Self, Table};
use sui::vec_set::{Self, VecSet};

const EEpochNotFound: u64 = 0;
const EStorageAlreadyInitialized: u64 = 1;
const EStorageNotInitialized: u64 = 2;

public struct EpochManager has key, store {
    id: UID,
    epoch_duration_ms: u64,
    genesis_timestamp_ms: u64,
    epochs: Table<u64, Epoch>,
    unfinalized_epochs: VecSet<u64>,
}

public struct Epoch has key, store {
    id: UID,
    epoch_no: u64,
    finalized: bool,
    end_time_ms: u64,
    start_time_ms: u64,
}

public struct Storage has store {
    inner: Bag,
}

public struct StorageKey(ID) has copy, drop, store;

public struct EpochStarted has copy, drop {
    epoch_no: u64,
    end_time_ms: u64,
    start_time_ms: u64,
}

public struct EpochFinalized has copy, drop {
    epoch_no: u64,
    finalized_at_ms: u64,
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
        epoch_no: 0,
        start_time_ms: genesis_time_ms,
        end_time_ms: genesis_time_ms + duration_ms,
    });

    manager
}

public fun next_epoch(manager: &mut EpochManager, clock: &Clock, ctx: &mut TxContext): &Epoch {
    let epoch_no = current_epoch_no(manager, clock) + 1;
    ensure_epoch_exists(manager, epoch_no, clock, ctx)
}

public fun current_epoch(manager: &EpochManager, clock: &Clock): &Epoch {
    &manager.epochs[epoch_no_for_timestamp(manager, clock.timestamp_ms())]
}

public fun current_epoch_mut(manager: &mut EpochManager, clock: &Clock): &mut Epoch {
    let epoch_no = epoch_no_for_timestamp(manager, clock.timestamp_ms());
    &mut manager.epochs[epoch_no]
}

public fun current_epoch_no(manager: &EpochManager, clock: &Clock): u64 {
    epoch_no_for_timestamp(manager, clock.timestamp_ms())
}

public fun epoch_no_for_timestamp(manager: &EpochManager, timestamp_ms: u64): u64 {
    (timestamp_ms - manager.genesis_timestamp_ms) / manager.epoch_duration_ms
}

public fun epoch_boundaries(manager: &EpochManager, epoch_no: u64): (u64, u64) {
    let start = manager.genesis_timestamp_ms + (epoch_no * manager.epoch_duration_ms);
    (start, start + manager.epoch_duration_ms)
}

fun ensure_epoch_exists(
    manager: &mut EpochManager,
    epoch_no: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): &mut Epoch {
    finalize_old_epochs(manager, clock);

    if (!manager.epochs.contains(epoch_no)) {
        let (start_time, end_time) = epoch_boundaries(manager, epoch_no);

        let new_epoch = Epoch {
            id: object::new(ctx),
            epoch_no,
            finalized: false,
            end_time_ms: end_time,
            start_time_ms: start_time,
        };

        manager.epochs.add(epoch_no, new_epoch);
        manager.unfinalized_epochs.insert(epoch_no);

        event::emit(EpochStarted {
            epoch_no,
            start_time_ms: start_time,
            end_time_ms: end_time,
        });
    };

    manager.epochs.borrow_mut(epoch_no)
}

fun finalize_old_epochs(manager: &mut EpochManager, clock: &Clock) {
    let current_time_epoch = current_epoch_no(manager, clock);

    let safe_to_finalize = if (current_time_epoch > 2) { current_time_epoch - 2 } else { 0 };

    let mut epochs_to_finalize = vector::empty<u64>();
    manager.unfinalized_epochs.keys().do_ref!(|epoch_no_ref| {
        let epoch_no = *epoch_no_ref;
        if (epoch_no <= safe_to_finalize) {
            epochs_to_finalize.push_back(epoch_no);
        };
    });

    epochs_to_finalize.do!(|epoch_no| {
        if (manager.epochs.contains(epoch_no)) {
            let epoch = manager.epochs.borrow_mut(epoch_no);

            epoch.finalized = true;
            manager.unfinalized_epochs.remove(&epoch_no);

            event::emit(EpochFinalized {
                epoch_no,
                finalized_at_ms: clock.timestamp_ms(),
            });
        };
    });
}

public fun get_next_epoch_no(manager: &EpochManager, clock: &Clock): u64 {
    current_epoch_no(manager, clock) + 1
}

public fun is_epoch_active(manager: &EpochManager, epoch_no: u64, clock: &Clock): bool {
    if (!manager.epochs.contains(epoch_no)) {
        return false
    };

    let epoch = &manager.epochs[epoch_no];
    let current_time_ms = clock.timestamp_ms();

    current_time_ms >= epoch.start_time_ms && current_time_ms < epoch.end_time_ms
}

public fun get_epoch(manager: &EpochManager, epoch_no: u64): &Epoch {
    assert!(manager.epochs.contains(epoch_no), EEpochNotFound);
    &manager.epochs[epoch_no]
}

public fun get_epoch_mut(manager: &mut EpochManager, epoch_no: u64): &mut Epoch {
    assert!(manager.epochs.contains(epoch_no), EEpochNotFound);
    &mut manager.epochs[epoch_no]
}

public fun get_epoch_for_timestamp(manager: &EpochManager, timestamp_ms: u64): &Epoch {
    let epoch_no = epoch_no_for_timestamp(manager, timestamp_ms);
    assert!(manager.epochs.contains(epoch_no), EEpochNotFound);
    &manager.epochs[epoch_no]
}

public(package) fun get_or_create_epoch(
    manager: &mut EpochManager,
    epoch_no: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): &Epoch {
    ensure_epoch_exists(manager, epoch_no, clock, ctx)
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
    24 * 60 * 60 * 1000
}

public fun initialize_storage(epoch: &mut Epoch, cap: &ResolverCap, ctx: &mut TxContext) {
    assert!(!epoch.is_storage_initialized(cap), EStorageAlreadyInitialized);
    dynamic_field::add(
        &mut epoch.id,
        StorageKey(cap.cap_resolver_id()),
        Storage { inner: bag::new(ctx) },
    )
}

public fun is_storage_initialized(epoch: &Epoch, cap: &ResolverCap): bool {
    dynamic_field::exists_(&epoch.id, StorageKey(cap.cap_resolver_id()))
}

public fun storage(epoch: &Epoch, cap: &ResolverCap): &Bag {
    assert!(epoch.is_storage_initialized(cap), EStorageNotInitialized);
    &dynamic_field::borrow<_, Storage>(&epoch.id, StorageKey(cap.cap_resolver_id())).inner
}

public fun storage_mut(epoch: &mut Epoch, cap: &ResolverCap): &mut Bag {
    assert!(epoch.is_storage_initialized(cap), EStorageNotInitialized);
    &mut dynamic_field::borrow_mut<_, Storage>(
        &mut epoch.id,
        StorageKey(cap.cap_resolver_id()),
    ).inner
}
