import Foundation
import Display
import TelegramCore
import AccountContext
import PresentationDataUtils
import GroupAdminElectionCore

private func cooldownString(until: Int32) -> String {
    let now = Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970)
    let seconds = max(60, until - now)
    if seconds >= 2 * 24 * 60 * 60 {
        return "in \(seconds / (24 * 60 * 60)) days"
    }
    let hours = seconds / 3600
    if hours >= 1 {
        return hours == 1 ? "in 1 hour" : "in \(hours) hours"
    }
    return "in \(seconds / 60) min"
}

private func proposeErrorText(_ error: GroupAdminElectionProposeError, candidate: EnginePeer, isSelf: Bool) -> String {
    switch error {
    case .groupHasAdmin:
        return "This group already has an admin."
    case .electionInProgress:
        return "An election is already in progress. You can propose a new candidate when it ends."
    case .proposerCannotVote:
        return "Only members who have been in the group for a while can propose an admin."
    case .candidateNotMember:
        return "\(candidate.compactDisplayTitle) is no longer a member of this group."
    case .candidateIsBot:
        return "Bots can't be elected."
    case let .proposerCooldown(until):
        return "You've already proposed a candidate today. You can propose again \(cooldownString(until: until))."
    case let .candidateCooldown(until):
        let name = isSelf ? "You" : candidate.compactDisplayTitle
        return "\(name) lost a recent election and can be proposed again \(cooldownString(until: until))."
    case .notEnoughVoters:
        return "There's nobody who could vote yet. Members can vote after they've been in the group for a while."
    }
}

func groupAdminElectionProposeErrorAlert(context: AccountContext, error: GroupAdminElectionProposeError, candidate: EnginePeer) -> ViewController {
    return textAlertController(context: context, title: nil, text: proposeErrorText(error, candidate: candidate, isSelf: candidate.id == context.account.peerId), actions: [
        TextAlertAction(type: .defaultAction, title: "OK", action: {})
    ])
}

/// Whether the member list should offer to propose `candidate`: the group has no admin and the
/// candidate could run. Cooldowns and a running election still show the action, and explain
/// themselves when it is tapped.
public func groupAdminElectionCanOfferProposal(context: AccountContext, group: EnginePeer, candidate: EnginePeer) -> Bool {
    guard case .legacyGroup = group else {
        return false
    }
    if candidate.isDeleted {
        return false
    }
    if case let .user(user) = candidate, user.botInfo != nil {
        return false
    }
    switch GroupAdminElectionService.shared(context: context).validateProposal(peerId: group.id, candidateId: candidate.id) {
    case .groupHasAdmin, .candidateNotMember, .candidateIsBot:
        return false
    default:
        return true
    }
}

public func groupAdminElectionProposalTitle(context: AccountContext, candidate: EnginePeer) -> String {
    return candidate.id == context.account.peerId ? "Propose Myself as Admin" : "Propose as Admin"
}

/// Confirms the nomination, starts the election and opens the vote.
public func presentGroupAdminElectionProposal(context: AccountContext, group: EnginePeer, candidate: EnginePeer, present: @escaping (ViewController) -> Void, push: @escaping (ViewController) -> Void) {
    let service = GroupAdminElectionService.shared(context: context)
    let isSelf = candidate.id == context.account.peerId

    if let error = service.validateProposal(peerId: group.id, candidateId: candidate.id) {
        present(textAlertController(context: context, title: nil, text: proposeErrorText(error, candidate: candidate, isSelf: isSelf), actions: [
            TextAlertAction(type: .defaultAction, title: "OK", action: {})
        ]))
        return
    }

    let rules = GroupAdminElectionDemo.rules
    let hours = rules.duration / 3600
    let title = isSelf ? "Run for admin?" : "Propose \(candidate.compactDisplayTitle) as admin?"
    let text = "Everyone in \(group.compactDisplayTitle) will be asked to vote for \(hours) hours. \(isSelf ? "You" : candidate.compactDisplayTitle) will become an admin if at least half of the members vote and most of them say yes."
    present(textAlertController(context: context, title: title, text: text, actions: [
        TextAlertAction(type: .genericAction, title: "Cancel", action: {}),
        TextAlertAction(type: .defaultAction, title: "Start Vote", action: {
            if let error = service.propose(peerId: group.id, candidateId: candidate.id) {
                present(textAlertController(context: context, title: nil, text: proposeErrorText(error, candidate: candidate, isSelf: isSelf), actions: [
                    TextAlertAction(type: .defaultAction, title: "OK", action: {})
                ]))
                return
            }
            HapticFeedback().success()
            push(GroupAdminElectionScreen(context: context, group: group))
        })
    ], actionLayout: .vertical))
}
