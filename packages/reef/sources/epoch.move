module reef::epoch;

use reef::resolver::ResolverCap;
use sui::bag::{Self, Bag};
use sui::clock::Clock;
use sui::dynamic_field;
use sui::event;
use sui::table::{Self, Table};

/// Thrown when requested epoch number doesn't exist
const EEpochNotFound: u64 = 0;
/// Thrown when trying to initialize storage that already exists
const EStorageAlreadyInitialized: u64 = 1;
/// Thrown when trying to access storage that hasn't been initialized
const EStorageNotInitialized: u64 = 2;
/// Thrown when timestamp is before genesis timestamp
const ETimestampBeforeGenesis: u64 = 3;

public struct EpochManager has key, store {
    id: UID,
    epoch_duration_ms: u64,
    genesis_timestamp_ms: u64,
    epochs: Table<u64, Epoch>,
}

public struct Epoch has key, store {
    id: UID,
    epoch_no: u64,
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
    };

    event::emit(EpochStarted {
        epoch_no: 0,
        start_time_ms: genesis_time_ms,
        end_time_ms: genesis_time_ms + duration_ms,
    });

    manager
}

/// Gets or creates the next epoch after the current one.
///
/// @param manager EpochManager object
/// @param clock System clock for current time
/// @param ctx Transaction context for object creation
///
/// @return Mutable reference to next epoch
public fun next_epoch(manager: &mut EpochManager, clock: &Clock, ctx: &mut TxContext): &Epoch {
    let epoch_no = current_epoch_no(manager, clock) + 1;
    ensure_epoch_exists(manager, epoch_no, ctx)
}

/// Returns the current epoch based on the clock time.
/// Creates the epoch if it doesn't exist yet.
///
/// @param manager EpochManager object (mutable for potential epoch creation)
/// @param clock System clock for current time
/// @param ctx Transaction context for object creation if needed
///
/// @return Reference to current epoch
public fun current_epoch(manager: &mut EpochManager, clock: &Clock, ctx: &mut TxContext): &Epoch {
    let epoch_no = epoch_no_for_timestamp(manager, clock.timestamp_ms());
    ensure_epoch_exists(manager, epoch_no, ctx)
}

/// Returns a mutable reference to the current epoch.
/// Creates the epoch if it doesn't exist yet.
///
/// @param manager EpochManager object
/// @param clock System clock for current time
/// @param ctx Transaction context for object creation if needed
///
/// @return Mutable reference to current epoch
public fun current_epoch_mut(manager: &mut EpochManager, clock: &Clock, ctx: &mut TxContext): &mut Epoch {
    let epoch_no = epoch_no_for_timestamp(manager, clock.timestamp_ms());
    ensure_epoch_exists(manager, epoch_no, ctx)
}

/// Returns the current epoch number.
///
/// @param manager EpochManager object
/// @param clock System clock for current time
///
/// @return Current epoch number
public fun current_epoch_no(manager: &EpochManager, clock: &Clock): u64 {
    epoch_no_for_timestamp(manager, clock.timestamp_ms())
}

/// Calculates which epoch number a timestamp belongs to using the
/// epoch duration and genesis timestamp.
///
/// @param manager EpochManager object
/// @param timestamp_ms Timestamp to convert
///
/// @return Epoch number for the timestamp
public fun epoch_no_for_timestamp(manager: &EpochManager, timestamp_ms: u64): u64 {
    assert!(timestamp_ms >= manager.genesis_timestamp_ms, ETimestampBeforeGenesis);
    (timestamp_ms - manager.genesis_timestamp_ms) / manager.epoch_duration_ms
}

/// Returns the start and end timestamps for an epoch.
///
/// @param manager EpochManager object
/// @param epoch_no Epoch number to calculate boundaries for
///
/// @return (start_time_ms, end_time_ms) tuple
public fun epoch_boundaries(manager: &EpochManager, epoch_no: u64): (u64, u64) {
    let start = manager.genesis_timestamp_ms + (epoch_no * manager.epoch_duration_ms);
    (start, start + manager.epoch_duration_ms)
}

fun ensure_epoch_exists(
    manager: &mut EpochManager,
    epoch_no: u64,
    ctx: &mut TxContext,
): &mut Epoch { if (!manager.epochs.contains(epoch_no)) {
        let (start_time, end_time) = epoch_boundaries(manager, epoch_no);

        let new_epoch = Epoch {
            id: object::new(ctx),
            epoch_no,
            end_time_ms: end_time,
            start_time_ms: start_time,
        };

        manager.epochs.add(epoch_no, new_epoch);

        event::emit(EpochStarted {
            epoch_no,
            start_time_ms: start_time,
            end_time_ms: end_time,
        });
    };  manager.epochs.borrow_mut(epoch_no) }

/// Returns the next epoch number after the current one.
public fun get_next_epoch_no(manager: &EpochManager, clock: &Clock): u64 {
    current_epoch_no(manager, clock) + 1
}

/// Checks if a specific epoch is currently active.
public fun is_epoch_active(manager: &EpochManager, epoch_no: u64, clock: &Clock): bool {
    if (!manager.epochs.contains(epoch_no)) {
        return false
    };

    let epoch = &manager.epochs[epoch_no];
    let current_time_ms = clock.timestamp_ms();

    current_time_ms >= epoch.start_time_ms && current_time_ms < epoch.end_time_ms
}

/// Gets an epoch by number. Panics if epoch doesn't exist.
public fun get_epoch(manager: &EpochManager, epoch_no: u64): &Epoch {
    assert!(manager.epochs.contains(epoch_no), EEpochNotFound);
    &manager.epochs[epoch_no]
}

/// Gets a mutable epoch by number. Panics if epoch doesn't exist.
public fun get_epoch_mut(manager: &mut EpochManager, epoch_no: u64): &mut Epoch {
    assert!(manager.epochs.contains(epoch_no), EEpochNotFound);
    &mut manager.epochs[epoch_no]
}

/// Gets the epoch that contains a specific timestamp.
/// Creates the epoch if it doesn't exist yet.
public fun get_epoch_for_timestamp(
    manager: &mut EpochManager,
    timestamp_ms: u64,
    ctx: &mut TxContext,
): &Epoch {
    let epoch_no = epoch_no_for_timestamp(manager, timestamp_ms);
    ensure_epoch_exists(manager, epoch_no, ctx)
}

public(package) fun get_or_create_epoch(
    manager: &mut EpochManager,
    epoch_no: u64,
    ctx: &mut TxContext,
): &Epoch {
    ensure_epoch_exists(manager, epoch_no, ctx)
}

/// Returns the start time of the epoch in milliseconds.
public fun start_time_ms(epoch: &Epoch): u64 {
    epoch.start_time_ms
}

/// Returns the end time of the epoch in milliseconds.
public fun end_time_ms(epoch: &Epoch): u64 {
    epoch.end_time_ms
}

/// Returns when the commit phase ends (halfway through epoch).
///
/// @param epoch Epoch object
///
/// @return Timestamp when commit phase ends
public fun commit_end_time_ms(epoch: &Epoch): u64 {
    let duration = epoch.end_time_ms - epoch.start_time_ms;
    epoch.start_time_ms + (duration / 2) // Exactly halfway
}

/// Checks if the epoch is currently in the commit phase (first half).
///
/// @param epoch Epoch object
/// @param clock System clock for current time
///
/// @return True if in commit phase
public fun is_in_commit_phase(epoch: &Epoch, clock: &Clock): bool {
    let current_time = clock.timestamp_ms();
    current_time >= epoch.start_time_ms && current_time < epoch.commit_end_time_ms()
}

/// Checks if the epoch is currently in the reveal phase (second half).
///
/// @param epoch Epoch object
/// @param clock System clock for current time
///
/// @return True if in reveal phase
public fun is_in_reveal_phase(epoch: &Epoch, clock: &Clock): bool {
    let current_time = clock.timestamp_ms();
    current_time >= epoch.commit_end_time_ms() && current_time < epoch.end_time_ms
}

/// Returns the duration of epochs in milliseconds.
public fun epoch_duration_ms(manager: &EpochManager): u64 {
    manager.epoch_duration_ms
}

public macro fun default_epoch_duration_ms(): u64 {
    48 * 60 * 60 * 1000 // 48 hours in milliseconds
}

/// Initializes storage for a resolver within this epoch. Creates a new
/// Bag for resolver-specific data storage during this epoch.
///
/// @param epoch Epoch to initialize storage in
/// @param cap ResolverCap for authorization and key generation
/// @param ctx Transaction context for object creation
public fun initialize_storage(epoch: &mut Epoch, cap: &ResolverCap, ctx: &mut TxContext) {
    assert!(!epoch.is_storage_initialized(cap), EStorageAlreadyInitialized);
    dynamic_field::add(
        &mut epoch.id,
        StorageKey(cap.cap_resolver_id()),
        Storage { inner: bag::new(ctx) },
    )
}

/// Checks if storage has been initialized for a resolver.
///
/// @param epoch Epoch object
/// @param cap ResolverCap for authorization
///
/// @return True if storage exists
public fun is_storage_initialized(epoch: &Epoch, cap: &ResolverCap): bool {
    dynamic_field::exists_(&epoch.id, StorageKey(cap.cap_resolver_id()))
}

/// Returns read-only access to resolver storage for this epoch.
///
/// @param epoch Epoch containing storage
/// @param cap ResolverCap for authorization
///
/// @return Reference to storage Bag
public fun storage(epoch: &Epoch, cap: &ResolverCap): &Bag {
    assert!(epoch.is_storage_initialized(cap), EStorageNotInitialized);
    &dynamic_field::borrow<_, Storage>(&epoch.id, StorageKey(cap.cap_resolver_id())).inner
}

/// Returns mutable access to resolver storage for this epoch.
///
/// @param epoch Epoch containing storage
/// @param cap ResolverCap for authorization
///
/// @return Mutable reference to storage Bag
public fun storage_mut(epoch: &mut Epoch, cap: &ResolverCap): &mut Bag {
    assert!(epoch.is_storage_initialized(cap), EStorageNotInitialized);
    &mut dynamic_field::borrow_mut<_, Storage>(
        &mut epoch.id,
        StorageKey(cap.cap_resolver_id()),
    ).inner
}

/// Returns the epoch number.
public fun epoch_no(epoch: &Epoch): u64 {
    epoch.epoch_no
}

/// Returns the genesis timestamp of the epoch manager.
public fun genesis_timestamp_ms(manager: &EpochManager): u64 {
    manager.genesis_timestamp_ms
}
