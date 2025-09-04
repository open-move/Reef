module default_resolver::resolver_impl;

use reef::epoch::{Epoch, EpochManager};
use reef::resolver::{Self, ResolverCap};
use default_resolver::stake_manager::StakeManager;
use sui::clock::Clock;
use sui::hash;
use sui::package::{Self, Publisher};
use sui::table::{Self, Table};
use sui::vec_map::VecMap;
use default_resolver::stake_manager::StakeManagerCap;

public struct DisputeResolver has key {
    id: UID,
    cumulative_stake: u64,
    config: ResolverConfig,
    resolver_cap: ResolverCap,
    user_tracker: Table<address, Tracker>,
}

public struct RESOLVER_IMPL() has drop;

public struct Witness() has drop;

public struct VoteKey(ID) has copy, drop, store;
public struct EpochConfigKey() has copy, drop, store;
public struct VotingPowerKey(address) has copy, drop, store;

public struct Vote has store {
    total_participating_stake: u64,
    tallies: VecMap<vector<u8>, u64>,
    current_winner: Option<vector<u8>>,
    reveals: Table<address, vector<u8>>,
    commitments: Table<address, vector<u8>>,
}

public struct Tracker has drop, store {
    last_processed_epoch: u64,
    pending_disputes: vector<ID>,
}

public struct EpochConfig has copy, drop, store {
    total_eligible_stake: u64,
    min_consensus_rate_bps: u64,
    min_participation_rate_bps: u64,
}

public struct ResolverConfig has copy, drop, store {
    no_vote_slashing_rate_bps: u64,
    wrong_vote_slashing_rate_bps: u64,
}

public enum VotingStatus has copy, drop {
    NoVote,
    WrongVote,
    CorrectVote,
}

public struct Dispute has key, store {
    id: UID,
    query_id: ID,
    created_at_ms: u64,
    rollover_count: u64,
    active_epoch_no: u64,
}

const EInvalidPublisher: u64 = 0;
const EAlreadyCommitted: u64 = 1;
const EDidNotCommit: u64 = 2;
const EInvalidVote: u64 = 3;
const ENotInCommitPhase: u64 = 4;
const ENotInRevealPhase: u64 = 5;

fun init(otw: RESOLVER_IMPL, ctx: &mut TxContext) {
    package::claim_and_keep(otw, ctx)
}

public fun create(publisher: Publisher, ctx: &mut TxContext): DisputeResolver {
    assert!(publisher.from_module<RESOLVER_IMPL>(), EInvalidPublisher);

    let (resolver, resolver_cap) = resolver::create(Witness(), publisher, ctx);
    resolver.share();

    DisputeResolver {
        id: object::new(ctx),
        resolver_cap,
        cumulative_stake: 0,
        user_tracker: table::new(ctx),
        config: ResolverConfig {
            no_vote_slashing_rate_bps: default_no_vote_slashing_bps!(),
            wrong_vote_slashing_rate_bps: default_wrong_vote_slashing_bps!(),
        },
    }
}

public fun commit<CoinType>(
    resolver: &mut DisputeResolver,
    epoch_manager: &mut EpochManager,
    stake_manager: &mut StakeManager<CoinType>,
    stake_manager_cap: &StakeManagerCap,
    dispute: &Dispute,
    hash: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    stake_manager.validate_stake_manager_cap(stake_manager_cap);
    {
        let epoch = epoch_manager.current_epoch_mut(clock);
        assert!(epoch.is_in_commit_phase(clock), ENotInCommitPhase);
    };

    let voter = ctx.sender();
    resolver.process_voter_slash(epoch_manager, stake_manager, voter, clock);

    let epoch = epoch_manager.current_epoch_mut(clock);
    let vote = resolver.get_vote_mut(epoch, dispute.id.to_inner());

    assert!(!vote.commitments.contains(voter), EAlreadyCommitted);
    vote.commitments.add(voter, hash);
}

public fun reveal(
    resolver: &mut DisputeResolver,
    epoch_manager: &mut EpochManager,
    dispute: &Dispute,
    salt: vector<u8>,
    data: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let epoch = epoch_manager.current_epoch_mut(clock);

    resolver.freeze_epoch_config(epoch);
    assert!(epoch.is_in_reveal_phase(clock), ENotInRevealPhase);

    let voter = ctx.sender();
    let power = resolver.get_voting_power(epoch, voter);
    let vote = resolver.get_vote_mut(epoch, dispute.id.to_inner());
    assert!(vote.commitments.contains(voter), EDidNotCommit);
    assert!(commit_hash!(voter, salt, data) == vote.commitments[voter], EInvalidVote);

    vote.reveals.add(voter, data);

    if (!vote.tallies.contains(&data)) {
        vote.tallies.insert(data, power);
    } else {
        let tally = vote.tallies.get_mut(&data);
        *tally = *tally + power;
    };

    if (vote.current_winner.is_some()) {
        let current_winner = vote.current_winner.borrow();
        if (vote.tallies[&data] > vote.tallies[current_winner]) {
            vote.current_winner = option::some(data)
        }
    } else {
        vote.current_winner.fill(data)
    };

    vote.total_participating_stake = vote.total_participating_stake + power;
}

public fun request_withdrawal<CoinType>(
    resolver: &mut DisputeResolver,
    epoch_manager: &mut EpochManager,
    stake_manager: &mut StakeManager<CoinType>,
    stake_manager_cap: &StakeManagerCap,
    amount: u64,
    clock: &Clock,
    ctx: TxContext,
) {
    resolver.process_voter_slash(epoch_manager, stake_manager, ctx.sender(), clock);
    stake_manager.request_withdrawal(stake_manager_cap, epoch_manager, amount, clock)
}

fun freeze_epoch_config(resolver: &DisputeResolver, epoch: &mut Epoch) {
    let storage = epoch.storage_mut(&resolver.resolver_cap);
    if (!storage.contains(EpochConfigKey())) {
        let epoch_config = EpochConfig {
            total_eligible_stake: resolver.cumulative_stake,
            min_consensus_rate_bps: default_min_consensus_rate_bps!(),
            min_participation_rate_bps: default_min_participation_rate_bps!(),
        };

        storage.add(EpochConfigKey(), epoch_config)
    };
}

public fun is_resolved(
    dispute: &Dispute,
    resolver: &DisputeResolver,
    epoch_manager: &EpochManager,
): bool {
    let epoch = epoch_manager.get_epoch(dispute.active_epoch_no);

    let cfg = resolver.epcoch_config(epoch);
    let vote = resolver.get_vote(epoch, dispute.id.to_inner());

    if (cfg.total_eligible_stake == 0) return false;

    let participation_rate = (vote.total_participating_stake * bps!() / cfg.total_eligible_stake);
    let consensus_rate = if (vote.current_winner.is_some()) {
        let current_winner = vote.current_winner.borrow();
        (vote.tallies[current_winner] * bps!() / cfg.total_eligible_stake)
    } else { 0 };

    participation_rate >= cfg.min_participation_rate_bps && consensus_rate >= cfg.min_consensus_rate_bps
}

public fun process_voter_slash<CoinType>(
    resolver: &mut DisputeResolver,
    epoch_manager: &mut EpochManager,
    stake_manager: &mut StakeManager<CoinType>,
    voter: address,
    clock: &Clock,
) {
    stake_manager.activate_pending_stakes(epoch_manager, clock);


    // let _epoch = epoch_manager.get_epoch(last_processed);
    // let voting_power = resolver.get_voting_power(epoch, voter);

    // let mut i = 0;

    // let pending_slash = 0;
    // while (i < tracker.pending_disputes.length()) {
    //     let dispute_id = tracker.pending_disputes[i];
    //     let vote = resolver.get_vote(epoch, dispute_id);
    //     let status = vote.voting_status(voter);

    //     let amount = match (status) {
    //         VotingStatus::NoVote => (voting_power * resolver.config.no_vote_slashing_rate_bps) / bps!(),
    //         VotingStatus::WrongVote => (voting_power * resolver.config.no_vote_slashing_rate_bps) / bps!(),
    //         _ => 0,
    //     };

    //     pending_slash = pending_slash + amount;
    //     if (
    //         dispute_id != tracker.pending_disputes[i] && tracker.pending_disputes.length() - 1 !=i
    //     ) {
    //         let slash = stake_manager.slash(epoch_manager, amount, clock);
    //         slash.destroy_zero() // destroy for now
    //     };

    //     tracker.pending_disputes.swap_remove(i);
    // };
}

fun voting_status(vote: &Vote, voter: address): VotingStatus {
    if (!vote.reveals.contains(voter)) return VotingStatus::NoVote;
    let winner = vote.current_winner.destroy_with_default(vector[]);
    if (vote.reveals[voter] == winner) {
        return VotingStatus::CorrectVote
    };
    VotingStatus::WrongVote
}

public fun get_voting_power(resolver: &DisputeResolver, epoch: &Epoch, voter: address): u64 {
    *epoch.storage(&resolver.resolver_cap).borrow<_, u64>(VotingPowerKey(voter))
}

public fun get_vote(resolver: &DisputeResolver, epoch: &Epoch, dispute_id: ID): &Vote {
    epoch.storage(&resolver.resolver_cap).borrow<_, Vote>(VoteKey(dispute_id))
}

public fun get_vote_mut(resolver: &DisputeResolver, epoch: &mut Epoch, dispute_id: ID): &mut Vote {
    epoch.storage_mut(&resolver.resolver_cap).borrow_mut<_, Vote>(VoteKey(dispute_id))
}

public fun epcoch_config(resolver: &DisputeResolver, epoch: &Epoch): &EpochConfig {
    epoch.storage(&resolver.resolver_cap).borrow<_, EpochConfig>(EpochConfigKey())
}

macro fun bps(): u64 {
    10_000
}

macro fun default_no_vote_slashing_bps(): u64 {
    100
}

macro fun default_wrong_vote_slashing_bps(): u64 {
    500
}

macro fun default_min_consensus_rate_bps(): u64 {
    69_00
}

macro fun default_min_participation_rate_bps(): u64 {
    51_00
}

macro fun commit_hash($voter: address, $salt: vector<u8>, $data: vector<u8>): vector<u8> {
    let voter = $voter;
    let salt = $salt;
    let data = $data;

    let mut bytes = voter.to_bytes();
    bytes.append(salt);
    bytes.append(data);

    hash::blake2b256(&bytes)
}
