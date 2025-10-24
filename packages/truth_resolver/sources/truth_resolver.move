module truth_resolver::truth_resolver;

use reef::resolver::{Self, ResolverCap, DisputeTicket};
use reef::round::{Self, Round, RoundManager};
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::Coin;
use sui::derived_object;
use sui::hash;
use sui::object_table::{Self, ObjectTable};
use sui::package::{Self, Publisher};
use sui::table::{Self, Table};
use sui::vec_map::{Self, VecMap};
use truth_resolver::staking_vault::{Self, StakingVault, StakingVaultCap};
use truth_resolver::verification::{Self, VerificationCommittee, VerificationRequest};

public struct TruthResolver<phantom CoinType> has key {
    id: UID,
    total_pending_slash: u64,
    resolver_cap: ResolverCap,
    verification_buffer_ms: u64,
    cumulative_vote_weight: u64,
    slashing_config: SlashingConfig,
    voters_state: Table<address, VoterState>,
    disputes: ObjectTable<ID, Dispute<CoinType>>,
    round_dispute_index: VecMap<u64, vector<ID>>,
    verification_committee: VerificationCommittee,
    pending_round_disputes: VecMap<u64, vector<ID>>,
}

public struct TruthResolverCap<phantom CoinType> has key, store {
    id: UID,
}

public struct Dispute<phantom CoinType> has key, store {
    id: UID,
    query_id: ID,
    created_at_ms: u64,
    rollover_count: u64,
    min_bond_amount: u64,
    active_round_no: u64,
    slashing_mode: SlashingMode,
    balances: Balances<CoinType>,
    resolved_data: Option<vector<u8>>,
    verification_ends_at_ms: Option<u64>,
    verification_request: Option<VerificationRequest<CoinType>>,
}

public struct Balances<phantom CoinType> has store {
    resolver_pool: Balance<CoinType>,
    verification_bond_pool: Balance<CoinType>,
}

public struct DisputeHandle has key, store {
    id: UID,
    dispute_id: ID,
}

public struct Vote has store {
    total_votes_weight: u64,
    leading_value: Option<vector<u8>>,
    vote_weights: VecMap<vector<u8>, u64>,
    commitments: Table<address, vector<u8>>,
    revealed_votes: Table<address, vector<u8>>,
}

public struct VoterState has store {
    pending_slash: u64,
    pending_dispute_slash: VecMap<ID, u64>,
    pending_round_disputes: VecMap<u64, vector<ID>>,
}

public struct RoundConfig has copy, drop, store {
    verification_buffer_ms: u64,
    min_consensus_rate_bps: u64,
    total_eligible_vote_weight: u64,
    min_participation_rate_bps: u64,
    slashing_config: SlashingConfig,
}

public struct SlashingConfig has copy, drop, store {
    base_slashing_rate_bps: u64,
    no_vote_slashing_bps: u64,
    quadratic_threshold_bps: u64,
    wrong_vote_slashing_bps: u64,
}

public enum VotingStatus has copy, drop {
    NoVote,
    WrongVote,
    CorrectVote,
}

public enum DisputeStatus has copy, drop, store {
    Pending,
    Voting,
    Verification,
    Review,
    Resolved,
    Expired,
}

public enum SlashingMode has copy, drop, store {
    Linear,
    Quadratic,
}

public struct Witness() has drop;

public struct TRUTH_RESOLVER() has drop;

public struct VoteKey(ID) has copy, drop, store;
public struct RoundConfigKey() has copy, drop, store;
public struct VoteWeightKey(address) has copy, drop, store;

public struct TruthResolverCapKey() has copy, drop, store;

const EInvalidPublisher: u64 = 0;
const EAlreadyCommitted: u64 = 1;
const EDidNotCommit: u64 = 2;
const EInvalidVote: u64 = 3;
const ENotInCommitPhase: u64 = 4;
const ENotInRevealPhase: u64 = 5;
const ENotInVerificationBuffer: u64 = 6;
const EInsufficientVerificationRequestBond: u64 = 7;
const EChallengeAlreadyExists: u64 = 8;
const EInvalidDisputeRound: u64 = 9;
const EPendingSlashExists: u64 = 12;
const EVoteNotInitialized: u64 = 13;

fun init(otw: TRUTH_RESOLVER, ctx: &mut TxContext) {
    package::claim_and_keep(otw, ctx)
}

public fun create<CoinType>(
    publisher: Publisher,
    members: vector<address>,
    threshold: u64,
    ctx: &mut TxContext,
): (TruthResolver<CoinType>, TruthResolverCap<CoinType>) {
    assert!(publisher.from_module<TRUTH_RESOLVER>(), EInvalidPublisher);

    let (resolver, resolver_cap) = resolver::create(Witness(), publisher, ctx);
    resolver.share();

    let mut truth_resolver = TruthResolver<CoinType> {
        id: object::new(ctx),
        resolver_cap,
        total_pending_slash: 0,
        cumulative_vote_weight: 0,
        voters_state: table::new(ctx),
        disputes: object_table::new(ctx),
        round_dispute_index: vec_map::empty(),
        pending_round_disputes: vec_map::empty(),
        slashing_config: SlashingConfig {
            no_vote_slashing_bps: default_no_vote_slashing_bps!(),
            base_slashing_rate_bps: default_base_slashing_rate_bps!(),
            wrong_vote_slashing_bps: default_wrong_vote_slashing_bps!(),
            quadratic_threshold_bps: default_quadratic_threshold_bps!(),
        },
        verification_buffer_ms: default_verification_buffer_ms!(),
        verification_committee: verification::new_committee(threshold, members, ctx),
    };

    let cap = TruthResolverCap<CoinType> {
        id: derived_object::claim(&mut truth_resolver.id, TruthResolverCapKey()),
    };

    (truth_resolver, cap)
}

public fun create_dispute<CoinType>(
    resolver: &mut TruthResolver<CoinType>,
    round_manager: &RoundManager,
    ticket: DisputeTicket<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
): DisputeHandle {
    let current_round_no = round_manager.current_round_no(clock);
    let (query_id, _, fee, _disputer, disputed_at_ms, min_bond_amount) = ticket.unpack(
        &resolver.resolver_cap,
    );

    let mut dispute = Dispute {
        id: object::new(ctx),
        query_id,
        min_bond_amount,
        rollover_count: 0,
        resolved_data: option::none(),
        created_at_ms: disputed_at_ms,
        active_round_no: current_round_no,
        slashing_mode: SlashingMode::Linear,
        verification_request: option::none(),
        verification_ends_at_ms: option::none(),
        balances: Balances {
            resolver_pool: fee,
            verification_bond_pool: balance::zero(),
        },
    };

    let dispute_id = dispute.id.to_inner();
    let handle = DisputeHandle {
        id: derived_object::claim(&mut dispute.id, query_id.to_bytes()),
        dispute_id: dispute_id,
    };

    resolver.disputes.add(dispute_id, dispute);
    if (resolver.pending_round_disputes.contains(&current_round_no)) {
        (&mut resolver.pending_round_disputes[&current_round_no]).push_back(dispute_id);
    } else {
        resolver.pending_round_disputes.insert(current_round_no, vector[dispute_id]);
    };

    if (resolver.round_dispute_index.contains(&current_round_no)) {
        (&mut resolver.round_dispute_index[&current_round_no]).push_back(dispute_id);
    } else {
        resolver.round_dispute_index.insert(current_round_no, vector[dispute_id]);
    };

    handle
}

public fun process_round_transitions<CoinType>(
    resolver: &mut TruthResolver<CoinType>,
    round_manager: &mut RoundManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // we are calling this, just to ensure that the current round is initialized if not already
    round_manager.current_round(clock, ctx);

    let current_round_no = round_manager.current_round_no(clock);

    // we need to collect the rounds that we we need to process first, these will be all rounds prior
    // to the current round.
    //
    // for example current round is 5, we need to process rounds 0,1,2,3 and 4 if they have pending disputes.
    let mut rounds_to_process = vector[];
    resolver.pending_round_disputes.keys().do!(|round_no| {
        if (round_no < current_round_no) {
            rounds_to_process.push_back(round_no);
        }
    });

    // now process each round, we need to separate the disputes in each round into those that need to be
    // - resolved
    // - rolled over to the current round (voting not complete, but can rollover)
    // - have their verification buffer set (just entered verification)
    rounds_to_process.do!(|round_no| {
        let mut resolved_disputes = vector[];
        let mut disputes_to_expire = vector[];
        let mut disputes_to_rollover = vector[];
        let mut disputes_to_set_verification = vector[];

        // process each dispute in the round
        resolver.pending_round_disputes[&round_no].do_ref!(|dispute_id_ref| {
            let dispute_id = *dispute_id_ref;
            let dispute = &resolver.disputes[dispute_id];

            let current_round = round_manager.get_round(current_round_no);
            let dispute_round = round_manager.get_round(dispute.active_round_no);

            // if voting is not complete, if rollover count < max, add to rollover list
            // else add to resolved list
            if (!dispute.is_voting_complete_internal(resolver, dispute_round)) {
                if (dispute.rollover_count < default_max_rollover!()) {
                    disputes_to_rollover.push_back(dispute_id);
                } else {
                    resolved_disputes.push_back(dispute_id);
                }
            } else {
                // voting is complete, every dispute needs to go through the verification buffer phase,
                // so if `verification_ends_at_ms` is `none`, then it means it hasn't gone through it.
                // so we need to add it to the `disputes_to_set_verification` list
                if (dispute.verification_ends_at_ms.is_none()) {
                    disputes_to_set_verification.push_back(dispute_id);
                } else {
                    let status = resolver.dispute_status_internal(
                        dispute,
                        current_round,
                        dispute_round,
                        clock,
                    );

                    if (status == DisputeStatus::Resolved) {
                        resolved_disputes.push_back(dispute_id);
                    } else {
                        disputes_to_expire.push_back(dispute_id);
                    }
                }
            }
        });

        // Set verification buffers for disputes that are yet to go through it the verification buffer priod.
        disputes_to_set_verification.do!(|dispute_id| {
            let active_round_no = resolver.disputes[dispute_id].active_round_no;

            let dispute_round = round_manager.get_round(active_round_no);
            let buffer_ms = resolver.round_config(dispute_round).verification_buffer_ms;

            let dispute_mut = &mut resolver.disputes[dispute_id];
            dispute_mut.verification_ends_at_ms.fill(clock.timestamp_ms() + buffer_ms);
        });

        if (!resolved_disputes.is_empty()) {
            resolved_disputes.do!(|dispute_id| {
                resolver.remove_dispute_tracking(round_no, dispute_id);
            });
        };

        if (!disputes_to_rollover.is_empty()) {
            if (resolver.pending_round_disputes.contains(&current_round_no)) {
                resolver
                    .pending_round_disputes
                    .get_mut(&current_round_no)
                    .append(disputes_to_rollover);
            } else {
                resolver.pending_round_disputes.insert(current_round_no, disputes_to_rollover);
            };

            disputes_to_rollover.do!(|dispute_id| {
                let dispute_mut = &mut resolver.disputes[dispute_id];

                dispute_mut.active_round_no = current_round_no;
                dispute_mut.rollover_count = dispute_mut.rollover_count + 1;
            });

            let rollover_ids = &resolver.pending_round_disputes[&current_round_no];
            if (!resolver.round_dispute_index.contains(&current_round_no)) {
                resolver.round_dispute_index.insert(current_round_no, *rollover_ids);
            } else {
                (&mut resolver.round_dispute_index[&current_round_no]).append(*rollover_ids);
            };
        };
    });
}

fun settle_pending_state_internal<CoinType>(
    resolver: &mut TruthResolver<CoinType>,
    round_manager: &mut RoundManager,
    staking_vault: &mut StakingVault<CoinType>,
    voter: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    staking_vault.activate_pending_stakes(round_manager, clock);
    let active_stake = staking_vault.active_stake();

    if (!resolver.voters_state.contains(voter)) {
        let voter_state = VoterState {
            pending_slash: 0,
            pending_dispute_slash: vec_map::empty(),
            pending_round_disputes: vec_map::empty(),
        };

        resolver.voters_state.add(voter, voter_state);
        resolver.cumulative_vote_weight = resolver.cumulative_vote_weight + active_stake;
    };

    let mut total_slash = 0;
    let mut slashes_to_apply = vec_map::empty<ID, u64>();
    let current_round_no = round_manager.current_round(clock, ctx).round_no();

    {
        let dispute_index = &resolver.round_dispute_index;

        sync_voter_round_disputes(
            dispute_index,
            &mut resolver.voters_state[voter],
            current_round_no,
        );
    };

    let mut rounds_to_process = vector[];
    (&resolver.voters_state[voter]).pending_round_disputes.keys().do!(|round| {
        if (round < current_round_no) {
            rounds_to_process.push_back(round);
        };
    });

    rounds_to_process.do!(|round_no| {
        let dispute_ids = *(&resolver.voters_state[voter]).pending_round_disputes.get(&round_no);

        let mut round_slash = 0;
        let mut round_resolved = true;
        let mut disputes_to_remove = vector[];

        dispute_ids.do!(|dispute_id| {
            let dispute_active_round_no = *{ &resolver.disputes[dispute_id].active_round_no };

            let (status, slashing_mode) = {
                let dispute_ref = &resolver.disputes[dispute_id];
                let current_round_no_local = round_manager.current_round_no(clock);
                let status = if (dispute_ref.verification_request.is_some()) {
                    let verification_request = dispute_ref.verification_request.borrow();
                    if (
                        verification_request.state() == verification::verification_request_state_pending()
                    ) {
                        DisputeStatus::Review
                    } else {
                        DisputeStatus::Resolved
                    }
                } else if (is_in_verification_buffer(dispute_ref, clock)) {
                    DisputeStatus::Verification
                } else if (current_round_no_local > dispute_active_round_no) {
                    let temp_round = round_manager.get_round(dispute_active_round_no);
                    if (is_voting_complete_internal(dispute_ref, resolver, temp_round)) {
                        DisputeStatus::Resolved
                    } else if (dispute_ref.rollover_count < default_max_rollover!()) {
                        DisputeStatus::Pending
                    } else {
                        DisputeStatus::Expired
                    }
                } else {
                    DisputeStatus::Pending
                };
                (status, dispute_ref.slashing_mode)
            };

            if (status == DisputeStatus::Verification || status == DisputeStatus::Review) {
                ensure_round_config_initialized(resolver, round_manager, round_no, ctx);
                let round = round_manager.get_round(round_no);
                let round_config = round_config(resolver, round);
                let vote_weight = resolver.get_vote_weight(staking_vault, round, voter);
                let voting_status = voting_status_for_dispute(resolver, round, dispute_id, voter);
                let potential_slash = calculate_slash_weight(
                    vote_weight,
                    round_config.total_eligible_vote_weight,
                    voting_status,
                    &round_config.slashing_config,
                    SlashingMode::Quadratic,
                );

                round_resolved = false;
                add_pending_slash(resolver, voter, potential_slash, dispute_id);
            } else if (status == DisputeStatus::Resolved) {
                remove_pending_slash(resolver, voter, dispute_id);

                ensure_round_config_initialized(resolver, round_manager, round_no, ctx);
                let round = round_manager.get_round(round_no);
                let round_config = round_config(resolver, round);
                let vote_weight = resolver.get_vote_weight(staking_vault, round, voter);
                let voting_status = voting_status_for_dispute(resolver, round, dispute_id, voter);
                let slash_weight = calculate_slash_weight(
                    vote_weight,
                    round_config.total_eligible_vote_weight,
                    voting_status,
                    &round_config.slashing_config,
                    slashing_mode,
                );

                round_slash = round_slash + slash_weight;
                if (slashes_to_apply.contains(&dispute_id)) {
                    let accumulated = slashes_to_apply.get_mut(&dispute_id);
                    *accumulated = *accumulated + slash_weight;
                } else {
                    slashes_to_apply.insert(dispute_id, slash_weight);
                };
                disputes_to_remove.push_back(dispute_id);
            } else if (status == DisputeStatus::Expired) {
                remove_pending_slash(resolver, voter, dispute_id);
                disputes_to_remove.push_back(dispute_id);
            } else {
                round_resolved = false;
            }
        });

        if (!disputes_to_remove.is_empty()) {
            {
                disputes_to_remove.do!(|dispute_id| {
                    let voter_disputes = (
                        &mut resolver.voters_state[voter].pending_round_disputes,
                    ).get_mut(&round_no);
                    let (found, index) = voter_disputes.index_of(&dispute_id);
                    if (found) {
                        voter_disputes.swap_remove(index);
                    };
                });
            };
            disputes_to_remove.do!(|dispute_id| {
                remove_dispute_tracking(resolver, round_no, dispute_id);
                let active_round_no = resolver.disputes[dispute_id].active_round_no;
                if (active_round_no != round_no) {
                    remove_dispute_tracking(resolver, active_round_no, dispute_id);
                };
            });
        };

        let should_remove_round = {
            let voter_disputes = &resolver.voters_state[voter].pending_round_disputes;
            round_resolved || voter_disputes.get(&round_no).is_empty()
        };

        if (should_remove_round) {
            resolver.voters_state[voter].pending_round_disputes.remove(&round_no);
        };

        total_slash = total_slash + round_slash;
    });

    if (total_slash > 0) {
        let mut total_slashed_value = 0;
        slashes_to_apply.keys().do!(|dispute_id| {
            let amount = *slashes_to_apply.get(&dispute_id);
            if (amount == 0) {
                return
            };

            let slashed_balance = staking_vault.slash(round_manager, amount, clock);
            let slashed_value = slashed_balance.value();
            if (slashed_value > 0) {
                total_slashed_value = total_slashed_value + slashed_value;
                let dispute_mut = &mut resolver.disputes[dispute_id];
                dispute_mut.balances.resolver_pool.join(slashed_balance);
            } else {
                slashed_balance.destroy_zero();
            };
        });
    };
}

fun sync_voter_round_disputes(
    dispute_index: &VecMap<u64, vector<ID>>,
    voter_state: &mut VoterState,
    current_round_no: u64,
) {
    dispute_index.keys().do!(|round_no| {
        if (round_no >= current_round_no) return;

        let dispute_ids = &dispute_index[&round_no];
        if (dispute_ids.is_empty()) return;

        if (!voter_state.pending_round_disputes.contains(&round_no)) {
            voter_state.pending_round_disputes.insert(round_no, vector[]);
        };

        let voter_round_disputes = &mut voter_state.pending_round_disputes[&round_no];
        dispute_ids.do_ref!(|dispute_id_ref| {
            if (!voter_round_disputes.contains(dispute_id_ref)) {
                voter_round_disputes.push_back(*dispute_id_ref);
            };
        });
    });
}

fun voting_status_for_dispute<CoinType>(
    resolver: &TruthResolver<CoinType>,
    round: &Round,
    dispute_id: ID,
    voter: address,
): VotingStatus {
    let storage = round.storage(&resolver.resolver_cap);

    let key = VoteKey(dispute_id);
    if (!storage.contains(key)) return VotingStatus::NoVote;

    let vote = storage.borrow<_, Vote>(key);
    voting_status(vote, voter)
}

public fun commit<CoinType>(
    resolver: &mut TruthResolver<CoinType>,
    round_manager: &mut RoundManager,
    staking_vault: &mut StakingVault<CoinType>,
    staking_vault_cap: &StakingVaultCap,
    dispute_handle: &DisputeHandle,
    hash: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let voter_address = ctx.sender();

    let round = round_manager.current_round(clock, ctx);
    assert!(round.is_in_commit_phase(clock), ENotInCommitPhase);
    staking_vault.validate_staking_vault_cap(staking_vault_cap);

    let round_no = round.round_no();

    resolver.process_round_transitions(round_manager, clock, ctx);
    resolver.settle_pending_state_internal(round_manager, staking_vault, voter_address, clock, ctx);
    ensure_round_config_initialized(resolver, round_manager, round_no, ctx);

    let voter_state = &mut resolver.voters_state[voter_address];
    if (voter_state.pending_round_disputes.contains(&round_no)) {
        let disputes = &mut voter_state.pending_round_disputes[&round_no];
        if (!disputes.contains(&dispute_handle.dispute_id)) {
            disputes.push_back(dispute_handle.dispute_id);
        };
    } else {
        voter_state.pending_round_disputes.insert(round_no, vector[dispute_handle.dispute_id]);
    };

    let dispute = &resolver.disputes[dispute_handle.dispute_id];
    let dispute_id_inner = dispute.id.to_inner();
    let dispute_active_round_no = dispute.active_round_no;

    let key = VoteKey(dispute_id_inner);

    // Create tables outside of the round borrow
    let new_commitments = table::new(ctx);
    let new_revealed = table::new(ctx);

    // Now work with the round
    let round_mut = round_manager.current_round_mut(clock, ctx);
    assert!(round_mut.round_no() == dispute_active_round_no, EInvalidDisputeRound);

    let resolver_cap_ref = &resolver.resolver_cap;

    // Check if we need to initialize and do so if needed
    let storage_mut = round_mut.storage_mut(resolver_cap_ref);
    if (!storage_mut.contains(key)) {
        let new_vote = Vote {
            total_votes_weight: 0,
            commitments: new_commitments,
            leading_value: option::none(),
            vote_weights: vec_map::empty(),
            revealed_votes: new_revealed,
        };
        storage_mut.add(key, new_vote);
    } else {
        // Clean up unused tables
        new_commitments.destroy_empty();
        new_revealed.destroy_empty();
    };

    let vote = storage_mut.borrow_mut<_, Vote>(key);
    assert!(!vote.commitments.contains(voter_address), EAlreadyCommitted);
    vote.commitments.add(voter_address, hash);
}

public fun reveal<CoinType>(
    resolver: &mut TruthResolver<CoinType>,
    round_manager: &mut RoundManager,
    staking_vault: &mut StakingVault<CoinType>,
    staking_vault_cap: &StakingVaultCap,
    dispute_handle: &DisputeHandle,
    salt: vector<u8>,
    data: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let voter_address = ctx.sender();

    let current_round = round_manager.current_round(clock, ctx);
    assert!(current_round.is_in_reveal_phase(clock), ENotInRevealPhase);
    staking_vault.validate_staking_vault_cap(staking_vault_cap);

    let round_no = current_round.round_no();
    ensure_round_config_initialized(resolver, round_manager, round_no, ctx);
    let round = round_manager.current_round_mut(clock, ctx);

    // Freeze individual vote weight at reveal time
    // This ensures consistent vote weight within the round, accounting for pending slashes
    let storage_mut = round.storage_mut(&resolver.resolver_cap);
    let vote_weight = if (!storage_mut.contains(VoteWeightKey(voter_address))) {
        // First reveal for this voter in this round - freeze their vote weight
        let effective_weight = calculate_effective_vote_weight(
            resolver,
            staking_vault.active_stake(),
            voter_address,
        );

        // Freeze this power for the remainder of the round
        storage_mut.add(VoteWeightKey(voter_address), effective_weight);
        effective_weight
    } else {
        *storage_mut.borrow<_, u64>(VoteWeightKey(voter_address))
    };

    let dispute = &resolver.disputes[dispute_handle.dispute_id];
    let dispute_id_inner = dispute.id.to_inner();
    let dispute_active_round_no = dispute.active_round_no;
    assert!(round.round_no() == dispute_active_round_no, EInvalidDisputeRound);

    let resolver_cap_ref = &resolver.resolver_cap;
    let vote = round.storage_mut(resolver_cap_ref).borrow_mut<_, Vote>(VoteKey(dispute_id_inner));
    assert!(vote.commitments.contains(voter_address), EDidNotCommit);
    assert!(
        commit_hash!(voter_address, salt, data) == vote.commitments[voter_address],
        EInvalidVote,
    );

    vote.revealed_votes.add(voter_address, data);

    if (!vote.vote_weights.contains(&data)) {
        vote.vote_weights.insert(data, vote_weight);
    } else {
        let vote_weights_mut = vote.vote_weights.get_mut(&data);
        *vote_weights_mut = *vote_weights_mut + vote_weight;
    };

    if (vote.leading_value.is_some()) {
        let leading_value = vote.leading_value.borrow();
        if (vote.vote_weights[&data] > vote.vote_weights[leading_value]) {
            vote.leading_value = option::some(data)
        }
    } else {
        vote.leading_value.fill(data)
    };

    vote.total_votes_weight = vote.total_votes_weight + vote_weight;
}

public fun create_staking_vault<CoinType>(
    resolver: &mut TruthResolver<CoinType>,
    initial_stake: Coin<CoinType>,
    round_manager: &RoundManager,
    clock: &Clock,
    ctx: &mut TxContext,
): StakingVaultCap {
    let sender = ctx.sender();
    let (staking_vault, cap) = staking_vault::new(
        &mut resolver.id,
        initial_stake,
        round_manager,
        clock,
        ctx,
    );

    if (!resolver.voters_state.contains(sender)) {
        let voter_state = VoterState {
            pending_slash: 0,
            pending_dispute_slash: vec_map::empty(),
            pending_round_disputes: vec_map::empty(),
        };

        resolver.voters_state.add(sender, voter_state);
    };

    staking_vault.share_staking_vault();

    cap
}

public fun add_stake<CoinType>(
    cap: &StakingVaultCap,
    vault: &mut StakingVault<CoinType>,
    stake: Coin<CoinType>,
    round_manager: &RoundManager,
    clock: &Clock,
) { vault.validate_staking_vault_cap(cap); vault.add_stake(stake, round_manager, clock); }

public fun complete_withdrawal<CoinType>(
    staking_vault: &mut StakingVault<CoinType>,
    round_manager: &RoundManager,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<CoinType> {
    staking_vault.complete_withdrawal(round_manager, clock, ctx)
}

public fun request_withdrawal<CoinType>(
    resolver: &mut TruthResolver<CoinType>,
    round_manager: &mut RoundManager,
    staking_vault: &mut StakingVault<CoinType>,
    staking_vault_cap: &StakingVaultCap,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    resolver.settle_pending_state_internal(round_manager, staking_vault, ctx.sender(), clock, ctx);

    let sender = ctx.sender();
    if (resolver.voters_state.contains(sender)) {
        let voter_state = &resolver.voters_state[sender];
        assert!(voter_state.pending_slash == 0, EPendingSlashExists);
    };

    staking_vault.request_withdrawal(staking_vault_cap, round_manager, amount, clock);
}

public fun add_committee_member<CoinType>(
    resolver: &mut TruthResolver<CoinType>,
    _: &TruthResolverCap<CoinType>,
    new_member: address,
) {
    resolver.verification_committee.add_committee_member(new_member);
}

public fun remove_committee_member<CoinType>(
    resolver: &mut TruthResolver<CoinType>,
    _: &TruthResolverCap<CoinType>,
    member: address,
) {
    resolver.verification_committee.remove_committee_member(member);
}

public fun update_committee_threshold<CoinType>(
    resolver: &mut TruthResolver<CoinType>,
    _: &TruthResolverCap<CoinType>,
    new_threshold: u64,
) {
    resolver.verification_committee.update_committee_threshold(new_threshold);
}

public fun update_slashing_config<CoinType>(
    resolver: &mut TruthResolver<CoinType>,
    _: &TruthResolverCap<CoinType>,
    new_config: SlashingConfig,
) {
    resolver.slashing_config = new_config;
}

public fun update_verification_buffer<CoinType>(
    resolver: &mut TruthResolver<CoinType>,
    _: &TruthResolverCap<CoinType>,
    new_buffer_ms: u64,
) {
    resolver.verification_buffer_ms = new_buffer_ms;
}

public fun withdraw_verification_bonds<CoinType>(
    resolver: &mut TruthResolver<CoinType>,
    dispute_handle: &DisputeHandle,
    amount: u64,
    ctx: &mut TxContext,
): Coin<CoinType> {
    let dispute = &mut resolver.disputes[dispute_handle.dispute_id];
    dispute.balances.verification_bond_pool.split(amount).into_coin(ctx)
}

fun ensure_round_storage_initialized<CoinType>(
    resolver: &TruthResolver<CoinType>,
    target_round: &mut Round,
    ctx: &mut TxContext,
) {
    if (!round::is_storage_initialized(target_round, &resolver.resolver_cap)) {
        round::initialize_storage(target_round, &resolver.resolver_cap, ctx);
    };
}

fun remove_dispute_tracking<CoinType>(
    resolver: &mut TruthResolver<CoinType>,
    round_no: u64,
    dispute_id: ID,
) {
    if (resolver.pending_round_disputes.contains(&round_no)) {
        let should_drop_round = {
            let round_disputes = &mut resolver.pending_round_disputes[&round_no];
            let (found, index) = round_disputes.index_of(&dispute_id);
            if (found) {
                round_disputes.swap_remove(index);
            };
            round_disputes.length() == 0
        };

        if (should_drop_round) {
            resolver.pending_round_disputes.remove(&round_no);
        };
    };

    if (resolver.round_dispute_index.contains(&round_no)) {
        let should_drop_index = {
            let round_index = &mut resolver.round_dispute_index[&round_no];
            let (found, index) = round_index.index_of(&dispute_id);
            if (found) {
                round_index.swap_remove(index);
            };
            round_index.length() == 0
        };

        if (should_drop_index) {
            resolver.round_dispute_index.remove(&round_no);
        };
    };
}

fun freeze_round_config<CoinType>(
    resolver: &TruthResolver<CoinType>,
    round: &mut Round,
    ctx: &mut TxContext,
) {
    ensure_round_storage_initialized(resolver, round, ctx);
    let storage = round.storage_mut(&resolver.resolver_cap);

    if (!storage.contains(RoundConfigKey())) {
        let total_eligible_vote_weight = if (
            resolver.total_pending_slash >= resolver.cumulative_vote_weight
        ) {
            0
        } else {
            resolver.cumulative_vote_weight - resolver.total_pending_slash
        };
        let round_config = RoundConfig {
            slashing_config: resolver.slashing_config,
            min_consensus_rate_bps: default_min_consensus_rate_bps!(),
            total_eligible_vote_weight,
            min_participation_rate_bps: default_min_participation_rate_bps!(),
            verification_buffer_ms: resolver.verification_buffer_ms,
        };

        storage.add(RoundConfigKey(), round_config)
    };
}

fun ensure_round_config_initialized<CoinType>(
    resolver: &TruthResolver<CoinType>,
    round_manager: &mut RoundManager,
    round_no: u64,
    ctx: &mut TxContext,
) {
    let round_mut = round_manager.get_round_mut(round_no);
    freeze_round_config(resolver, round_mut, ctx);
}

public fun dispute_status<CoinType>(
    resolver: &TruthResolver<CoinType>,
    round_manager: &mut RoundManager,
    dispute: &Dispute<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
): DisputeStatus {
    ensure_round_config_initialized(resolver, round_manager, dispute.active_round_no, ctx);
    let current_round = round_manager.current_round(clock, ctx);
    let dispute_round = round_manager.get_round(dispute.active_round_no);

    dispute_status_internal(resolver, dispute, current_round, dispute_round, clock)
}

fun dispute_status_internal<CoinType>(
    resolver: &TruthResolver<CoinType>,
    dispute: &Dispute<CoinType>,
    current_round: &Round,
    dispute_round: &Round,
    clock: &Clock,
): DisputeStatus {
    // Check if dispute has verification request under review
    if (dispute.verification_request.is_some()) {
        let verification_request = dispute.verification_request.borrow();
        if (verification_request.state() == verification::verification_request_state_pending()) {
            return DisputeStatus::Review
        };
        // Verification request was resolved
        return DisputeStatus::Resolved
    };

    // Check if dispute is in verification buffer
    if (is_in_verification_buffer(dispute, clock)) {
        return DisputeStatus::Verification
    };

    if (current_round.round_no() == dispute.active_round_no) {
        // Still in the same round - voting may be ongoing
        if (is_voting_complete_internal(dispute, resolver, dispute_round)) {
            // Voting complete but verification buffer not set yet (shouldn't happen normally)
            return DisputeStatus::Voting
        };
        return DisputeStatus::Voting
    };

    if (current_round.round_no() > dispute.active_round_no) {
        if (is_voting_complete_internal(dispute, resolver, dispute_round)) {
            // Voting complete and verification buffer expired
            return DisputeStatus::Resolved
        };

        // If voting not complete and max rollovers not reached, still pending for next round
        if (dispute.rollover_count < default_max_rollover!()) {
            return DisputeStatus::Pending
        };

        return DisputeStatus::Expired
    };

    DisputeStatus::Pending
}

fun is_voting_complete_internal<CoinType>(
    dispute: &Dispute<CoinType>,
    resolver: &TruthResolver<CoinType>,
    round: &Round,
): bool {
    let storage = round.storage(&resolver.resolver_cap);
    if (!storage.contains(RoundConfigKey())) {
        return false
    };

    let cfg = storage.borrow<_, RoundConfig>(RoundConfigKey());
    let vote_key = VoteKey(dispute.id.to_inner());
    if (!storage.contains(vote_key)) {
        return false
    };

    let vote = storage.borrow<_, Vote>(vote_key);

    if (cfg.total_eligible_vote_weight == 0) return false;

    let participation_rate_bps = (
        vote.total_votes_weight * bps!() / cfg.total_eligible_vote_weight,
    );
    let consensus_rate_bps = if (vote.leading_value.is_some()) {
        let leading_value = vote.leading_value.borrow();
        (vote.vote_weights[leading_value] * bps!() / cfg.total_eligible_vote_weight)
    } else { 0 };

    return participation_rate_bps >= cfg.min_participation_rate_bps && 
                         consensus_rate_bps >= cfg.min_consensus_rate_bps
}

public fun is_voting_complete<CoinType>(
    dispute_handle: &DisputeHandle,
    resolver: &TruthResolver<CoinType>,
    round_manager: &RoundManager,
): bool {
    let dispute = &resolver.disputes[dispute_handle.dispute_id];
    let round = round_manager.get_round(dispute.active_round_no);
    is_voting_complete_internal(dispute, resolver, round)
}

public fun is_in_verification_buffer<CoinType>(dispute: &Dispute<CoinType>, clock: &Clock): bool {
    if (dispute.verification_ends_at_ms.is_none()) {
        return false
    };

    clock.timestamp_ms() <= *dispute.verification_ends_at_ms.borrow()
}

fun voting_status(vote: &Vote, voter: address): VotingStatus {
    if (!vote.revealed_votes.contains(voter)) return VotingStatus::NoVote;

    if (vote.leading_value.is_some()) {
        if (vote.revealed_votes[voter] == *vote.leading_value.borrow()) {
            return VotingStatus::CorrectVote
        };
    };

    VotingStatus::WrongVote
}

/// Calculate effective vote weight for a voter, accounting for pending slashes
///
/// Pending slashes represent stake that's under verification due to verification
/// of past disputes. This stake gets reduced vote weight to prevent double-spending
/// while the verification is ongoing.
fun calculate_effective_vote_weight<CoinType>(
    resolver: &TruthResolver<CoinType>,
    base_vote_weight: u64,
    voter: address,
): u64 {
    if (resolver.voters_state.contains(voter)) {
        let voter_state = &resolver.voters_state[voter];

        if (voter_state.pending_slash > base_vote_weight) return 0;
        return base_vote_weight - voter_state.pending_slash
    };

    base_vote_weight
}

fun add_pending_slash<CoinType>(
    resolver: &mut TruthResolver<CoinType>,
    voter: address,
    potential_slash: u64,
    dispute_id: ID,
) {
    let voter_state = &mut resolver.voters_state[voter];
    if (!voter_state.pending_dispute_slash.contains(&dispute_id)) {
        voter_state.pending_slash = voter_state.pending_slash + potential_slash;
        voter_state.pending_dispute_slash.insert(dispute_id, potential_slash);
        resolver.total_pending_slash = resolver.total_pending_slash + potential_slash;
    };
}

fun remove_pending_slash<CoinType>(
    resolver: &mut TruthResolver<CoinType>,
    voter: address,
    dispute_id: ID,
): u64 {
    let voter_state = &mut resolver.voters_state[voter];
    if (voter_state.pending_dispute_slash.contains(&dispute_id)) {
        let pending_amount = *voter_state.pending_dispute_slash.get(&dispute_id);
        voter_state.pending_dispute_slash.remove(&dispute_id);
        voter_state.pending_slash = voter_state.pending_slash - pending_amount;
        resolver.total_pending_slash = resolver.total_pending_slash - pending_amount;

        return pending_amount
    };
    0
}

/// Get vote weight for a voter in a specific round
///
/// Voting power is frozen at reveal time to ensure consistency within the round.
/// If not frozen yet, calculates dynamically including pending slash deductions.
public fun get_vote_weight<CoinType>(
    resolver: &TruthResolver<CoinType>,
    staking_vault: &StakingVault<CoinType>,
    round: &Round,
    voter: address,
): u64 {
    let storage = round.storage(&resolver.resolver_cap);

    // Check if vote weight is already frozen for this voter in this round
    if (storage.contains(VoteWeightKey(voter))) {
        return *storage.borrow<_, u64>(VoteWeightKey(voter))
    };

    // This should only happen during commit phase before reveal
    calculate_effective_vote_weight(resolver, staking_vault.active_stake(), voter)
}

public fun get_vote<CoinType>(
    resolver: &TruthResolver<CoinType>,
    round: &Round,
    dispute_id: ID,
): &Vote {
    let storage = round.storage(&resolver.resolver_cap);
    let key = VoteKey(dispute_id);
    assert!(storage.contains(key), EVoteNotInitialized);
    storage.borrow<_, Vote>(key)
}

fun get_or_initialize_vote_mut_internal(
    resolver_cap: &ResolverCap,
    round: &mut Round,
    dispute_id: ID,
    ctx: &mut TxContext,
): &mut Vote {
    let key = VoteKey(dispute_id);
    let storage_mut = round.storage_mut(resolver_cap);
    if (!storage_mut.contains(key)) {
        storage_mut.add(
            key,
            Vote {
                total_votes_weight: 0,
                commitments: table::new(ctx),
                leading_value: option::none(),
                vote_weights: vec_map::empty(),
                revealed_votes: table::new(ctx),
            },
        );
    };

    storage_mut.borrow_mut<_, Vote>(key)
}

public fun get_or_initialize_vote_mut<CoinType>(
    resolver: &TruthResolver<CoinType>,
    round: &mut Round,
    dispute_id: ID,
    ctx: &mut TxContext,
): &mut Vote {
    get_or_initialize_vote_mut_internal(&resolver.resolver_cap, round, dispute_id, ctx)
}

public fun get_vote_mut<CoinType>(
    resolver: &TruthResolver<CoinType>,
    round: &mut Round,
    dispute_id: ID,
): &mut Vote {
    round.storage_mut(&resolver.resolver_cap).borrow_mut<_, Vote>(VoteKey(dispute_id))
}

fun round_config<CoinType>(resolver: &TruthResolver<CoinType>, round: &Round): &RoundConfig {
    round.storage(&resolver.resolver_cap).borrow<_, RoundConfig>(RoundConfigKey())
}

public fun request_verification<CoinType>(
    resolver: &mut TruthResolver<CoinType>,
    round_manager: &mut RoundManager,
    dispute_handle: &DisputeHandle,
    bond: Coin<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let dispute = &resolver.disputes[dispute_handle.dispute_id];
    ensure_round_config_initialized(resolver, round_manager, dispute.active_round_no, ctx);
    let current_round = round_manager.current_round(clock, ctx);
    let dispute_round = round_manager.get_round(dispute.active_round_no);

    let status = dispute_status_internal(resolver, dispute, current_round, dispute_round, clock);

    assert!(dispute.verification_request.is_none(), EChallengeAlreadyExists);
    assert!(status == DisputeStatus::Verification, ENotInVerificationBuffer);
    assert!(bond.value() >= dispute.min_bond_amount, EInsufficientVerificationRequestBond);
    assert!(is_in_verification_buffer(dispute, clock), ENotInVerificationBuffer);

    let verification_request = verification::request_verification(
        bond.into_balance(),
        clock,
        ctx,
    );

    (&mut resolver.disputes[dispute_handle.dispute_id])
        .verification_request
        .fill(verification_request);
    resolver.verification_committee.initialize_review(dispute_handle.dispute_id);
}

public fun cast_verification_vote<CoinType>(
    resolver: &mut TruthResolver<CoinType>,
    round_manager: &mut RoundManager,
    dispute_handle: &DisputeHandle,
    // using vector<u8> for future extensibility, we could change the mechanism later
    truth: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // let dispute_status = resolver.dispute_status(round_manager, dispute_handle.dispute_id, clock);

    let dispute = &resolver.disputes[dispute_handle.dispute_id];
    ensure_round_config_initialized(resolver, round_manager, dispute.active_round_no, ctx);
    let current_round = round_manager.current_round(clock, ctx);
    let dispute_round = round_manager.get_round(dispute.active_round_no);

    let dispute_status = dispute_status_internal(
        resolver,
        dispute,
        current_round,
        dispute_round,
        clock,
    );

    assert!(dispute_status == DisputeStatus::Review, 0);

    let dispute_id = dispute_handle.dispute_id;
    let dispute_mut = &mut resolver.disputes[dispute_handle.dispute_id];
    {
        let verification_request = dispute_mut.verification_request.borrow_mut();
        resolver.verification_committee.cast_vote(verification_request, dispute_id, truth, ctx);
    };

    let verification_state = {
        let verification_request = dispute_mut.verification_request.borrow();
        verification_request.state()
    };

    // If the verification state is "accepted", meaning that the verification requester was correct about a manipulation,
    // the slashing mode is set to "SlashingMode::Quadratic".
    // This will apply quadratic slashing to all correct votes from the voting stage, this is because the correct votes from the voting stage
    // were supposed to be wrong but manipulation by some voters made the voting mechanisms think them as correct, so the verification layer
    // here helps us know they're actually wrong and should be quadratically slashed.
    if (verification_state == verification::verification_request_state_accepted()) {
        dispute_mut.slashing_mode = SlashingMode::Quadratic;
    };

    if (verification_state != verification::verification_request_state_pending()) {
        let (requester, bond_balance) = verification::take_request_data(
            &mut dispute_mut.verification_request,
        );

        if (verification_state == verification::verification_request_state_accepted()) {
            let coin = bond_balance.into_coin(ctx);
            sui::transfer::public_transfer(coin, requester);
        } else {
            dispute_mut.balances.verification_bond_pool.join(bond_balance);
        };
    };
}

fun calculate_slash_weight(
    vote_weight: u64,
    total_eligible_vote_weight: u64,
    status: VotingStatus,
    config: &SlashingConfig,
    mode: SlashingMode,
): u64 {
    let slashing_rate_bps = match (mode) {
        SlashingMode::Linear => match (status) {
            VotingStatus::WrongVote => config.wrong_vote_slashing_bps,
            VotingStatus::NoVote => config.no_vote_slashing_bps,
            VotingStatus::CorrectVote => 0,
        },
        SlashingMode::Quadratic => {
            if (total_eligible_vote_weight == 0) return 0;
            let vote_weight_bps = (vote_weight * bps!()) / total_eligible_vote_weight;

            let quadratic_slashing_rate = if (vote_weight_bps >= config.quadratic_threshold_bps) {
                let ratio_bps = (vote_weight_bps * bps!()) / config.quadratic_threshold_bps;
                let quadratic_multiplier = (ratio_bps * ratio_bps) / bps!();
                (config.wrong_vote_slashing_bps * quadratic_multiplier) / bps!()
            } else {
                config.wrong_vote_slashing_bps
            };

            // Quadratic slashing mode being set means that the verification succeeded in verifying that a manipulation was attempted,
            // so voters with the "correct" (obv manipulated) votes are slashed.
            match (status) {
                VotingStatus::WrongVote => 0,
                VotingStatus::NoVote => config.no_vote_slashing_bps,
                VotingStatus::CorrectVote => quadratic_slashing_rate,
            }
        },
    };

    let slash_amount = (vote_weight * slashing_rate_bps) / bps!();
    if (slash_amount > vote_weight) {
        vote_weight
    } else {
        slash_amount
    }
}

macro fun default_no_vote_slashing_bps(): u64 {
    200
}

macro fun default_wrong_vote_slashing_bps(): u64 {
    500
}

macro fun default_base_slashing_rate_bps(): u64 {
    200
}

macro fun default_quadratic_threshold_bps(): u64 {
    1000
}

macro fun default_max_rollover(): u64 {
    3
}

macro fun bps(): u64 {
    10_000
}

macro fun default_min_consensus_rate_bps(): u64 {
    69_00
}

macro fun default_min_participation_rate_bps(): u64 {
    51_00
}

macro fun default_verification_buffer_ms(): u64 {
    2 * 60 * 60 * 1000 // 2 hours in milliseconds
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
