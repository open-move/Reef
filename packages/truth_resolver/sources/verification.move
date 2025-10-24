module truth_resolver::verification;

use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::table::{Self, Table};
use sui::vec_map::{Self, VecMap};

// ======= Error Codes =======

const EMemberAlreadyExists: u64 = 0;
const EMemberNotFound: u64 = 1;
const EMembersCannotExceedThreshold: u64 = 2;
const EInvalidThreshold: u64 = 3;
const ENotCommitteeMember: u64 = 4;
const EReviewNotFound: u64 = 5;
const EInvalidVoteOption: u64 = 6;
const EAlreadyResolved: u64 = 7;
const ENotEligibleMember: u64 = 8;
const ECommitteeTooSmall: u64 = 9;
const EOptionAlreadyVoted: u64 = 10;

public struct VerificationCommittee has store {
    threshold: u64,
    members: vector<address>,
    pending_reviews: Table<ID, VerificationReview>,
}

public struct VerificationRequest<phantom CoinType> has store {
    requester: address,
    requested_at_ms: u64,
    bond: Balance<CoinType>,
    state: VerificationState,
}

public struct VerificationReview has drop, store {
    required_threshold: u64,
    eligible_members: vector<address>,
    votes: VecMap<vector<u8>, vector<address>>,
}

public enum VerificationState has copy, drop, store {
    Pending,
    Accepted,
    Rejected,
}

public use fun verification_request_state as VerificationRequest.state;

public(package) fun new_committee(
    threshold: u64,
    members: vector<address>,
    ctx: &mut TxContext,
): VerificationCommittee {
    assert!(members.length() >= 1, ECommitteeTooSmall);
    assert!(threshold > 0 && threshold <= members.length(), EInvalidThreshold);

    VerificationCommittee {
        members,
        threshold,
        pending_reviews: table::new(ctx),
    }
}

public(package) fun request_verification<CoinType>(
    bond: Balance<CoinType>,
    clock: &Clock,
    ctx: &TxContext,
): VerificationRequest<CoinType> {
    VerificationRequest<CoinType> {
        bond,
        requester: ctx.sender(),
        state: VerificationState::Pending,
        requested_at_ms: clock.timestamp_ms(),
    }
}

public(package) fun add_committee_member(
    committee: &mut VerificationCommittee,
    new_member: address,
) {
    assert!(!committee.members.contains(&new_member), EMemberAlreadyExists);
    committee.members.push_back(new_member);
}

public(package) fun remove_committee_member(
    committee: &mut VerificationCommittee,
    member: address,
) {
    let (exists, index) = committee.members.index_of(&member);

    assert!(exists, EMemberNotFound);
    assert!(committee.members.length() > 1, ECommitteeTooSmall);
    assert!(committee.members.length() - 1 >= committee.threshold, EMembersCannotExceedThreshold);
    committee.members.remove(index);
}

public(package) fun update_committee_threshold(
    committee: &mut VerificationCommittee,
    new_threshold: u64,
) {
    assert!(new_threshold > 0 && new_threshold <= committee.members.length(), EInvalidThreshold);
    committee.threshold = new_threshold;
}

public(package) fun initialize_review(committee: &mut VerificationCommittee, dispute_id: ID) {
    let mut votes = vec_map::empty<vector<u8>, vector<address>>();
    votes.insert(accept!(), vector::empty<address>());
    votes.insert(reject!(), vector::empty<address>());

    committee
        .pending_reviews
        .add(
            dispute_id,
            VerificationReview {
                votes,
                eligible_members: committee.members,
                required_threshold: committee.threshold,
            },
        );
}

public(package) fun cast_vote<CoinType>(
    committee: &mut VerificationCommittee,
    request: &mut VerificationRequest<CoinType>,
    dispute_id: ID,
    vote_option: vector<u8>,
    ctx: &TxContext,
) {
    let voter = ctx.sender();
    let accept_vote = accept!();
    let reject_vote = reject!();

    assert!(committee.members.contains(&voter), ENotCommitteeMember);
    assert!(request.state == VerificationState::Pending, EAlreadyResolved);
    assert!(committee.pending_reviews.contains(dispute_id), EReviewNotFound);
    assert!(vote_option == accept_vote || vote_option == reject_vote, EInvalidVoteOption);

    let review = committee.pending_reviews.borrow(dispute_id);
    assert!(review.eligible_members.contains(&voter), ENotEligibleMember);

    let review = committee.pending_reviews.borrow_mut(dispute_id);
    assert!(!review.votes[&vote_option].contains(&voter), EOptionAlreadyVoted);

    let threshold = review.required_threshold;

    if (vote_option == accept_vote) {
        {
            let reject_votes = review.votes.get_mut(&reject_vote);
            remove_vote!(reject_votes, voter);
        };

        let accept_votes = review.votes.get_mut(&accept_vote);
        accept_votes.push_back(voter);

        if (accept_votes.length() >= threshold) {
            request.state = VerificationState::Accepted;
            committee.pending_reviews.remove(dispute_id);
        };
    } else {
        {
            let accept_votes = review.votes.get_mut(&accept_vote);
            remove_vote!(accept_votes, voter);
        };

        let reject_votes = review.votes.get_mut(&reject_vote);
        reject_votes.push_back(voter);

        if (reject_votes.length() >= threshold) {
            request.state = VerificationState::Rejected;
            committee.pending_reviews.remove(dispute_id);
        };
    };
}

public fun verification_request_state<CoinType>(
    request: &VerificationRequest<CoinType>,
): VerificationState {
    request.state
}

public fun verification_request_state_accepted(): VerificationState {
    VerificationState::Accepted
}

public fun verification_request_state_rejected(): VerificationState {
    VerificationState::Rejected
}

public fun verification_request_state_pending(): VerificationState {
    VerificationState::Pending
}

public(package) fun take_request_data<CoinType>(
    request: &mut Option<VerificationRequest<CoinType>>,
): (address, Balance<CoinType>) {
    let verification_request = option::extract(request);
    let VerificationRequest {
        requester,
        requested_at_ms: _,
        mut bond,
        state: _,
    } = verification_request;

    let bond_balance = balance::withdraw_all(&mut bond);
    balance::destroy_zero(bond);
    (requester, bond_balance)
}


macro fun remove_vote($voters: &mut vector<address>, $voter: address) {
    let voter = $voter;
    let voters = $voters;

    let (found, index) = voters.index_of(&voter);
    if (!found) return;
    voters.swap_remove(index);
}

macro fun accept(): vector<u8> {
    x"fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0"
}

macro fun reject(): vector<u8> {
    x"fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff1"
}
