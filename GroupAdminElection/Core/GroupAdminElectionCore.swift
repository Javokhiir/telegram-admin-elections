import Foundation

/// Rules of a members' vote that picks a new admin for a basic group that has none.
///
/// A basic group whose creator deleted their account (or left it) and that has no other admins
/// can never be managed again: nobody can change its info, remove spammers or add admins. The
/// election lets the remaining members pick an admin among themselves. Everything here is pure
/// and deterministic so the same evaluation can run on the server (the source of truth) and on
/// the client (to render the state without waiting for a round trip).
public struct GroupAdminElectionRules: Equatable {
    /// How long an election stays open.
    public var duration: Int32
    /// Share of the eligible voters that has to take part for the result to count.
    public var quorum: Double
    /// Members who joined less than this long before the election started cannot vote, so an
    /// election cannot be won by adding fresh accounts to the group.
    public var minimumMembershipAge: Int32
    /// With fewer eligible voters than this every one of them has to vote yes.
    public var unanimityThreshold: Int
    /// How often one member can start an election.
    public var proposerCooldown: Int32
    /// How long a candidate who lost cannot be proposed again.
    public var rejectedCandidateCooldown: Int32
    /// How long an elected admin cannot remove members or add other admins.
    public var probation: Int32
    /// How long a creator who left (rather than deleted the account) has to be gone before the
    /// group counts as having no admin. A creator of a basic group can come back.
    public var creatorAbsenceGrace: Int32

    public init(
        duration: Int32,
        quorum: Double,
        minimumMembershipAge: Int32,
        unanimityThreshold: Int,
        proposerCooldown: Int32,
        rejectedCandidateCooldown: Int32,
        probation: Int32,
        creatorAbsenceGrace: Int32
    ) {
        self.duration = duration
        self.quorum = quorum
        self.minimumMembershipAge = minimumMembershipAge
        self.unanimityThreshold = unanimityThreshold
        self.proposerCooldown = proposerCooldown
        self.rejectedCandidateCooldown = rejectedCandidateCooldown
        self.probation = probation
        self.creatorAbsenceGrace = creatorAbsenceGrace
    }

    public static let `default` = GroupAdminElectionRules(
        duration: 24 * 60 * 60,
        quorum: 0.5,
        minimumMembershipAge: 3 * 24 * 60 * 60,
        unanimityThreshold: 3,
        proposerCooldown: 24 * 60 * 60,
        rejectedCandidateCooldown: 7 * 24 * 60 * 60,
        probation: 48 * 60 * 60,
        creatorAbsenceGrace: 7 * 24 * 60 * 60
    )
}

/// A member of the group as the election sees it.
public struct GroupAdminElectionMember<Id: Hashable>: Equatable {
    public enum Role: Equatable {
        case creator
        case admin
        case member
    }

    public var id: Id
    public var role: Role
    /// When the member joined, nil when unknown (the creator has no join date).
    public var joinDate: Int32?
    public var isBot: Bool
    public var isDeleted: Bool

    public init(id: Id, role: Role, joinDate: Int32?, isBot: Bool, isDeleted: Bool) {
        self.id = id
        self.role = role
        self.joinDate = joinDate
        self.isBot = isBot
        self.isDeleted = isDeleted
    }
}

public enum GroupAdminlessReason: Equatable {
    case creatorDeleted
    case creatorLeft
}

public enum GroupAdminElectionCancelReason: Equatable {
    /// The candidate left the group or deleted the account.
    case candidateLeft
    /// The creator came back or someone else became an admin while the vote was open.
    case adminReturned
    /// The group was upgraded to a supergroup, which has its own admin system.
    case groupUpgraded
}

public enum GroupAdminElectionOutcome: Equatable {
    case elected(date: Int32)
    case rejected(date: Int32)
    case cancelled(date: Int32, reason: GroupAdminElectionCancelReason)

    public var date: Int32 {
        switch self {
        case let .elected(date), let .rejected(date), let .cancelled(date, _):
            return date
        }
    }
}

public struct GroupAdminElection<Id: Hashable>: Equatable {
    public var id: Int64
    public var candidateId: Id
    public var proposerId: Id
    public var startDate: Int32
    public var endDate: Int32
    /// Members who can vote, fixed when the election starts. Members who leave are dropped, new
    /// members are never added.
    public var voterIds: [Id]
    public var votes: [Id: Bool]
    public var outcome: GroupAdminElectionOutcome?

    public init(id: Int64, candidateId: Id, proposerId: Id, startDate: Int32, endDate: Int32, voterIds: [Id], votes: [Id: Bool], outcome: GroupAdminElectionOutcome?) {
        self.id = id
        self.candidateId = candidateId
        self.proposerId = proposerId
        self.startDate = startDate
        self.endDate = endDate
        self.voterIds = voterIds
        self.votes = votes
        self.outcome = outcome
    }

    public var isOpen: Bool {
        return self.outcome == nil
    }

    public var yesCount: Int {
        return self.votes.values.filter({ $0 }).count
    }

    public var noCount: Int {
        return self.votes.values.filter({ !$0 }).count
    }

    public var turnout: Int {
        return self.votes.count
    }
}

public enum GroupAdminElectionProposeError: Error, Equatable {
    case groupHasAdmin
    case electionInProgress
    case proposerCannotVote
    case candidateNotMember
    case candidateIsBot
    case proposerCooldown(until: Int32)
    case candidateCooldown(until: Int32)
    case notEnoughVoters
}

public enum GroupAdminElectionVoteError: Error, Equatable {
    case electionClosed
    case notEligible
    case alreadyVoted
}

public enum GroupAdminElectionLogic {
    /// Why the group has nobody left to manage it, or nil if it does.
    ///
    /// `creatorLeftDate` is when the creator left. Only the server knows it, so a client passes
    /// nil and trusts the server's `canPropose` flag instead; nil here means "long enough ago".
    public static func adminlessReason<Id>(members: [GroupAdminElectionMember<Id>], creatorLeftDate: Int32?, now: Int32, rules: GroupAdminElectionRules) -> GroupAdminlessReason? {
        let activeAdmins = members.filter { member in
            member.role != .member && !member.isDeleted
        }
        if !activeAdmins.isEmpty {
            return nil
        }
        if members.contains(where: { $0.role == .creator && $0.isDeleted }) {
            return .creatorDeleted
        }
        if let creatorLeftDate, now - creatorLeftDate < rules.creatorAbsenceGrace {
            return nil
        }
        return .creatorLeft
    }

    public static func canVote<Id>(member: GroupAdminElectionMember<Id>, electionStart: Int32, rules: GroupAdminElectionRules) -> Bool {
        if member.isBot || member.isDeleted {
            return false
        }
        guard let joinDate = member.joinDate else {
            return false
        }
        return electionStart - joinDate >= rules.minimumMembershipAge
    }

    /// Everyone who may vote in an election for `candidateId` started at `start`. The candidate
    /// never votes in their own election.
    public static func voters<Id>(members: [GroupAdminElectionMember<Id>], candidateId: Id, start: Int32, rules: GroupAdminElectionRules) -> [Id] {
        return members.filter { member in
            member.id != candidateId && self.canVote(member: member, electionStart: start, rules: rules)
        }.map(\.id)
    }

    /// The number of votes the election needs to count.
    public static func requiredTurnout(voterCount: Int, rules: GroupAdminElectionRules) -> Int {
        if voterCount < rules.unanimityThreshold {
            return voterCount
        }
        return max(1, Int((Double(voterCount) * rules.quorum).rounded(.up)))
    }

    public static func validateProposal<Id>(
        proposerId: Id,
        candidateId: Id,
        members: [GroupAdminElectionMember<Id>],
        creatorLeftDate: Int32?,
        history: [GroupAdminElection<Id>],
        now: Int32,
        rules: GroupAdminElectionRules
    ) -> GroupAdminElectionProposeError? {
        if self.adminlessReason(members: members, creatorLeftDate: creatorLeftDate, now: now, rules: rules) == nil {
            return .groupHasAdmin
        }
        if history.contains(where: { $0.isOpen }) {
            return .electionInProgress
        }
        guard let proposer = members.first(where: { $0.id == proposerId }), self.canVote(member: proposer, electionStart: now, rules: rules) else {
            return .proposerCannotVote
        }
        guard let candidate = members.first(where: { $0.id == candidateId }), !candidate.isDeleted else {
            return .candidateNotMember
        }
        if candidate.isBot {
            return .candidateIsBot
        }
        if let last = history.filter({ $0.proposerId == proposerId }).map(\.startDate).max(), now - last < rules.proposerCooldown {
            return .proposerCooldown(until: last + rules.proposerCooldown)
        }
        let rejections = history.compactMap { election -> Int32? in
            if election.candidateId == candidateId, case let .rejected(date) = election.outcome {
                return date
            }
            return nil
        }
        if let lastRejection = rejections.max(), now - lastRejection < rules.rejectedCandidateCooldown {
            return .candidateCooldown(until: lastRejection + rules.rejectedCandidateCooldown)
        }
        if self.voters(members: members, candidateId: candidateId, start: now, rules: rules).isEmpty {
            return .notEnoughVoters
        }
        return nil
    }

    public static func makeElection<Id>(id: Int64, proposerId: Id, candidateId: Id, members: [GroupAdminElectionMember<Id>], now: Int32, rules: GroupAdminElectionRules) -> GroupAdminElection<Id> {
        return GroupAdminElection(
            id: id,
            candidateId: candidateId,
            proposerId: proposerId,
            startDate: now,
            endDate: now + rules.duration,
            voterIds: self.voters(members: members, candidateId: candidateId, start: now, rules: rules),
            votes: [:],
            outcome: nil
        )
    }

    public static func vote<Id>(election: GroupAdminElection<Id>, voterId: Id, yes: Bool, now: Int32) -> Result<GroupAdminElection<Id>, GroupAdminElectionVoteError> {
        if !election.isOpen || now >= election.endDate {
            return .failure(.electionClosed)
        }
        if !election.voterIds.contains(voterId) {
            return .failure(.notEligible)
        }
        if election.votes[voterId] != nil {
            return .failure(.alreadyVoted)
        }
        var election = election
        election.votes[voterId] = yes
        return .success(election)
    }

    /// The outcome once it can no longer change: early, as soon as the remaining votes cannot
    /// flip it, or at the deadline. Nil while it still can.
    ///
    /// A candidate wins with at least the required turnout and more yes than no votes; a tie
    /// loses. With fewer voters than `unanimityThreshold` every voter has to say yes.
    public static func decidedOutcome<Id>(election: GroupAdminElection<Id>, now: Int32, rules: GroupAdminElectionRules) -> GroupAdminElectionOutcome? {
        if let outcome = election.outcome {
            return outcome
        }
        let voterCount = election.voterIds.count
        let yes = election.yesCount
        let no = election.noCount
        let remaining = voterCount - election.turnout
        let required = self.requiredTurnout(voterCount: voterCount, rules: rules)
        let isUnanimous = voterCount < rules.unanimityThreshold

        let decideAt = min(now, election.endDate)
        if isUnanimous {
            if no > 0 {
                return .rejected(date: decideAt)
            }
            if voterCount > 0 && yes == voterCount {
                return .elected(date: decideAt)
            }
        } else {
            if election.turnout >= required && yes > no + remaining {
                return .elected(date: decideAt)
            }
            if yes + remaining <= no {
                return .rejected(date: decideAt)
            }
        }
        if now >= election.endDate {
            if !isUnanimous && election.turnout >= required && yes > no {
                return .elected(date: election.endDate)
            }
            return .rejected(date: election.endDate)
        }
        return nil
    }

    /// Applies membership changes to an open election: drops voters who left, and cancels it when
    /// the candidate left, an admin appeared or the group was upgraded.
    public static func reconcile<Id>(election: GroupAdminElection<Id>, members: [GroupAdminElectionMember<Id>], isUpgraded: Bool, now: Int32) -> GroupAdminElection<Id> {
        guard election.isOpen else {
            return election
        }
        var election = election
        if isUpgraded {
            election.outcome = .cancelled(date: now, reason: .groupUpgraded)
            return election
        }
        if !members.contains(where: { $0.id == election.candidateId && !$0.isDeleted }) {
            election.outcome = .cancelled(date: now, reason: .candidateLeft)
            return election
        }
        if members.contains(where: { $0.role != .member && !$0.isDeleted }) {
            election.outcome = .cancelled(date: now, reason: .adminReturned)
            return election
        }
        let present = Set(members.filter({ !$0.isDeleted }).map(\.id))
        election.voterIds = election.voterIds.filter { present.contains($0) }
        election.votes = election.votes.filter { present.contains($0.key) }
        return election
    }

    /// Whether an elected admin is still in probation and cannot remove members or add admins.
    public static func isInProbation<Id>(election: GroupAdminElection<Id>, now: Int32, rules: GroupAdminElectionRules) -> Bool {
        guard case let .elected(date) = election.outcome else {
            return false
        }
        return now - date < rules.probation
    }
}
