module truth_resolver::staking_vault;

use reef::round::RoundManager;
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::Coin;
use sui::derived_object;

public struct StakingVault<phantom CoinType> has key {
    id: UID,
    balance: Balance<CoinType>,
    /// Delayed stake activation:
    /// - activating_next_round: stakes that will activate at the next round transition
    /// Stakes added in round N become active in round N+1
    activating_next_round: Balance<CoinType>,
    withdrawal_request: Option<WithdrawalRequest<CoinType>>,
    /// Track the last round we processed to prevent double-activation
    last_processed_round: u64,
}

public struct WithdrawalRequest<phantom CoinType> has store {
    /// amount being withdrawn (not counted as active stake)
    balance: Balance<CoinType>,
    /// round when withdrawal can be completed
    unlock_round: u64,
}

public struct StakingVaultCap has key, store {
    id: UID,
    staking_vault_id: ID,
}

public struct StakingVaultKey(address) has copy, drop, store;
public struct StakingVaultCapKey() has copy, drop, store;

const ENoWithdrawalRequest: u64 = 0;
const EIncompleteWithdrawalRound: u64 = 1;
const EStakingVaultCapMismatch: u64 = 2;

public(package) fun new<CoinType>(
    resolver_uid: &mut UID,
    coin: Coin<CoinType>,
    round_manager: &RoundManager,
    clock: &Clock,
    ctx: &mut TxContext,
): (StakingVault<CoinType>, StakingVaultCap) {
    let vault = StakingVault {
        id: object::new(ctx),
        balance: balance::zero(),
        // Initial stake will activate next round
        withdrawal_request: option::none(),
        activating_next_round: coin.into_balance(),
        last_processed_round: round_manager.current_round_no(clock),
    };

    let cap = StakingVaultCap {
        id: derived_object::claim(resolver_uid, StakingVaultKey(ctx.sender())),
        staking_vault_id: vault.id.to_inner(),
    };

    (vault, cap)
}

public(package) fun share_staking_vault<CoinType>(vault: StakingVault<CoinType>) {
    transfer::share_object(vault);
}

#[allow(lint(custom_state_change, self_transfer))]
public(package) fun transfer_staking_vault_cap(cap: StakingVaultCap, ctx: &TxContext) {
    transfer::transfer(cap, ctx.sender());
}

// Process pending stakes for round transition
// Should be called before any stake-dependent operations (voting, slashing, etc.)
public(package) fun activate_pending_stakes<CoinType>(
    vault: &mut StakingVault<CoinType>,
    round_manager: &RoundManager,
    clock: &Clock,
) {
    let current_round = round_manager.current_round_no(clock);

    if (current_round > vault.last_processed_round) {
        vault.balance.join(vault.activating_next_round.withdraw_all());
        vault.last_processed_round = current_round;
    }
}

// Add new stake (will be active after next round transition)
public fun add_stake<CoinType>(
    vault: &mut StakingVault<CoinType>,
    coin: Coin<CoinType>,
    round_manager: &RoundManager,
    clock: &Clock,
) {
    activate_pending_stakes(vault, round_manager, clock);
    vault.activating_next_round.join(coin.into_balance());
}

// Get active stake amount (excludes pending stakes and withdrawals)
public fun active_stake<CoinType>(vault: &StakingVault<CoinType>): u64 {
    vault.balance.value()
}

// Immediate withdrawal for slashing (package-level only)
public(package) fun slash<CoinType>(
    vault: &mut StakingVault<CoinType>,
    round_manager: &RoundManager,
    amount: u64,
    clock: &Clock,
): Balance<CoinType> {
    activate_pending_stakes(vault, round_manager, clock);

    let total_available = {
        let mut available = vault.balance.value();
        if (vault.withdrawal_request.is_some()) {
            available = available + vault.withdrawal_request.borrow().balance.value();
        };
        available
    };

    if (total_available == 0) {
        return balance::zero()
    };

    let mut remaining = amount.min(total_available);
    if (remaining == 0) {
        return balance::zero()
    };

    let mut slashed = balance::zero();

    let active_available = vault.balance.value();
    let from_active = remaining.min(active_available);
    if (from_active > 0) {
        slashed.join(vault.balance.split(from_active));
        remaining = remaining - from_active;
    };

    let mut should_clear_withdrawal = false;
    if (remaining > 0 && vault.withdrawal_request.is_some()) {
        let request = vault.withdrawal_request.borrow_mut();
        let from_withdrawal = remaining.min(request.balance.value());
        if (from_withdrawal > 0) {
            slashed.join(request.balance.split(from_withdrawal));
            should_clear_withdrawal = request.balance.value() == 0;
        };
    };

    if (should_clear_withdrawal) {
        let WithdrawalRequest { balance: withdrawn_balance, unlock_round: _ } = vault
            .withdrawal_request
            .extract();
        withdrawn_balance.destroy_zero();
    };

    slashed
}

// Initiate user withdrawal with cooldown
public(package) fun request_withdrawal<CoinType>(
    vault: &mut StakingVault<CoinType>,
    cap: &StakingVaultCap,
    round_manager: &RoundManager,
    amount: u64,
    clock: &Clock,
) {
    vault.validate_staking_vault_cap(cap);
    activate_pending_stakes(vault, round_manager, clock);
    let current_round = round_manager.current_round_no(clock);

    vault
        .withdrawal_request
        .fill(WithdrawalRequest {
            balance: vault.balance.split(amount),
            unlock_round: current_round + default_cooldown_round!(),
        });
}

public fun complete_withdrawal<CoinType>(
    vault: &mut StakingVault<CoinType>,
    round_manager: &RoundManager,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<CoinType> {
    let current_round = round_manager.current_round_no(clock);

    assert!(vault.withdrawal_request.is_some(), ENoWithdrawalRequest);
    let WithdrawalRequest { balance, unlock_round } = vault.withdrawal_request.extract();

    assert!(current_round >= unlock_round, EIncompleteWithdrawalRound);
    balance.into_coin(ctx)
}

public fun validate_staking_vault_cap<CoinType>(
    vault: &StakingVault<CoinType>,
    cap: &StakingVaultCap,
) {
    assert!(cap.staking_vault_id == vault.id.to_inner(), EStakingVaultCapMismatch);
}

macro fun default_cooldown_round(): u64 {
    3
}
