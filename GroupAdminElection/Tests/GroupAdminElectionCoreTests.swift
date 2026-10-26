import XCTest
@testable import GroupAdminElectionCore

private typealias Member = GroupAdminElectionMember<Int>

final class GroupAdminElectionCoreTests: XCTestCase {
    private let rules = GroupAdminElectionRules.default
    private let day: Int32 = 24 * 60 * 60
    private let now: Int32 = 1_000_000_000

    private func member(_ id: Int, joinedDaysAgo: Int32 = 30, role: Member.Role = .member, isBot: Bool = false, isDeleted: Bool = false) -> Member {
        return Member(id: id, role: role, joinDate: role == .creator ? nil : self.now - joinedDaysAgo * self.day, isBot: isBot, isDeleted: isDeleted)
    }

    private func group(memberCount: Int) -> [Member] {
        return [self.member(0, role: .creator, isDeleted: true)] + (1 ... memberCount).map { self.member($0) }
    }

    private func election(in members: [Member], candidate: Int = 1, proposer: Int = 2) -> GroupAdminElection<Int> {
        return GroupAdminElectionLogic.makeElection(id: 1, proposerId: proposer, candidateId: candidate, members: members, now: self.now, rules: self.rules)
    }

    private func voting(_ election: GroupAdminElection<Int>, _ votes: [(Int, Bool)]) -> GroupAdminElection<Int> {
        var election = election
        for (voter, yes) in votes {
            election = try! GroupAdminElectionLogic.vote(election: election, voterId: voter, yes: yes, now: self.now).get()
        }
        return election
    }

    func testAdminlessReason() {
        XCTAssertEqual(GroupAdminElectionLogic.adminlessReason(members: self.group(memberCount: 3), creatorLeftDate: nil, now: self.now, rules: self.rules), .creatorDeleted)

        let creatorLeft = (1 ... 3).map { self.member($0) }
        XCTAssertEqual(GroupAdminElectionLogic.adminlessReason(members: creatorLeft, creatorLeftDate: nil, now: self.now, rules: self.rules), .creatorLeft)
        XCTAssertNil(GroupAdminElectionLogic.adminlessReason(members: creatorLeft, creatorLeftDate: self.now - self.day, now: self.now, rules: self.rules), "a creator who left recently may come back")

        let withAdmin = self.group(memberCount: 3) + [self.member(9, role: .admin)]
        XCTAssertNil(GroupAdminElectionLogic.adminlessReason(members: withAdmin, creatorLeftDate: nil, now: self.now, rules: self.rules))
    }

    func testVotersExcludeCandidateNewcomersBotsAndDeleted() {
        let members = self.group(memberCount: 3) + [
            self.member(4, joinedDaysAgo: 1),
            self.member(5, isBot: true),
            self.member(6, isDeleted: true)
        ]
        XCTAssertEqual(Set(GroupAdminElectionLogic.voters(members: members, candidateId: 1, start: self.now, rules: self.rules)), [2, 3])
    }

    func testProposalValidation() {
        let members = self.group(memberCount: 4) + [self.member(7, joinedDaysAgo: 1), self.member(8, isBot: true)]
        func validate(proposer: Int, candidate: Int, history: [GroupAdminElection<Int>] = []) -> GroupAdminElectionProposeError? {
            return GroupAdminElectionLogic.validateProposal(proposerId: proposer, candidateId: candidate, members: members, creatorLeftDate: nil, history: history, now: self.now, rules: self.rules)
        }
        XCTAssertNil(validate(proposer: 2, candidate: 1))
        XCTAssertNil(validate(proposer: 2, candidate: 2), "proposing yourself is allowed")
        XCTAssertNil(validate(proposer: 2, candidate: 7), "a newcomer can be elected, just not vote")
        XCTAssertEqual(validate(proposer: 7, candidate: 1), .proposerCannotVote)
        XCTAssertEqual(validate(proposer: 2, candidate: 8), .candidateIsBot)
        XCTAssertEqual(validate(proposer: 2, candidate: 0), .candidateNotMember)

        let open = self.election(in: members)
        XCTAssertEqual(validate(proposer: 3, candidate: 4, history: [open]), .electionInProgress)

        var cancelled = open
        cancelled.outcome = .cancelled(date: self.now, reason: .candidateLeft)
        XCTAssertEqual(validate(proposer: 2, candidate: 3, history: [cancelled]), .proposerCooldown(until: self.now + self.rules.proposerCooldown))

        var rejected = open
        rejected.proposerId = 4
        rejected.outcome = .rejected(date: self.now - self.day)
        XCTAssertEqual(validate(proposer: 3, candidate: 1, history: [rejected]), .candidateCooldown(until: self.now - self.day + self.rules.rejectedCandidateCooldown))
        XCTAssertNil(validate(proposer: 3, candidate: 2, history: [rejected]))
    }

    func testVoting() {
        let election = self.election(in: self.group(memberCount: 5))
        XCTAssertEqual(GroupAdminElectionLogic.vote(election: election, voterId: 1, yes: true, now: self.now).failureValue, .notEligible, "candidates cannot vote for themselves")
        let voted = self.voting(election, [(2, true)])
        XCTAssertEqual(GroupAdminElectionLogic.vote(election: voted, voterId: 2, yes: false, now: self.now).failureValue, .alreadyVoted)
        XCTAssertEqual(GroupAdminElectionLogic.vote(election: voted, voterId: 3, yes: true, now: election.endDate).failureValue, .electionClosed)
    }

    func testElectedEarlyOnlyWhenRemainingVotesCannotFlipIt() {
        // 9 members, the candidate excluded: 8 voters, 4 needed to count.
        let election = self.election(in: self.group(memberCount: 9))
        XCTAssertEqual(GroupAdminElectionLogic.requiredTurnout(voterCount: 8, rules: self.rules), 4)

        let fourYes = self.voting(election, [(2, true), (3, true), (4, true), (5, true)])
        XCTAssertNil(GroupAdminElectionLogic.decidedOutcome(election: fourYes, now: self.now, rules: self.rules), "the four others could still tie it")

        let fiveYes = self.voting(fourYes, [(6, true)])
        XCTAssertEqual(GroupAdminElectionLogic.decidedOutcome(election: fiveYes, now: self.now, rules: self.rules), .elected(date: self.now))

        XCTAssertEqual(GroupAdminElectionLogic.decidedOutcome(election: fourYes, now: election.endDate, rules: self.rules), .elected(date: election.endDate))
    }

    func testRejected() {
        let election = self.election(in: self.group(memberCount: 9))

        let lowTurnout = self.voting(election, [(2, true), (3, true), (4, true)])
        XCTAssertEqual(GroupAdminElectionLogic.decidedOutcome(election: lowTurnout, now: election.endDate, rules: self.rules), .rejected(date: election.endDate), "3 of 8 is below the quorum")

        let tie = self.voting(election, [(2, true), (3, true), (4, false), (5, false)])
        XCTAssertEqual(GroupAdminElectionLogic.decidedOutcome(election: tie, now: election.endDate, rules: self.rules), .rejected(date: election.endDate), "a tie loses")

        let fourNo = self.voting(election, [(2, false), (3, false), (4, false), (5, false)])
        XCTAssertEqual(GroupAdminElectionLogic.decidedOutcome(election: fourNo, now: self.now, rules: self.rules), .rejected(date: self.now))
    }

    func testSmallGroupNeedsEveryone() {
        // Candidate plus two voters.
        let election = self.election(in: self.group(memberCount: 3))
        XCTAssertEqual(election.voterIds.count, 2)
        let oneYes = self.voting(election, [(2, true)])
        XCTAssertNil(GroupAdminElectionLogic.decidedOutcome(election: oneYes, now: self.now, rules: self.rules))
        XCTAssertEqual(GroupAdminElectionLogic.decidedOutcome(election: oneYes, now: election.endDate, rules: self.rules), .rejected(date: election.endDate))
        XCTAssertEqual(GroupAdminElectionLogic.decidedOutcome(election: self.voting(oneYes, [(3, true)]), now: self.now, rules: self.rules), .elected(date: self.now))
        XCTAssertEqual(GroupAdminElectionLogic.decidedOutcome(election: self.voting(election, [(3, false)]), now: self.now, rules: self.rules), .rejected(date: self.now))
    }

    func testReconcile() {
        let members = self.group(memberCount: 5)
        let election = self.voting(self.election(in: members), [(2, true), (3, false)])

        let voterLeft = GroupAdminElectionLogic.reconcile(election: election, members: members.filter { $0.id != 3 }, isUpgraded: false, now: self.now)
        XCTAssertNil(voterLeft.outcome)
        XCTAssertFalse(voterLeft.voterIds.contains(3))
        XCTAssertNil(voterLeft.votes[3], "a voter who left takes the vote with them")

        let candidateLeft = GroupAdminElectionLogic.reconcile(election: election, members: members.filter { $0.id != 1 }, isUpgraded: false, now: self.now)
        XCTAssertEqual(candidateLeft.outcome, .cancelled(date: self.now, reason: .candidateLeft))

        let adminBack = GroupAdminElectionLogic.reconcile(election: election, members: members + [self.member(9, role: .admin)], isUpgraded: false, now: self.now)
        XCTAssertEqual(adminBack.outcome, .cancelled(date: self.now, reason: .adminReturned))

        let upgraded = GroupAdminElectionLogic.reconcile(election: election, members: members, isUpgraded: true, now: self.now)
        XCTAssertEqual(upgraded.outcome, .cancelled(date: self.now, reason: .groupUpgraded))

        let newcomer = GroupAdminElectionLogic.reconcile(election: election, members: members + [self.member(10, joinedDaysAgo: 0)], isUpgraded: false, now: self.now)
        XCTAssertFalse(newcomer.voterIds.contains(10), "members who join during the vote never get a vote")
    }

    func testProbation() {
        var election = self.election(in: self.group(memberCount: 3))
        election.outcome = .elected(date: self.now)
        XCTAssertTrue(GroupAdminElectionLogic.isInProbation(election: election, now: self.now + self.rules.probation - 1, rules: self.rules))
        XCTAssertFalse(GroupAdminElectionLogic.isInProbation(election: election, now: self.now + self.rules.probation, rules: self.rules))
    }
}

private extension Result {
    var failureValue: Failure? {
        if case let .failure(error) = self {
            return error
        }
        return nil
    }
}
