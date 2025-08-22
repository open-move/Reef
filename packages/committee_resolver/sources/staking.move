module resolver::staking;

use sui::balance::Balance;
use sui::clock::Clock;
use sui::coin::Coin;

public struct Stake<phantom CoinType> has store {
    value: Balance<CoinType>,
    withdrawal_request: Option<WithdrawalRequest>,
}

public struct WithdrawalRequest has drop, store {
    amount: u64,
    requested_at_ms: u64,
}

public use fun stake_value as Stake.value;
public use fun stake_split as Stake.split;
public use fun stake_join as Stake.join;
public use fun stake_into_coin as Stake.into_coin;
public use fun stake_destroy_zero as Stake.destroy_zero;
public use fun stake_withdrawal_request as Stake.withdrawal_request;

const WITHDRAWAL_COOLDOWN_MS: u64 = 7 * 24 * 60 * 60 * 1000; // 7 days

const EWithdrawalRequestExists: u64 = 0;
const EInsufficientStake: u64 = 1;
const ENoWithdrawalRequest: u64 = 2;
const EWithdrawalCooldownNotExpired: u64 = 3;

public(package) fun create_stake<CoinType>(value: Balance<CoinType>): Stake<CoinType> {
    Stake {
        value,
        withdrawal_request: option::none(),
    }
}

public(package) fun request_withdrawal<CoinType>(
    stake: &mut Stake<CoinType>,
    amount: u64,
    clock: &Clock,
) {
    assert!(stake.withdrawal_request.is_none(), EWithdrawalRequestExists);
    assert!(stake.value.value() >= amount, EInsufficientStake);
    let request = WithdrawalRequest {
        amount,
        requested_at_ms: clock.timestamp_ms(),
    };

    stake.withdrawal_request.fill(request)
}

public(package) fun complete_withdrawal<CoinType>(
    stake: &mut Stake<CoinType>,
    clock: &Clock,
): Balance<CoinType> {
    assert!(stake.withdrawal_request.is_some(), ENoWithdrawalRequest);
    let request = stake.withdrawal_request.borrow();

    let elapsed = clock.timestamp_ms() - request.requested_at_ms;
    assert!(elapsed >= WITHDRAWAL_COOLDOWN_MS, EWithdrawalCooldownNotExpired);

    let request = stake.withdrawal_request.extract();
    stake.value.split(request.amount)
}

public(package) fun stake_value<CoinType>(stake: &Stake<CoinType>): u64 {
    stake.value.value()
}

public(package) fun stake_split<CoinType>(
    stake: &mut Stake<CoinType>,
    amount: u64,
): Balance<CoinType> {
    stake.value.split(amount)
}

public(package) fun stake_join<CoinType>(stake: &mut Stake<CoinType>, balance: Balance<CoinType>) {
    stake.value.join(balance);
}

public(package) fun stake_into_coin<CoinType>(
    stake: Stake<CoinType>,
    ctx: &mut TxContext,
): Coin<CoinType> {
    let Stake { value, withdrawal_request } = stake;
    assert!(withdrawal_request.is_none(), EWithdrawalRequestExists);

    value.into_coin(ctx)
}

public(package) fun stake_destroy_zero<CoinType>(stake: Stake<CoinType>) {
    let Stake { value, withdrawal_request } = stake;
    assert!(withdrawal_request.is_none(), EWithdrawalRequestExists);

    value.destroy_zero();
}

public(package) fun stake_withdrawal_request<CoinType>(
    stake: &Stake<CoinType>,
): &Option<WithdrawalRequest> {
    &stake.withdrawal_request
}

public(package) fun withdrawal_amount<CoinType>(stake: &Stake<CoinType>): u64 {
    stake.withdrawal_request.borrow().amount
}

public(package) fun effective_stake<CoinType>(stake: &Stake<CoinType>): u64 {
    let total_stake = stake.value();
    let withdrawal_request = stake.withdrawal_request();

    if (withdrawal_request.is_some()) {
        let request = withdrawal_request.borrow();
        if (total_stake > request.amount) {
            total_stake - request.amount
        } else {
            0
        }
    } else {
        total_stake
    }
}
