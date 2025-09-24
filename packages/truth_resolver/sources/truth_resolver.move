module truth_resolver::truth_resolver;

use reef::epoch::{Epoch, EpochManager};
use reef::resolver::{Self, ResolverCap, DisputeTicket};
use sui::clock::Clock;
use sui::coin::Coin;
use sui::derived_object;
use sui::hash;
use sui::object_table::{Self, ObjectTable};
use sui::package::{Self, Publisher};
use sui::sui::SUI;
use sui::table::{Self, Table};
use sui::vec_map::{Self, VecMap};
use truth_resolver::staking_vault::{StakingVault, StakingVaultCap};
use truth_resolver::verification::{Self, VerificationCommittee, VerificationRequest};

public struct TruthResolver has key {
    id: UID,
    resolver_cap: ResolverCap,
    cumulative_vote_weight: u64,
    total_pending_slash: u64,
    slashing_config: SlashingConfig,
    disputes: ObjectTable<ID, Dispute>,
    voters_state: Table<address, VoterState>,
    verification_committee: VerificationCommittee,
    pending_epoch_disputes: VecMap<u64, vector<ID>>,
}

public struct Dispute has key, store {
    id: UID,
    query_id: ID,
    min_bond_amount: u64,
    created_at_ms: u64,
    rollover_count: u64,
    active_epoch_no: u64,
    slashing_mode: SlashingMode,
    resolved_data: Option<vector<u8>>,
    verification_request: Option<VerificationRequest<SUI>>,
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
    pending_epoch_disputes: VecMap<u64, vector<ID>>,
}

public struct EpochConfig has copy, drop, store {
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
public struct EpochConfigKey() has copy, drop, store;
public struct VoteWeightKey(address) has copy, drop, store;

const EInvalidPublisher: u64 = 0;
const EAlreadyCommitted: u64 = 1;
const EDidNotCommit: u64 = 2;
const EInvalidVote: u64 = 3;
const ENotInCommitPhase: u64 = 4;
const ENotInRevealPhase: u64 = 5;
const ENotInVerificationBuffer: u64 = 6;
const EInsufficientVerificationRequestBond: u64 = 7;
const EChallengeAlreadyExists: u64 = 8;
const EInvalidDisputeEpoch: u64 = 9;

fun init(otw: TRUTH_RESOLVER, ctx: &mut TxContext) {
    package::claim_and_keep(otw, ctx)
}

public fun create(
    publisher: Publisher,
    members: vector<address>,
    threshold: u64,
    ctx: &mut TxContext,
): TruthResolver {
    assert!(publisher.from_module<TRUTH_RESOLVER>(), EInvalidPublisher);

    let (resolver, resolver_cap) = resolver::create(Witness(), publisher, ctx);
    resolver.share();

    TruthResolver {
        id: object::new(ctx),
        resolver_cap,
        cumulative_vote_weight: 0,
        total_pending_slash: 0,
        voters_state: table::new(ctx),
        disputes: object_table::new(ctx),
        pending_epoch_disputes: vec_map::empty(),
        slashing_config: SlashingConfig {
            no_vote_slashing_bps: default_no_vote_slashing_bps!(),
            base_slashing_rate_bps: default_base_slashing_rate_bps!(),
            wrong_vote_slashing_bps: default_wrong_vote_slashing_bps!(),
            quadratic_threshold_bps: default_quadratic_threshold_bps!(),
        },
        verification_committee: verification::new_committee(threshold, members, ctx),
    }
}

public fun create_dispute<CoinType>(
    resolver: &mut TruthResolver,
    epoch_manager: &EpochManager,
    ticket: DisputeTicket<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
): DisputeHandle {
    let current_epoch_no = epoch_manager.current_epoch_no(clock);
    let (query_id, fee, _, disputed_at_ms, _) = ticket.unpack(Witness());
    fee.destroy_zero();

    let mut dispute = Dispute {
        id: object::new(ctx),
        query_id,
        rollover_count: 0,
        min_bond_amount: 0, // TODO: set from ticket
        resolved_data: option::none(),
        created_at_ms: disputed_at_ms,
        active_epoch_no: current_epoch_no,
        slashing_mode: SlashingMode::Linear,
        verification_request: option::none(),
    };

    let dispute_id = dispute.id.to_inner();
    let handle = DisputeHandle {
        id: derived_object::claim(&mut dispute.id, query_id.to_bytes()),
        dispute_id: dispute_id,
    };

    resolver.disputes.add(dispute_id, dispute);
    if (resolver.pending_epoch_disputes.contains(&current_epoch_no)) {
        (&mut resolver.pending_epoch_disputes[&current_epoch_no]).push_back(dispute_id);
    } else {
        resolver.pending_epoch_disputes.insert(current_epoch_no, vector[dispute_id]);
    };

    handle
}

public fun process_epoch_transitions(
    resolver: &mut TruthResolver,
    epoch_manager: &EpochManager,
    clock: &Clock,
) {
    let current_epoch = epoch_manager.current_epoch(clock);

    let mut epochs_to_process = vector[];
    resolver.pending_epoch_disputes.keys().do!(|epoch_no| {
        if (epoch_no < current_epoch.epoch_no()) {
            epochs_to_process.push_back(epoch_no);
        }
    });

    epochs_to_process.do!(|epoch_no| {
        let mut resolved_disputes = vector[];
        let mut rolled_over_disputes = vector[];

        resolver.pending_epoch_disputes[&epoch_no].do_ref!(|dispute_id_ref| {
            let dispute_id = *dispute_id_ref;
            let dispute = &resolver.disputes[dispute_id];
            let dispute_epoch = epoch_manager.get_epoch(dispute.active_epoch_no);

            if (!dispute.is_voting_complete_internal(resolver, dispute_epoch)) {
                if (dispute.rollover_count < default_max_rollover!()) {
                    let dispute_mut = &mut resolver.disputes[dispute_id];
                    dispute_mut.active_epoch_no = current_epoch.epoch_no();
                    dispute_mut.rollover_count = dispute_mut.rollover_count + 1;
                    rolled_over_disputes.push_back(dispute_id);
                } else {
                    resolved_disputes.push_back(dispute_id);
                }
            } else {
                let dispute_epoch = epoch_manager.get_epoch(dispute.active_epoch_no);
                let status = resolver.dispute_status_internal(
                    dispute,
                    current_epoch,
                    dispute_epoch,
                    clock,
                );

                if (status == DisputeStatus::Resolved || status == DisputeStatus::Expired) {
                    resolved_disputes.push_back(dispute_id);
                }
            }
        });

        if (!resolved_disputes.is_empty()) {
            resolved_disputes.do!(|dispute_id| {
                let epoch_disputes = &mut resolver.pending_epoch_disputes[&epoch_no];
                let (found, index) = epoch_disputes.index_of(&dispute_id);
                if (found) {
                    epoch_disputes.swap_remove(index);
                };
            });
        };

        let current_epoch_no = current_epoch.epoch_no();
        if (!rolled_over_disputes.is_empty()) {
            if (resolver.pending_epoch_disputes.contains(&current_epoch_no)) {
                resolver
                    .pending_epoch_disputes
                    .get_mut(&current_epoch_no)
                    .append(rolled_over_disputes);
            } else {
                resolver.pending_epoch_disputes.insert(current_epoch_no, rolled_over_disputes);
            }
        };

        if (resolver.pending_epoch_disputes[&epoch_no].length() == 0) {
            resolver.pending_epoch_disputes.remove(&epoch_no);
        }
    });
}

public fun settle_pending_state<CoinType>(
    resolver: &mut TruthResolver,
    epoch_manager: &mut EpochManager,
    staking_vault: &mut StakingVault<CoinType>,
    voter: address,
    clock: &Clock,
) {
    staking_vault.activate_pending_stakes(epoch_manager, clock);

    if (!resolver.voters_state.contains(voter)) {
        let voter_state = VoterState {
            pending_slash: 0,
            pending_dispute_slash: vec_map::empty(),
            pending_epoch_disputes: vec_map::empty(),
        };

        resolver.voters_state.add(voter, voter_state);
        return
    };

    let mut total_slash = 0;
    let current_epoch_no = epoch_manager.current_epoch(clock).epoch_no();

    let epochs_to_process = (&resolver.voters_state[voter])
        .pending_epoch_disputes
        .keys()
        .filter!(|epoch| *epoch < current_epoch_no);

    epochs_to_process.do!(|epoch_no| {
        let dispute_ids = *(&resolver.voters_state[voter]).pending_epoch_disputes.get(&epoch_no);
        let epoch = epoch_manager.get_epoch(epoch_no);

        let mut epoch_slash = 0;
        let mut epoch_resolved = true;
        let mut disputes_to_remove = vector[];
        let epoch_config = resolver.epcoch_config!(epoch);
        let vote_weight = resolver.get_vote_weight(epoch, voter);

        dispute_ids.do!(|dispute_id| {
            let dispute = &resolver.disputes[dispute_id];
            let current_epoch = epoch_manager.current_epoch(clock);
            let dispute_epoch = epoch_manager.get_epoch(dispute.active_epoch_no);
            let status = resolver.dispute_status_internal(
                dispute,
                current_epoch,
                dispute_epoch,
                clock,
            );

            if (status == DisputeStatus::Verification || status == DisputeStatus::Review) {
                let vote = resolver.get_vote(epoch, dispute_id);
                let voting_status = vote.voting_status(voter);
                let potential_slash = calculate_slash_weight(
                    vote_weight,
                    epoch_config.total_eligible_vote_weight,
                    voting_status,
                    &epoch_config.slashing_config,
                    SlashingMode::Quadratic,
                );

                epoch_resolved = false;
                resolver.add_pending_slash!(voter, potential_slash, dispute_id);
            } else if (status == DisputeStatus::Resolved) {
                resolver.remove_pending_slash!(voter, dispute_id);

                let vote = resolver.get_vote(epoch, dispute_id);
                let voting_status = vote.voting_status(voter);
                let slash_weight = calculate_slash_weight(
                    vote_weight,
                    epoch_config.total_eligible_vote_weight,
                    voting_status,
                    &epoch_config.slashing_config,
                    dispute.slashing_mode,
                );

                epoch_slash = epoch_slash + slash_weight;
                disputes_to_remove.push_back(dispute_id);
            } else if (status == DisputeStatus::Expired) {
                resolver.remove_pending_slash!(voter, dispute_id);
                disputes_to_remove.push_back(dispute_id);
            } else {
                epoch_resolved = false;
            }
        });

        if (!disputes_to_remove.is_empty()) {
            disputes_to_remove.do!(|dispute_id| {
                let voter_disputes = (
                    &mut resolver.voters_state[voter].pending_epoch_disputes,
                ).get_mut(&epoch_no);
                let (found, index) = voter_disputes.index_of(&dispute_id);
                if (found) {
                    voter_disputes.swap_remove(index);
                };
            });
        };

        let should_remove_epoch = {
            let voter_disputes = &resolver.voters_state[voter].pending_epoch_disputes;
            epoch_resolved || voter_disputes.get(&epoch_no).is_empty()
        };

        if (should_remove_epoch) {
            resolver.voters_state[voter].pending_epoch_disputes.remove(&epoch_no);
        };

        total_slash = total_slash + epoch_slash;
    });

    if (total_slash > 0) {
        let slash = staking_vault.slash(epoch_manager, total_slash, clock);
        slash.destroy_zero();
    };
}

public fun commit<CoinType>(
    resolver: &mut TruthResolver,
    epoch_manager: &mut EpochManager,
    staking_vault: &mut StakingVault<CoinType>,
    staking_vault_cap: &StakingVaultCap,
    dispute_handle: &DisputeHandle,
    hash: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let epoch = epoch_manager.current_epoch(clock);
    assert!(epoch.is_in_commit_phase(clock), ENotInCommitPhase);
    staking_vault.validate_staking_vault_cap(staking_vault_cap);

    let epoch_no = epoch.epoch_no();
    let voter_address = ctx.sender();

    resolver.process_epoch_transitions(epoch_manager, clock);
    resolver.settle_pending_state(epoch_manager, staking_vault, voter_address, clock);

    let voter_state = &mut resolver.voters_state[voter_address];
    if (voter_state.pending_epoch_disputes.contains(&epoch_no)) {
        let disputes = &mut voter_state.pending_epoch_disputes[&epoch_no];
        if (!disputes.contains(&dispute_handle.dispute_id)) {
            disputes.push_back(dispute_handle.dispute_id);
        };
    } else {
        voter_state.pending_epoch_disputes.insert(epoch_no, vector[dispute_handle.dispute_id]);
    };

    let dispute = &resolver.disputes[dispute_handle.dispute_id];

    let epoch_mut = epoch_manager.current_epoch_mut(clock);
    assert!(epoch_mut.epoch_no() == dispute.active_epoch_no, EInvalidDisputeEpoch);

    let vote = resolver.get_or_initialize_vote_mut(epoch_mut, dispute.id.to_inner(), ctx);
    assert!(!vote.commitments.contains(voter_address), EAlreadyCommitted);

    vote.commitments.add(voter_address, hash);
}

public fun reveal(
    resolver: &mut TruthResolver,
    epoch_manager: &mut EpochManager,
    dispute_handle: &DisputeHandle,
    salt: vector<u8>,
    data: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let epoch = epoch_manager.current_epoch_mut(clock);
    assert!(epoch.is_in_reveal_phase(clock), ENotInRevealPhase);

    resolver.freeze_epoch_config(epoch);

    let voter_address = ctx.sender();

    // Freeze individual vote weight at reveal time
    // This ensures consistent vote weight within the epoch, accounting for pending slashes
    let storage_mut = epoch.storage_mut(&resolver.resolver_cap);
    let vote_weight = if (!storage_mut.contains(VoteWeightKey(voter_address))) {
        // First reveal for this voter in this epoch - freeze their vote weight
        // TODO: Get actual base weight from staking vault instead of using placeholder
        let base_weight = resolver.cumulative_vote_weight; // Placeholder - should be voter's actual stake
        let effective_weight = calculate_effective_vote_weight(
            resolver,
            base_weight,
            voter_address,
        );

        // Freeze this power for the remainder of the epoch
        storage_mut.add(VoteWeightKey(voter_address), effective_weight);
        effective_weight
    } else {
        // Power already frozen for this voter - use the frozen value
        *storage_mut.borrow<_, u64>(VoteWeightKey(voter_address))
    };

    let dispute = &resolver.disputes[dispute_handle.dispute_id];
    assert!(epoch.epoch_no() == dispute.active_epoch_no, EInvalidDisputeEpoch);

    let vote = resolver.get_vote_mut(epoch, dispute.id.to_inner());
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

public fun request_withdrawal<CoinType>(
    resolver: &mut TruthResolver,
    epoch_manager: &mut EpochManager,
    staking_vault: &mut StakingVault<CoinType>,
    staking_vault_cap: &StakingVaultCap,
    amount: u64,
    clock: &Clock,
    ctx: TxContext,
) {
    resolver.settle_pending_state(epoch_manager, staking_vault, ctx.sender(), clock);
    staking_vault.request_withdrawal(staking_vault_cap, epoch_manager, amount, clock)
}

fun freeze_epoch_config(resolver: &TruthResolver, epoch: &mut Epoch) {
    let storage = epoch.storage_mut(&resolver.resolver_cap);
    if (!storage.contains(EpochConfigKey())) {
        let epoch_config = EpochConfig {
            slashing_config: resolver.slashing_config,
            min_consensus_rate_bps: default_min_consensus_rate_bps!(),
            total_eligible_vote_weight: resolver.cumulative_vote_weight - resolver.total_pending_slash,
            min_participation_rate_bps: default_min_participation_rate_bps!(),
        };

        storage.add(EpochConfigKey(), epoch_config)
    };
}

public fun dispute_status(
    resolver: &TruthResolver,
    epoch_manager: &EpochManager,
    dispute: &Dispute,
    clock: &Clock,
): DisputeStatus {
    let current_epoch = epoch_manager.current_epoch(clock);
    let dispute_epoch = epoch_manager.get_epoch(dispute.active_epoch_no);

    resolver.dispute_status_internal(dispute, current_epoch, dispute_epoch, clock)
}

fun dispute_status_internal(
    resolver: &TruthResolver,
    dispute: &Dispute,
    current_epoch: &Epoch,
    dispute_epoch: &Epoch,
    clock: &Clock,
): DisputeStatus {
    if (current_epoch.epoch_no() == dispute.active_epoch_no) {
        if (is_voting_complete_internal(dispute, resolver, dispute_epoch)) {
            if (dispute_epoch.is_in_verification_phase(clock)) {
                return DisputeStatus::Verification
            };

            return DisputeStatus::Voting
        };

        return DisputeStatus::Voting
    };

    if (current_epoch.epoch_no() > dispute.active_epoch_no) {
        if (dispute.verification_request.is_some()) {
            let verification_request = dispute.verification_request.borrow();
            if (
                verification_request.state() == verification::verification_request_state_pending()
            ) {
                return DisputeStatus::Review
            };

            return DisputeStatus::Resolved
        };

        if (is_voting_complete_internal(dispute, resolver, dispute_epoch)) {
            return DisputeStatus::Resolved
        };

        // If voting not complete and max rollovers not reached, still pending for next epoch
        if (dispute.rollover_count < default_max_rollover!()) {
            return DisputeStatus::Pending
        };

        return DisputeStatus::Expired
    };

    DisputeStatus::Pending
}

fun is_voting_complete_internal(dispute: &Dispute, resolver: &TruthResolver, epoch: &Epoch): bool {
    let cfg = resolver.epcoch_config!(epoch);
    let vote = resolver.get_vote(epoch, dispute.id.to_inner());

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

public fun is_voting_complete(
    dispute_handle: &DisputeHandle,
    resolver: &TruthResolver,
    epoch_manager: &EpochManager,
): bool {
    let dispute = &resolver.disputes[dispute_handle.dispute_id];
    let epoch = epoch_manager.get_epoch(dispute.active_epoch_no);
    is_voting_complete_internal(dispute, resolver, epoch)
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
fun calculate_effective_vote_weight(
    resolver: &TruthResolver,
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

macro fun add_pending_slash(
    $resolver: &mut TruthResolver,
    $voter: address,
    $potential_slash: u64,
    $dispute_id: ID,
) {
    let voter = $voter;
    let resolver = $resolver;
    let dispute_id = $dispute_id;
    let potential_slash = $potential_slash;

    let voter_state = &mut resolver.voters_state[voter];
    if (!voter_state.pending_dispute_slash.contains(&dispute_id)) {
        voter_state.pending_slash = voter_state.pending_slash + potential_slash;
        voter_state.pending_dispute_slash.insert(dispute_id, potential_slash);
        resolver.total_pending_slash = resolver.total_pending_slash + potential_slash;
    };
}

macro fun remove_pending_slash(
    $resolver: &mut TruthResolver,
    $voter: address,
    $dispute_id: ID,
): u64 {
    let voter = $voter;
    let resolver = $resolver;
    let dispute_id = $dispute_id;

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

/// Get vote weight for a voter in a specific epoch
///
/// Voting power is frozen at reveal time to ensure consistency within the epoch.
/// If not frozen yet, calculates dynamically including pending slash deductions.
public fun get_vote_weight(resolver: &TruthResolver, epoch: &Epoch, voter: address): u64 {
    let storage = epoch.storage(&resolver.resolver_cap);

    // Check if vote weight is already frozen for this voter in this epoch
    if (storage.contains(VoteWeightKey(voter))) {
        return *storage.borrow<_, u64>(VoteWeightKey(voter))
    };

    // Power not frozen yet - calculate dynamically
    // This should only happen during commit phase before reveal
    let base_weight = resolver.cumulative_vote_weight; // TODO: Get actual base weight from staking
    calculate_effective_vote_weight(resolver, base_weight, voter)
}

public fun get_vote(resolver: &TruthResolver, epoch: &Epoch, dispute_id: ID): &Vote {
    epoch.storage(&resolver.resolver_cap).borrow<_, Vote>(VoteKey(dispute_id))
}

public fun get_or_initialize_vote_mut(
    resolver: &TruthResolver,
    epoch: &mut Epoch,
    dispute_id: ID,
    ctx: &mut TxContext,
): &mut Vote {
    let key = VoteKey(dispute_id);
    let storage_mut = epoch.storage_mut(&resolver.resolver_cap);
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

public fun get_vote_mut(resolver: &TruthResolver, epoch: &mut Epoch, dispute_id: ID): &mut Vote {
    epoch.storage_mut(&resolver.resolver_cap).borrow_mut<_, Vote>(VoteKey(dispute_id))
}

public macro fun epcoch_config($resolver: &TruthResolver, $epoch: &Epoch): &EpochConfig {
    let resolver = $resolver;
    let epoch = $epoch;

    epoch.storage(&resolver.resolver_cap).borrow<_, EpochConfig>(EpochConfigKey())
}

public fun request_verification(
    resolver: &mut TruthResolver,
    epoch_manager: &EpochManager,
    dispute_handle: &DisputeHandle,
    bond: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let current_epoch = epoch_manager.current_epoch(clock);
    let dispute = &resolver.disputes[dispute_handle.dispute_id];
    let dispute_epoch = epoch_manager.get_epoch(dispute.active_epoch_no);

    let status = resolver.dispute_status_internal(dispute, current_epoch, dispute_epoch, clock);

    assert!(current_epoch.epoch_no() == dispute.active_epoch_no, EInvalidDisputeEpoch);
    assert!(dispute.verification_request.is_none(), EChallengeAlreadyExists);
    assert!(status == DisputeStatus::Verification, ENotInVerificationBuffer);
    assert!(bond.value() >= dispute.min_bond_amount, EInsufficientVerificationRequestBond);

    let active_epoch = epoch_manager.get_epoch(dispute.active_epoch_no);
    assert!(active_epoch.is_in_verification_phase(clock), ENotInVerificationBuffer);

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

public fun cast_verification_vote(
    resolver: &mut TruthResolver,
    epoch_manager: &EpochManager,
    dispute_handle: &DisputeHandle,
    // using vector<u8> for future extensibility, we could change the mechanism later
    truth: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // let dispute_status = resolver.dispute_status(epoch_manager, dispute_handle.dispute_id, clock);

    let current_epoch = epoch_manager.current_epoch(clock);
    let dispute = &resolver.disputes[dispute_handle.dispute_id];
    let dispute_epoch = epoch_manager.get_epoch(dispute.active_epoch_no);

    let dispute_status = resolver.dispute_status_internal(
        dispute,
        current_epoch,
        dispute_epoch,
        clock,
    );

    assert!(dispute_status == DisputeStatus::Review, 0);

    let dispute_id = dispute_handle.dispute_id;
    let dispute_mut = &mut resolver.disputes[dispute_handle.dispute_id];
    let verification_request = dispute_mut.verification_request.borrow_mut();
    resolver.verification_committee.cast_vote(verification_request, dispute_id, truth, ctx);

    // If the verification state is "accepted", meaning that the verification requester was correct about a manipulation,
    // the slashing mode is set to "SlashingMode::Quadratic".
    // This will apply quadratic slashing to all correct votes from the voting stage, this is because the correct votes from the voting stage
    // were supposed to be wrong but manipulation by some voters made the voting mechanisms think them as correct, so the verification layer
    // here helps us know they're actually wrong and should be quadratically slashed.
    if (verification_request.state() == verification::verification_request_state_accepted()) {
        dispute_mut.slashing_mode = SlashingMode::Quadratic
    }
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

    (vote_weight * slashing_rate_bps) / bps!()
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

macro fun commit_hash($voter: address, $salt: vector<u8>, $data: vector<u8>): vector<u8> {
    let voter = $voter;
    let salt = $salt;
    let data = $data;

    let mut bytes = voter.to_bytes();
    bytes.append(salt);
    bytes.append(data);

    hash::blake2b256(&bytes)
}
