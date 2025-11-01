module reef::round;

use reef::resolver::ResolverCap;
use sui::bag::{Self, Bag};
use sui::clock::Clock;
use sui::derived_object;
use sui::dynamic_field;
use sui::event;
use sui::object_table::{Self, ObjectTable};

/// Thrown when requested round number doesn't exist
const ERoundNotFound: u64 = 0;
/// Thrown when trying to initialize storage that already exists
const EStorageAlreadyInitialized: u64 = 1;
/// Thrown when trying to access storage that hasn't been initialized
const EStorageNotInitialized: u64 = 2;
/// Thrown when timestamp is before genesis timestamp
const ETimestampBeforeGenesis: u64 = 3;

public struct RoundManager has key, store {
    id: UID,
    round_duration_ms: u64,
    genesis_timestamp_ms: u64,
    rounds: ObjectTable<u64, Round>,
}

public struct Round has key, store {
    id: UID,
    round_no: u64,
    end_time_ms: u64,
    start_time_ms: u64,
}

public struct Storage has store {
    inner: Bag,
}

public struct StorageKey(ID) has copy, drop, store;
public struct RoundKey(u64) has copy, drop, store;

public struct RoundStarted has copy, drop {
    round_no: u64,
    end_time_ms: u64,
    start_time_ms: u64,
}

public(package) fun new_round_manager(
    round_duration_ms: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): RoundManager {
    let duration_ms = round_duration_ms.destroy_with_default(default_round_duration_ms!());
    let genesis_time_ms = clock.timestamp_ms();

    let manager = RoundManager {
        id: object::new(ctx),
        rounds: object_table::new(ctx),
        round_duration_ms: duration_ms,
        genesis_timestamp_ms: genesis_time_ms,
    };

    event::emit(RoundStarted {
        round_no: 0,
        start_time_ms: genesis_time_ms,
        end_time_ms: genesis_time_ms + duration_ms,
    });

    manager
}

/// Gets or creates the next round after the current one.
///
/// @param manager RoundManager object
/// @param clock System clock for current time
///
/// @return Mutable reference to next round
public fun next_round(manager: &mut RoundManager, clock: &Clock): &Round {
    let round_no = current_round_no(manager, clock) + 1;
    ensure_round_exists(manager, round_no)
}

/// Returns the current round based on the clock time.
/// Creates the round if it doesn't exist yet.
///
/// @param manager RoundManager object (mutable for potential round creation)
/// @param clock System clock for current time
///
/// @return Reference to current round
public fun current_round(manager: &mut RoundManager, clock: &Clock): &Round {
    let round_no = round_no_for_timestamp(manager, clock.timestamp_ms());
    ensure_round_exists(manager, round_no)
}

/// Returns a mutable reference to the current round.
/// Creates the round if it doesn't exist yet.
///
/// @param manager RoundManager object
/// @param clock System clock for current time
///
/// @return Mutable reference to current round
public fun current_round_mut(manager: &mut RoundManager, clock: &Clock): &mut Round {
    let round_no = round_no_for_timestamp(manager, clock.timestamp_ms());
    ensure_round_exists(manager, round_no)
}

/// Returns the current round number.
///
/// @param manager RoundManager object
/// @param clock System clock for current time
///
/// @return Current round number
public fun current_round_no(manager: &RoundManager, clock: &Clock): u64 {
    round_no_for_timestamp(manager, clock.timestamp_ms())
}

/// Calculates which round number a timestamp belongs to using the
/// round duration and genesis timestamp.
///
/// @param manager RoundManager object
/// @param timestamp_ms Timestamp to convert
///
/// @return Round number for the timestamp
public fun round_no_for_timestamp(manager: &RoundManager, timestamp_ms: u64): u64 {
    assert!(timestamp_ms >= manager.genesis_timestamp_ms, ETimestampBeforeGenesis);
    (timestamp_ms - manager.genesis_timestamp_ms) / manager.round_duration_ms
}

/// Returns the start and end timestamps for an round.
///
/// @param manager RoundManager object
/// @param round_no Round number to calculate boundaries for
///
/// @return (start_time_ms, end_time_ms) tuple
public fun round_boundaries(manager: &RoundManager, round_no: u64): (u64, u64) {
    let start = manager.genesis_timestamp_ms + (round_no * manager.round_duration_ms);
    (start, start + manager.round_duration_ms)
}

fun ensure_round_exists(manager: &mut RoundManager, round_no: u64): &mut Round {
    if (!manager.rounds.contains(round_no)) {
        let (start_time, end_time) = round_boundaries(manager, round_no);

        let new_round = Round {
            id: derived_object::claim(&mut manager.id, RoundKey(round_no)),
            round_no,
            end_time_ms: end_time,
            start_time_ms: start_time,
        };

        manager.rounds.add(round_no, new_round);

        event::emit(RoundStarted {
            round_no,
            start_time_ms: start_time,
            end_time_ms: end_time,
        });
    };
    manager.rounds.borrow_mut(round_no)
}

/// Returns the next round number after the current one.
public fun get_next_round_no(manager: &RoundManager, clock: &Clock): u64 {
    current_round_no(manager, clock) + 1
}

/// Checks if a specific round is currently active.
public fun is_round_active(manager: &RoundManager, round_no: u64, clock: &Clock): bool {
    if (!manager.rounds.contains(round_no)) {
        return false
    };

    let round = &manager.rounds[round_no];
    let current_time_ms = clock.timestamp_ms();

    current_time_ms >= round.start_time_ms && current_time_ms < round.end_time_ms
}

/// Gets an round by number. Panics if round doesn't exist.
public fun get_round(manager: &RoundManager, round_no: u64): &Round {
    assert!(manager.rounds.contains(round_no), ERoundNotFound);
    &manager.rounds[round_no]
}

/// Gets a mutable round by number. Panics if round doesn't exist.
public fun get_round_mut(manager: &mut RoundManager, round_no: u64): &mut Round {
    assert!(manager.rounds.contains(round_no), ERoundNotFound);
    &mut manager.rounds[round_no]
}

/// Gets the round that contains a specific timestamp.
/// Creates the round if it doesn't exist yet.
public fun get_round_for_timestamp(manager: &mut RoundManager, timestamp_ms: u64): &Round {
    let round_no = round_no_for_timestamp(manager, timestamp_ms);
    ensure_round_exists(manager, round_no)
}

public(package) fun get_or_create_round(manager: &mut RoundManager, round_no: u64): &Round {
    ensure_round_exists(manager, round_no)
}

/// Returns the start time of the round in milliseconds.
public fun start_time_ms(round: &Round): u64 {
    round.start_time_ms
}

/// Returns the end time of the round in milliseconds.
public fun end_time_ms(round: &Round): u64 {
    round.end_time_ms
}

/// Returns when the commit phase ends (halfway through round).
///
/// @param round Round object
///
/// @return Timestamp when commit phase ends
public fun commit_end_time_ms(round: &Round): u64 {
    let duration = round.end_time_ms - round.start_time_ms;
    round.start_time_ms + (duration / 2) // Exactly halfway
}

/// Checks if the round is currently in the commit phase (first half).
///
/// @param round Round object
/// @param clock System clock for current time
///
/// @return True if in commit phase
public fun is_in_commit_phase(round: &Round, clock: &Clock): bool {
    let current_time = clock.timestamp_ms();
    current_time >= round.start_time_ms && current_time < round.commit_end_time_ms()
}

/// Checks if the round is currently in the reveal phase (second half).
///
/// @param round Round object
/// @param clock System clock for current time
///
/// @return True if in reveal phase
public fun is_in_reveal_phase(round: &Round, clock: &Clock): bool {
    let current_time = clock.timestamp_ms();
    current_time >= round.commit_end_time_ms() && current_time < round.end_time_ms
}

/// Returns the duration of rounds in milliseconds.
public fun round_duration_ms(manager: &RoundManager): u64 {
    manager.round_duration_ms
}

public macro fun default_round_duration_ms(): u64 {
    48 * 60 * 60 * 1000 // 48 hours in milliseconds
}

/// Initializes storage for a resolver within this round. Creates a new
/// Bag for resolver-specific data storage during this round.
///
/// @param round Round to initialize storage in
/// @param cap ResolverCap for authorization and key generation
/// @param ctx Transaction context for object creation
public fun initialize_storage(round: &mut Round, cap: &ResolverCap, ctx: &mut TxContext) {
    assert!(!round.is_storage_initialized(cap), EStorageAlreadyInitialized);
    dynamic_field::add(
        &mut round.id,
        StorageKey(cap.cap_resolver_id()),
        Storage { inner: bag::new(ctx) },
    )
}

/// Checks if storage has been initialized for a resolver.
///
/// @param round Round object
/// @param cap ResolverCap for authorization
///
/// @return True if storage exists
public fun is_storage_initialized(round: &Round, cap: &ResolverCap): bool {
    dynamic_field::exists_(&round.id, StorageKey(cap.cap_resolver_id()))
}

/// Returns read-only access to resolver storage for this round.
///
/// @param round Round containing storage
/// @param cap ResolverCap for authorization
///
/// @return Reference to storage Bag
public fun storage(round: &Round, cap: &ResolverCap): &Bag {
    assert!(round.is_storage_initialized(cap), EStorageNotInitialized);
    &dynamic_field::borrow<_, Storage>(&round.id, StorageKey(cap.cap_resolver_id())).inner
}

/// Returns mutable access to resolver storage for this round.
///
/// @param round Round containing storage
/// @param cap ResolverCap for authorization
///
/// @return Mutable reference to storage Bag
public fun storage_mut(round: &mut Round, cap: &ResolverCap): &mut Bag {
    assert!(round.is_storage_initialized(cap), EStorageNotInitialized);
    &mut dynamic_field::borrow_mut<_, Storage>(
        &mut round.id,
        StorageKey(cap.cap_resolver_id()),
    ).inner
}

/// Returns the round number.
public fun round_no(round: &Round): u64 {
    round.round_no
}

/// Returns the genesis timestamp of the round manager.
public fun genesis_timestamp_ms(manager: &RoundManager): u64 {
    manager.genesis_timestamp_ms
}
