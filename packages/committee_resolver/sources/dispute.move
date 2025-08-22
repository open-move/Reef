module resolver::dispute;

use reef::reef::Query;
use sui::clock::Clock;
use sui::hash;
use sui::vec_map::{Self, VecMap};

// Error constants
const ECommitPhaseEnded: u64 = 0;
const ENotEligibleVoter: u64 = 1;
const EAlreadyCommitted: u64 = 2;
const ECommitPhaseNotEnded: u64 = 3;
const ERevealPhaseEnded: u64 = 4;
const EVoterDidNotCommit: u64 = 5;
const EAlreadyVoted: u64 = 6;
const EHashMismatch: u64 = 7;
const EInsufficientCommitteeSize: u64 = 8;

// Precision and percentages
const PRECISION_FACTOR: u64 = 10_000;

const MIN_PARTICIPATION_RATE: u64 = 5_000;
const MIN_CONSENSUS_RATE: u64 = 6_000;

const COMMIT_PHASE_DURATION_MS: u64 = 48 * 60 * 60 * 1000; // 48 hours
const REVEAL_PHASE_DURATION_MS: u64 = 24 * 60 * 60 * 1000; // 24 hours

const MIN_COMMITTEE_SIZE: u64 = 3;

public struct Dispute has key {
    id: UID,
    query_id: ID,
    commit_end_ms: u64,
    reveal_end_ms: u64,
    total_revealed_stake: u64,
    votes: VecMap<address, Vote>,
    leading_claim: Option<vector<u8>>,
    voter_stakes: VecMap<address, u64>,
    claims_stake: VecMap<vector<u8>, u64>,
    commitments: VecMap<address, vector<u8>>,
}

public struct Vote has store {
    claim: vector<u8>,
    salt: vector<u8>,
    timestamp_ms: u64,
}

public(package) fun create(
    voter_stakes: VecMap<address, u64>,
    query: &Query,
    clock: &Clock,
    ctx: &mut TxContext,
): Dispute {
    let current_time = clock.timestamp_ms();
    assert!(voter_stakes.size() >= MIN_COMMITTEE_SIZE, EInsufficientCommitteeSize);

    Dispute {
        id: object::new(ctx),
        voter_stakes,
        votes: vec_map::empty(),
        total_revealed_stake: 0,
        query_id: object::id(query),
        commitments: vec_map::empty(),
        leading_claim: option::none(),
        claims_stake: vec_map::empty(),
        commit_end_ms: current_time + COMMIT_PHASE_DURATION_MS,
        reveal_end_ms: current_time + COMMIT_PHASE_DURATION_MS + REVEAL_PHASE_DURATION_MS,
    }
}

public(package) fun commit_vote(
    dispute: &mut Dispute,
    voter: address,
    vote_hash: vector<u8>,
    clock: &Clock,
) {
    assert!(dispute.voter_stakes.contains(&voter), ENotEligibleVoter);
    assert!(clock.timestamp_ms() <= dispute.commit_end_ms, ECommitPhaseEnded);
    assert!(!dispute.commitments.contains(&voter), EAlreadyCommitted);

    dispute.commitments.insert(voter, vote_hash);
}

public(package) fun reveal_vote(
    dispute: &mut Dispute,
    voter: address,
    claim: vector<u8>,
    salt: vector<u8>,
    clock: &Clock,
) {
    let timestamp_ms = clock.timestamp_ms();

    assert!(timestamp_ms > dispute.commit_end_ms, ECommitPhaseNotEnded);
    assert!(timestamp_ms <= dispute.reveal_end_ms, ERevealPhaseEnded);
    assert!(dispute.commitments.contains(&voter), EVoterDidNotCommit);
    assert!(!dispute.votes.contains(&voter), EAlreadyVoted);
    assert!(dispute.voter_stakes.contains(&voter), ENotEligibleVoter);

    assert!(dispute.commitments[&voter] == compute_hash(claim, salt), EHashMismatch);

    let stake = dispute.voter_stakes[&voter];
    if (dispute.claims_stake.contains(&claim)) {
        let current_stake = &mut dispute.claims_stake[&claim];
        *current_stake = *current_stake + stake;
    } else {
        dispute.claims_stake.insert(claim, stake);
    };

    dispute.votes.insert(voter, Vote { claim, salt, timestamp_ms: timestamp_ms });
    dispute.total_revealed_stake = dispute.total_revealed_stake + stake;
    dispute.set_leading_claim()
}

fun set_leading_claim(dispute: &mut Dispute) {
    let claims = dispute.claims_stake.keys();
    let (mut max_stake, mut leading_claim) = (0, option::none<vector<u8>>());

    claims.do_ref!(|key| {
        let stake = dispute.claims_stake[key];

        if (stake > max_stake) {
            max_stake = stake;
            leading_claim = option::some(*key);
        };
    });

    dispute.leading_claim = leading_claim;
}

// Get vote correctness results for economic incentives
// This function will be called from committee module with proper stake access
public(package) fun get_vote_results(
    dispute: &Dispute,
    winning_claim: &vector<u8>,
): VecMap<address, bool> {
    let mut results = vec_map::empty<address, bool>();
    let vote_keys = dispute.votes.keys();

    let mut i = 0;
    while (i < vote_keys.length()) {
        let voter = vote_keys[i];
        let vote = &dispute.votes[&voter];
        let was_correct = (vote.claim == *winning_claim);
        results.insert(voter, was_correct);
        i = i + 1;
    };

    results
}

public fun share_dispute(dispute: Dispute) {
    transfer::share_object(dispute);
}

fun compute_hash(claim: vector<u8>, salt: vector<u8>): vector<u8> {
    let mut data = vector[];
    data.append(claim);
    data.append(salt);

    hash::blake2b256(&data)
}

// === View Functions ===

public fun voter_stakes(dispute: &Dispute): &VecMap<address, u64> {
    &dispute.voter_stakes
}

public fun get_commitments(dispute: &Dispute): &VecMap<address, vector<u8>> {
    &dispute.commitments
}

public fun get_votes(dispute: &Dispute): &VecMap<address, Vote> {
    &dispute.votes
}

public fun has_committed(dispute: &Dispute, voter: address): bool {
    dispute.commitments.contains(&voter)
}

public fun has_revealed(dispute: &Dispute, voter: address): bool {
    dispute.votes.contains(&voter)
}

public fun get_vote_claim(vote: &Vote): vector<u8> {
    vote.claim
}

public fun claims_stake(dispute: &Dispute): &VecMap<vector<u8>, u64> {
    &dispute.claims_stake
}

public fun total_revealed_stake(dispute: &Dispute): u64 {
    dispute.total_revealed_stake
}

public fun votes(dispute: &Dispute): &VecMap<address, Vote> {
    &dispute.votes
}

public fun is_eligible_voter(dispute: &Dispute, member: address): bool {
    dispute.voter_stakes.contains(&member)
}

public fun is_commit_phase(dispute: &Dispute, clock: &Clock): bool {
    let current_time = clock.timestamp_ms();
    current_time <= dispute.commit_end_ms
}

public fun is_reveal_phase(dispute: &Dispute, clock: &Clock): bool {
    let current_time = clock.timestamp_ms();
    current_time > dispute.commit_end_ms && current_time <= dispute.reveal_end_ms
}

public fun dispute_ended(dispute: &Dispute, clock: &Clock): bool {
    let current_time = clock.timestamp_ms();
    current_time > dispute.reveal_end_ms
}

public(package) fun dispute_results(dispute: &Dispute): (vector<u8>, u64) {
    if (dispute.leading_claim.is_some()) {
        let claim = *dispute.leading_claim.borrow();
        (claim, dispute.claims_stake[&claim])
    } else {
        (vector::empty<u8>(), 0)
    }
}

public(package) fun reveal_end_ms(dispute: &Dispute): u64 {
    dispute.reveal_end_ms
}

public fun resolved_claim(dispute: &Dispute): Option<vector<u8>> {
    if (dispute.is_resolved()) return dispute.leading_claim;
    option::none()
}

public fun meets_participation_threshold(dispute: &Dispute): bool {
    let participation_rate =
        (dispute.votes.size() * PRECISION_FACTOR) / dispute.voter_stakes.size();
    participation_rate >= MIN_PARTICIPATION_RATE
}

public fun meets_consensus_threshold(dispute: &Dispute): bool {
    if (dispute.leading_claim.is_some()) {
        let winning_claim = *dispute.leading_claim.borrow();
        let winning_stake = dispute.claims_stake[&winning_claim];
        let consensus_rate = (winning_stake * PRECISION_FACTOR) / dispute.total_revealed_stake;
        consensus_rate >= MIN_CONSENSUS_RATE
    } else {
        false
    }
}

public fun is_resolved(dispute: &Dispute): bool {
    meets_participation_threshold(dispute) && meets_consensus_threshold(dispute)
}
