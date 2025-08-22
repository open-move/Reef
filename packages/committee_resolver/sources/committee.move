module resolver::committee;

use reef::reef::Query;
use reef::resolver::{Self, Resolver, Resolution, ChallengeRequest};
use resolver::dispute::{Self, Dispute};
use resolver::staking::{Self, Stake};
use sui::clock::Clock;
use sui::coin::Coin;
use sui::event;
use std::type_name;
use sui::package::{Self, Publisher};
use sui::sui::SUI;
use sui::vec_map::{Self, VecMap};
use sui::vec_set::{Self, VecSet};

// Error constants
const EInsufficientStake: u64 = 0;
const ENotMember: u64 = 1;
const EWrongResolver: u64 = 2;
const EPendingDisputes: u64 = 3;
const EInvalidPublisher: u64 = 4;
const ENotActiveMember: u64 = 5;
const EDisputeNotActive: u64 = 6;
const EInvalidConfig: u64 = 7;
const EInvalidQueryID: u64 = 8;
const EInvalidChallengeTime: u64 = 10;
const ECommitteePaused: u64 = 11;
const EInvalidWitnessType: u64 = 12;

const PRECISION_FACTOR: u64 = 10_000;

const GOOD_PERFORMANCE_THRESHOLD: u64 = 7_000; // 70%
const POOR_PERFORMANCE_THRESHOLD: u64 = 5_000; // 50%


const MIN_STAKE: u64 = 1_000 * 1000_000; // 1000 SUI
const MAX_SLASHING_RATE: u64 = 5_000; // 50%
const MAX_COMMITTEE_SIZE: u64 = 1000;

public struct COMMITTEE() has drop;

public struct Witness() has drop;


public struct MemberJoined has copy, drop {
    member: address,
    committee_id: ID,
    stake_amount: u64,
    timestamp_ms: u64,
}

public struct VoteCommitted has copy, drop {
    dispute_id: ID,
    voter: address,
    committee_id: ID,
    timestamp_ms: u64,
}

public struct VoteRevealed has copy, drop {
    voter: address,
    dispute_id: ID,
    committee_id: ID,
    timestamp_ms: u64,
    claim_hash: vector<u8>,
}

public struct DisputeCreated has copy, drop {
    query_id: ID,
    dispute_id: ID,
    committee_id: ID,
    timestamp_ms: u64,
    eligible_voters: u64,
    total_voting_power: u64,
}

public struct DisputeResolved has copy, drop {
    dispute_id: ID,
    committee_id: ID,
    timestamp_ms: u64,
    participation_rate: u64,
    consensus_percentage: u64,
    winning_claim: vector<u8>,
}

public struct MemberSlashed has copy, drop {
    reason: u8, // 0: non-reveal, 1: incorrect vote, 2: non-participation
    member: address,
    committee_id: ID,
    slash_amount: u64,
    timestamp_ms: u64,
}

public struct ConfigUpdated has copy, drop {
    committee_id: ID,
    timestamp_ms: u64,
    updated_by: address,
}

public struct Committee has key {
    id: UID,
    /// Whether the committee is paused (emergency stop)
    paused: bool,
    /// ID of the associated resolver for this committee
    resolver_id: ID,
    /// Total amount staked by all members (for efficiency)
    total_staked: u64,
    /// Config parameters (slashing rates, limits, etc.)
    config: CommitteeConfig,
    /// Set of currently active dispute IDs
    active_disputes: VecSet<ID>,
    /// Map of member addresses to their committee member data
    members: VecMap<address, CommitteeMember>,
}

/// Configuration parameters for committee behavior and economic incentives.
///
/// All slashing rates are in basis points (10000 = 100%). The progressive
/// slashing system penalizes poor performers more heavily:
/// - Base: 70-99% accuracy (light penalty)
/// - Moderate: 50-70% accuracy (medium penalty)
/// - Extreme: <50% accuracy (heavy penalty)
/// - Immediate: Applied instantly for non-reveal gaming
public struct CommitteeConfig has drop, store {
    /// Minimum SUI amount required to join the committee
    minimum_stake: u64,
    /// Base slashing rate for 70-99% accuracy (basis points)
    base_slashing_rate: u64,
    /// Moderate slashing rate for 50-70% accuracy (basis points)
    moderate_slashing_rate_bps: u64,
    /// Extreme slashing rate for <50% accuracy (basis points)
    extreme_slashing_rate_bps: u64,
    /// Penalty rate for non-reveals at withdrawal (basis points)
    non_reveal_penalty_rate: u64,
    /// Immediate slashing rate for non-reveal gaming (basis points)
    immediate_slash_rate: u64,
    /// Maximum number of members allowed in the committee
    max_committee_size: u64,
}

/// Represents a single committee member with their stake and performance history.
///
/// Performance is tracked via lazy evaluation - dispute outcomes are processed
/// only when needed (withdrawals, new interactions) to minimize gas costs.
///
/// ## Performance Calculation
/// Accuracy = total_correct / total_participations (including non-reveals)
/// - >= 70%: Active status, base slashing
/// - 50-70%: Probation status, moderate slashing
/// - < 50%: Suspended status, extreme slashing
public struct CommitteeMember has store {
    stake: Stake<SUI>,
    total_correct: u64,
    last_active_ms: u64,
    total_participations: u64,
    pending_disputes: VecSet<ID>,
}

fun init(otw: COMMITTEE, ctx: &mut TxContext) {
    package::claim_and_keep(otw, ctx);
}

/// Creates a new committee with the given configuration.
///
/// # Parameters
/// - `publisher`: Publisher capability proving authorization to create committees
/// - `config`: Committee configuration (stake requirements, slashing rates, etc.)
/// - `ctx`: Transaction context for object creation
///
/// # Returns
/// A new Committee object ready to accept members
///
/// # Panics
/// - `EInvalidPublisher`: Publisher not from this module
/// - `EInvalidConfig`: Configuration parameters out of valid ranges
public fun create(publisher: Publisher, config: CommitteeConfig, ctx: &mut TxContext): Committee {
    assert!(publisher.from_module<COMMITTEE>(), EInvalidPublisher);
    config.validate_config();

    let resolver = resolver::create(Witness(), publisher, ctx);

    let committee = Committee {
        id: object::new(ctx),
        config,
        paused: false,
        total_staked: 0,
        members: vec_map::empty(),
        active_disputes: vec_set::empty(),
        resolver_id: object::id(&resolver),
    };

    resolver.share();
    committee
}

fun validate_config(config: &CommitteeConfig) {
    assert!(config.minimum_stake >= MIN_STAKE, EInvalidConfig);
    assert!(config.base_slashing_rate <= MAX_SLASHING_RATE, EInvalidConfig);
    assert!(config.moderate_slashing_rate_bps <= MAX_SLASHING_RATE, EInvalidConfig);
    assert!(config.extreme_slashing_rate_bps <= MAX_SLASHING_RATE, EInvalidConfig);
    assert!(config.non_reveal_penalty_rate <= MAX_SLASHING_RATE, EInvalidConfig);
    assert!(config.immediate_slash_rate <= MAX_SLASHING_RATE, EInvalidConfig);
    assert!(
        config.max_committee_size > 0 && config.max_committee_size <= MAX_COMMITTEE_SIZE,
        EInvalidConfig,
    );
}

/// Allows a new member to join the committee by staking SUI.
///
/// # Parameters
/// - `committee`: The committee to join
/// - `stake`: SUI coins to stake (must meet minimum requirement)
/// - `clock`: Clock for timestamp recording
/// - `ctx`: Transaction context to identify the joiner
///
/// # Panics
/// - `EUnauthorized`: Committee is paused
/// - `EInvalidConfig`: Already a member or committee full
/// - `EInsufficientStake`: Stake amount below minimum
///
/// # Events
/// Emits `MemberJoined` event with stake details
public fun join(committee: &mut Committee, stake: Coin<SUI>, clock: &Clock, ctx: &mut TxContext) {
    assert!(!committee.paused, ECommitteePaused);

    let sender = ctx.sender();
    let stake_value = stake.value();
    let current_time = clock.timestamp_ms();

    assert!(!committee.members.contains(&sender), EInvalidConfig);
    assert!(stake_value >= committee.config.minimum_stake, EInsufficientStake);
    assert!(committee.members.size() < committee.config.max_committee_size, EInvalidConfig);

    let member = CommitteeMember {
        total_correct: 0,
        total_participations: 0,
        last_active_ms: current_time,
        pending_disputes: vec_set::empty<ID>(),
        stake: staking::create_stake(stake.into_balance()),
    };

    committee.total_staked = committee.total_staked + stake_value;
    committee.members.insert(sender, member);

    event::emit(MemberJoined {
        committee_id: object::id(committee),
        member: sender,
        stake_amount: stake_value,
        timestamp_ms: current_time,
    });
}

public fun request_withdrawal(
    committee: &mut Committee,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let sender = ctx.sender();
    assert!(committee.members.contains(&sender), ENotMember);

    let member = committee.members.get_mut(&sender);
    assert!(member.pending_disputes.is_empty(), EPendingDisputes);
    member.stake.request_withdrawal(amount, clock);
}

/// Completes a withdrawal request, applying slashing based on member performance.
///
/// This function implements lazy evaluation - it processes any unresolved disputes
/// for the member before calculating the final slashing rate. Only members with
/// no active disputes can withdraw.
///
/// # Parameters
/// - `committee`: The committee to withdraw from
/// - `clock`: Clock for timestamp and dispute timeout calculations
/// - `ctx`: Transaction context to identify the withdrawing member
///
/// # Returns
/// SUI coin with the remaining amount after slashing penalties
///
/// # Panics
/// - `ENotMember`: Sender is not a committee member
/// - `EPendingDisputes`: Member has unresolved active disputes
public fun complete_withdrawal(
    committee: &mut Committee,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<SUI> {
    let sender = ctx.sender();
    assert!(committee.members.contains(&sender), ENotMember);
    assert!(committee.members[&sender].pending_disputes.is_empty(), EPendingDisputes);

    let slashing_rate = committee.slashing_rate(sender);
    let member = committee.members.get_mut(&sender);

    let mut withdrawn_balance = member.stake.complete_withdrawal(clock);

    let withdrawn_amount = withdrawn_balance.value();
    let penalty_amount = (withdrawn_amount * slashing_rate) / PRECISION_FACTOR;

    if (penalty_amount > 0) {
        let penalty_balance = withdrawn_balance.split(penalty_amount);
        penalty_balance.destroy_zero();
    };

    committee.total_staked = committee.total_staked - withdrawn_amount;

    if (member.stake.value() == 0) {
        let (_addr, removed_member) = committee.members.remove(&sender);
        let CommitteeMember { stake, .. } = removed_member;
        stake.destroy_zero();
    };

    withdrawn_balance.into_coin(ctx)
}

/// Calculates the slashing rate for a member based on their performance.
///
/// Uses a progressive slashing system:
/// - 100% accuracy: 0% slashing (perfect performance)
/// - 70-99%: Base rate (good performance, light penalty)
/// - 50-70%: Moderate rate (poor performance, medium penalty)
/// - <50%: Extreme rate (suspended, heavy penalty)
fun slashing_rate(committee: &Committee, member_address: address): u64 {
    // Calculate current accuracy including pending non-reveals
    let accuracy = committee.member_accuracy(member_address);
    if (accuracy == PRECISION_FACTOR) return 0;

    if (accuracy < POOR_PERFORMANCE_THRESHOLD) {
        committee.config.extreme_slashing_rate_bps // <50%: Heavy penalty
    } else if (accuracy < GOOD_PERFORMANCE_THRESHOLD) {
        committee.config.moderate_slashing_rate_bps // 50-70%: Medium penalty
    } else {
        committee.config.base_slashing_rate // 70-99%: Light penalty
    }
}

public fun is_active(committee: &Committee, member_addr: address): bool {
    committee.member_accuracy(member_addr) >= GOOD_PERFORMANCE_THRESHOLD
}

public fun is_suspended(committee: &Committee, member_addr: address): bool {
     committee.member_accuracy(member_addr) < POOR_PERFORMANCE_THRESHOLD
}

public fun create_dispute<CoinType>(
    committee: &mut Committee,
    query: &Query,
    resolver: &Resolver,
    challenge: ChallengeRequest<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
): Dispute {
    let (
        query_id,
        fee,
        _challenger,
        challenged_at,
        _,
    ) = challenge.unpack_challenge_request<CoinType, _>(Witness());
    fee.destroy_zero();

    let current_time_ms = clock.timestamp_ms();
    assert!(query_id == object::id(query), EInvalidQueryID);
    assert!(current_time_ms == challenged_at, EInvalidChallengeTime);
    assert!(object::id(resolver) == committee.resolver_id, EWrongResolver);
    assert!(resolver.witness_type() == type_name::get<Witness>(), EInvalidWitnessType);

    let addresses = committee.members.keys();
    let mut total_stakes = vec_map::empty<address, u64>();
    addresses.do!(|addr| {
        let member = &committee.members[&addr];
        let effective_stake = member.stake.effective_stake();

        if (committee.is_active(addr) && effective_stake > 0) {
            total_stakes.insert(copy addr, effective_stake);
        };
    });

    let dispute = dispute::create(total_stakes, query, clock, ctx);
    committee.effectuate_dispute(&dispute);

    event::emit(DisputeCreated {
        query_id: object::id(query),
        timestamp_ms: challenged_at,
        dispute_id: object::id(&dispute),
        committee_id: object::id(committee),
        eligible_voters: total_stakes.size(),
        total_voting_power: calculate_total_voting_power(&total_stakes),
    });

    dispute
}

public fun commit_vote(
    committee: &Committee,
    dispute: &mut Dispute,
    commitment: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(!committee.paused, ECommitteePaused);

    let sender = ctx.sender();
    let dispute_id = object::id(dispute);

    assert!(committee.is_active(sender), ENotActiveMember);
    assert!(committee.active_disputes.contains(&dispute_id), EDisputeNotActive);

    dispute.commit_vote(sender, commitment, clock);

    event::emit(VoteCommitted {
        dispute_id,
        voter: sender,
        committee_id: object::id(committee),
        timestamp_ms: clock.timestamp_ms(),
    });
}

public fun reveal_vote(
    committee: &mut Committee,
    dispute: &mut Dispute,
    claim: vector<u8>,
    salt: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(!committee.paused, ECommitteePaused);

    let sender = ctx.sender();
    let dispute_id = object::id(dispute);

    assert!(committee.active_disputes.contains(&dispute_id), EDisputeNotActive);
    dispute.reveal_vote(sender, claim, salt, clock);

    // Emit event
    event::emit(VoteRevealed {
        dispute_id,
        voter: sender,
        claim_hash: claim,
        timestamp_ms: clock.timestamp_ms(),
        committee_id: object::id(committee),
    });

}

// Create resolution using the base resolver
public fun create_resolution_from_Witness(
    resolver: &Resolver,
    committee: &Committee,
    query_id: ID,
    claim: vector<u8>,
    clock: &Clock,
): Resolution {
    // Validate committee belongs to this resolver
    assert!(committee.resolver_id == object::id(resolver), EWrongResolver);

    resolver::make_resolution(
        resolver,
        Witness(),
        query_id,
        claim,
        clock,
    )
}

fun effectuate_dispute(committee: &mut Committee, dispute: &Dispute) {
    let dispute_id = object::id(dispute);

    dispute.voter_stakes().keys().do_ref!(|member_addr| {
        let member = committee.members.get_mut(member_addr);
        member.pending_disputes.insert(dispute_id);
    })
}

fun calculate_total_voting_power(voter_stakes: &VecMap<address, u64>): u64 {
    let stakes = voter_stakes.keys();
    let mut total = 0;
    let mut i = 0;
    while (i < stakes.length()) {
        let addr = stakes[i];
        total = total + voter_stakes[&addr];
        i = i + 1;
    };
    total
}


public fun member_accuracy(committee: &Committee, member_addr: address): u64 {
    if (!committee.members.contains(&member_addr)) return 0;

    let member = &committee.members[&member_addr];
    if (member.total_participations == 0) return PRECISION_FACTOR;

    let total_correct = member.total_correct;
    (total_correct * PRECISION_FACTOR) / member.total_participations
}

public fun is_paused(committee: &Committee): bool {
    committee.paused
}
