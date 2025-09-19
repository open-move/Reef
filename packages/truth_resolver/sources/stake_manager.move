module truth_resolver::stake_manager;

use reef::epoch::EpochManager;
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::Coin;

public struct StakeManager<phantom CoinType> has key {
    id: UID,
    balance: Balance<CoinType>,
    /// Delayed stake activation:
    /// - activating_next_epoch: stakes that will activate at the next epoch transition
    /// Stakes added in epoch N become active in epoch N+1
    activating_next_epoch: Balance<CoinType>,
    withdrawal_request: Option<WithdrawalRequest<CoinType>>,
    /// Track the last epoch we processed to prevent double-activation
    last_processed_epoch: u64,
}

public struct WithdrawalRequest<phantom CoinType> has store {
    /// amount being withdrawn (not counted as active stake)
    balance: Balance<CoinType>,
    /// epoch when withdrawal can be completed
    unlock_epoch: u64,
}

public struct StakeManagerCap has key, store {
    id: UID,
    stake_manager_id: ID,
}

const ENoWithdrawalRequest: u64 = 0;
const EIncompleteWithdrawalEpoch: u64 = 1;
const EStakeManagerCapMismatch: u64 = 2;

public(package) fun new<CoinType>(
    coin: Coin<CoinType>,
    epoch_manager: &EpochManager,
    clock: &Clock,
    ctx: &mut TxContext,
): (StakeManager<CoinType>, StakeManagerCap) {
    let manager = StakeManager {
        id: object::new(ctx),
        balance: balance::zero(),
        // Initial stake will activate next epoch
        activating_next_epoch: coin.into_balance(),
        withdrawal_request: option::none(),
        last_processed_epoch: epoch_manager.current_epoch_no(clock),
    };

    let cap = StakeManagerCap {
        id: object::new(ctx),
        stake_manager_id: manager.id.to_inner(),
    };

    (manager, cap)
}

// Process pending stakes for epoch transition
// Should be called before any stake-dependent operations (voting, slashing, etc.)
public(package) fun activate_pending_stakes<CoinType>(
    manager: &mut StakeManager<CoinType>,
    epoch_manager: &EpochManager,
    clock: &Clock,
) {
    let current_epoch = epoch_manager.current_epoch_no(clock);

    if (current_epoch > manager.last_processed_epoch) {
        manager.balance.join(manager.activating_next_epoch.withdraw_all());
        manager.last_processed_epoch = current_epoch;
    }
}

// Add new stake (will be active after next epoch transition)
public fun add_stake<CoinType>(
    manager: &mut StakeManager<CoinType>,
    coin: Coin<CoinType>,
    epoch_manager: &EpochManager,
    clock: &Clock,
) {
    activate_pending_stakes(manager, epoch_manager, clock);
    manager.activating_next_epoch.join(coin.into_balance());
}

// Get active stake amount (excludes pending stakes and withdrawals)
public fun active_stake<CoinType>(manager: &StakeManager<CoinType>): u64 {
    manager.balance.value()
}

// Immediate withdrawal for slashing (package-level only)
public(package) fun slash<CoinType>(
    manager: &mut StakeManager<CoinType>,
    epoch_manager: &EpochManager,
    amount: u64,
    clock: &Clock,
): Balance<CoinType> {
    activate_pending_stakes(manager, epoch_manager, clock);

    let amount = amount.min(manager.balance.value());
    balance::split(&mut manager.balance, amount)
}

// Initiate user withdrawal with cooldown
public(package) fun request_withdrawal<CoinType>(
    manager: &mut StakeManager<CoinType>,
    cap: &StakeManagerCap,
    epoch_manager: &EpochManager,
    amount: u64,
    clock: &Clock,
) {
    manager.validate_stake_manager_cap(cap);
    activate_pending_stakes(manager, epoch_manager, clock);
    let current_epoch = epoch_manager.current_epoch_no(clock);

    manager
        .withdrawal_request
        .fill(WithdrawalRequest {
            balance: manager.balance.split(amount),
            unlock_epoch: current_epoch + default_cooldown_epoch!(),
        });
}

public fun complete_withdrawal<CoinType>(
    manager: &mut StakeManager<CoinType>,
    epoch_manager: &EpochManager,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<CoinType> {
    let current_epoch = epoch_manager.current_epoch_no(clock);

    assert!(manager.withdrawal_request.is_some(), ENoWithdrawalRequest);
    let WithdrawalRequest { balance, unlock_epoch } = manager.withdrawal_request.extract();

    assert!(current_epoch >= unlock_epoch, EIncompleteWithdrawalEpoch);
    balance.into_coin(ctx)
}

public fun validate_stake_manager_cap<CoinType>(
    manager: &StakeManager<CoinType>,
    cap: &StakeManagerCap,
) {
    assert!(cap.stake_manager_id == manager.id.to_inner(), EStakeManagerCapMismatch);
}

macro fun default_cooldown_epoch(): u64 {
    3
}
