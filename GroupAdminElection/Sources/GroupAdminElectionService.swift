import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import GroupAdminElectionCore

public typealias PeerAdminElection = GroupAdminElection<EnginePeer.Id>
public typealias PeerAdminElectionMember = GroupAdminElectionMember<EnginePeer.Id>

/// Switches for recording a demo of the election on one device.
///
/// The server does not support member elections yet, so `GroupAdminElectionService` keeps
/// elections in memory and nobody else in the group sees them. With demo mode on, the other
/// eligible members cast simulated votes a moment apart, and members who joined recently can
/// vote too, so the whole flow can be shown in a freshly created group.
///
/// `xcrun simctl spawn booted defaults write ph.telegra.Telegraph GroupAdminElectionDemo -bool YES`
public enum GroupAdminElectionDemo {
    public static var isEnabled: Bool {
        return UserDefaults.standard.bool(forKey: "GroupAdminElectionDemo")
    }

    /// How likely a simulated voter says yes; set `GroupAdminElectionDemoYesShare` low to record a
    /// lost election.
    static var yesShare: Double {
        if let value = UserDefaults.standard.object(forKey: "GroupAdminElectionDemoYesShare") as? Double {
            return value
        }
        return 0.8
    }

    /// Seconds between simulated votes, `GroupAdminElectionDemoVoteInterval`.
    static var voteInterval: Double {
        if let value = UserDefaults.standard.object(forKey: "GroupAdminElectionDemoVoteInterval") as? Double, value > 0.0 {
            return value
        }
        return 0.3
    }

    static var rules: GroupAdminElectionRules {
        var rules = GroupAdminElectionRules.default
        if self.isEnabled {
            rules.minimumMembershipAge = 0
        }
        return rules
    }
}

public struct GroupAdminElectionPeerState: Equatable {
    public var adminlessReason: GroupAdminlessReason?
    /// The open election, or the last finished one until its result is dismissed.
    public var current: PeerAdminElection?
    public var members: [PeerAdminElectionMember]
    public var peers: [EnginePeer.Id: EnginePeer]
    public var rules: GroupAdminElectionRules

    public func canVote(_ peerId: EnginePeer.Id) -> Bool {
        guard let current = self.current, current.isOpen else {
            return false
        }
        return current.voterIds.contains(peerId) && current.votes[peerId] == nil
    }
}

/// Client side of member elections in basic groups that have no admin.
///
/// The proposed API is three calls and one update: `messages.proposeChatAdmin(chat_id, user_id)`,
/// `messages.voteChatAdmin(chat_id, election_id, yes)`, `messages.getChatAdminElection(chat_id)`
/// and `updateChatAdminElection`, with the server running `GroupAdminElectionLogic` as the source
/// of truth. Until it exists this service plays the server's part locally; everything that
/// renders an election reads it from here, so swapping in the network calls touches nothing else.
public final class GroupAdminElectionService {
    private static var services: [EnginePeer.Id: GroupAdminElectionService] = [:]

    public static func shared(context: AccountContext) -> GroupAdminElectionService {
        assert(Thread.isMainThread)
        if let service = self.services[context.account.peerId] {
            return service
        }
        let service = GroupAdminElectionService(context: context)
        self.services[context.account.peerId] = service
        return service
    }

    private final class PeerContext {
        let peerId: EnginePeer.Id
        let state = Promise<GroupAdminElectionPeerState?>(nil)
        var members: [PeerAdminElectionMember] = []
        var peers: [EnginePeer.Id: EnginePeer] = [:]
        var isBasicGroup = false
        /// Whether the member list arrived. Before it does, an empty list must not read as a
        /// group without admins.
        var isLoaded = false
        var isUpgraded = false
        var history: [PeerAdminElection] = []
        var dismissedElectionId: Int64?
        var dataDisposable: Disposable?
        var timer: SwiftSignalKit.Timer?
        var nextSimulatedVoteDate: Double = 0.0

        init(peerId: EnginePeer.Id) {
            self.peerId = peerId
        }
    }

    private let context: AccountContext
    private var peerContexts: [EnginePeer.Id: PeerContext] = [:]
    private var nextElectionId: Int64 = 1
    private let outcomesPipe = ValuePipe<(EnginePeer.Id, PeerAdminElection)>()
    private var visibleScreenPeerIds: [EnginePeer.Id: Int] = [:]

    /// Elections the moment they are decided. Every member gets the result as a modal and a
    /// service message in the chat (`updateChatAdminElection` and `messageActionChatAdminElected`
    /// in the proposed API).
    public var outcomes: Signal<(EnginePeer.Id, PeerAdminElection), NoError> {
        return self.outcomesPipe.signal()
    }

    /// Whether a vote sheet for the group is on screen, so the result is shown there instead of
    /// in a second sheet.
    public func isScreenVisible(peerId: EnginePeer.Id) -> Bool {
        return (self.visibleScreenPeerIds[peerId] ?? 0) > 0
    }

    func setScreenVisible(peerId: EnginePeer.Id, _ isVisible: Bool) {
        self.visibleScreenPeerIds[peerId, default: 0] += isVisible ? 1 : -1
    }

    private init(context: AccountContext) {
        self.context = context
    }

    /// The members with the elected admin, if any, counted as one: the server would have
    /// promoted them, so the group has an admin again.
    private func effectiveMembers(_ peerContext: PeerContext) -> [PeerAdminElectionMember] {
        guard let last = peerContext.history.last, case .elected = last.outcome else {
            return peerContext.members
        }
        return peerContext.members.map { member in
            var member = member
            if member.id == last.candidateId {
                member.role = .admin
            }
            return member
        }
    }

    private var now: Int32 {
        return Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970)
    }

    private func peerContext(_ peerId: EnginePeer.Id) -> PeerContext {
        if let peerContext = self.peerContexts[peerId] {
            return peerContext
        }
        let peerContext = PeerContext(peerId: peerId)
        self.peerContexts[peerId] = peerContext

        let engine = self.context.engine
        peerContext.dataDisposable = (engine.data.subscribe(
            TelegramEngine.EngineData.Item.Peer.Peer(id: peerId),
            TelegramEngine.EngineData.Item.Peer.LegacyGroupParticipants(id: peerId)
        )
        |> mapToSignal { peer, participants -> Signal<(EnginePeer?, [EngineLegacyGroupParticipant], [EnginePeer.Id: EnginePeer]), NoError> in
            guard case let .known(participants) = participants else {
                return .single((peer, [], [:]))
            }
            return engine.data.subscribe(EngineDataMap(participants.map { TelegramEngine.EngineData.Item.Peer.Peer(id: $0.peerId) }))
            |> map { peers in
                return (peer, participants, peers.compactMapValues { $0 })
            }
        }
        |> deliverOnMainQueue).startStrict(next: { [weak self, weak peerContext] peer, participants, peers in
            guard let self, let peerContext else {
                return
            }
            if case let .legacyGroup(group) = peer {
                peerContext.isBasicGroup = true
                peerContext.isUpgraded = group.migrationReference != nil
            } else {
                peerContext.isBasicGroup = false
            }
            peerContext.isLoaded = !participants.isEmpty
            peerContext.peers = peers
            peerContext.members = participants.map { participant in
                let peer = peers[participant.peerId]
                var isBot = false
                if case let .user(user) = peer, user.botInfo != nil {
                    isBot = true
                }
                let role: PeerAdminElectionMember.Role
                let joinDate: Int32?
                switch participant {
                case .creator:
                    role = .creator
                    joinDate = nil
                case let .admin(_, _, invitedAt, _):
                    role = .admin
                    joinDate = invitedAt
                case let .member(_, _, invitedAt, _):
                    role = .member
                    joinDate = invitedAt
                }
                return PeerAdminElectionMember(id: participant.peerId, role: role, joinDate: joinDate, isBot: isBot, isDeleted: peer?.isDeleted ?? false)
            }
            self.update(peerContext)
        })

        peerContext.timer = SwiftSignalKit.Timer(timeout: GroupAdminElectionDemo.isEnabled ? 0.1 : 1.0, repeat: true, completion: { [weak self, weak peerContext] in
            guard let self, let peerContext else {
                return
            }
            self.simulateRemoteVoteIfNeeded(peerContext)
            self.update(peerContext)
        }, queue: .mainQueue())
        peerContext.timer?.start()

        return peerContext
    }

    /// Reconciles the open election with the current members, decides it once it can be decided
    /// and publishes the new state.
    private func update(_ peerContext: PeerContext) {
        let now = self.now
        let rules = GroupAdminElectionDemo.rules
        if let index = peerContext.history.lastIndex(where: { $0.isOpen }) {
            var election = GroupAdminElectionLogic.reconcile(election: peerContext.history[index], members: peerContext.members, isUpgraded: peerContext.isUpgraded, now: now)
            if election.isOpen, let outcome = GroupAdminElectionLogic.decidedOutcome(election: election, now: now, rules: rules) {
                election.outcome = outcome
            }
            peerContext.history[index] = election
            if !election.isOpen {
                self.announce(election, in: peerContext)
                self.outcomesPipe.putNext((peerContext.peerId, election))
            }
        }

        guard peerContext.isBasicGroup, peerContext.isLoaded else {
            peerContext.state.set(.single(nil))
            return
        }
        var current = peerContext.history.last
        if let value = current, !value.isOpen, value.id == peerContext.dismissedElectionId {
            current = nil
        }
        let adminlessReason = GroupAdminElectionLogic.adminlessReason(members: self.effectiveMembers(peerContext), creatorLeftDate: nil, now: now, rules: rules)
        if adminlessReason == nil && current == nil {
            peerContext.state.set(.single(nil))
            return
        }
        peerContext.state.set(.single(GroupAdminElectionPeerState(
            adminlessReason: adminlessReason,
            current: current,
            members: peerContext.members,
            peers: peerContext.peers,
            rules: rules
        )))
    }

    private func simulateRemoteVoteIfNeeded(_ peerContext: PeerContext) {
        guard GroupAdminElectionDemo.isEnabled, let index = peerContext.history.lastIndex(where: { $0.isOpen }) else {
            return
        }
        let timestamp = CFAbsoluteTimeGetCurrent()
        if timestamp < peerContext.nextSimulatedVoteDate {
            return
        }
        let election = peerContext.history[index]
        let accountPeerId = self.context.account.peerId
        // Leave the account's own vote to the person recording, and hold back until they voted
        // when they can, so the decisive vote is not cast before the voting sheet is even open.
        let pending = election.voterIds.filter { $0 != accountPeerId && election.votes[$0] == nil }
        if election.voterIds.contains(accountPeerId) && election.votes[accountPeerId] == nil && pending.count <= 1 {
            return
        }
        guard let voterId = pending.randomElement() else {
            return
        }
        let interval = GroupAdminElectionDemo.voteInterval
        peerContext.nextSimulatedVoteDate = timestamp + Double.random(in: interval * 0.6 ... interval * 1.4)
        let yes = Double.random(in: 0.0 ..< 1.0) < GroupAdminElectionDemo.yesShare
        if case let .success(updated) = GroupAdminElectionLogic.vote(election: election, voterId: voterId, yes: yes, now: self.now) {
            peerContext.history[index] = updated
        }
    }

    /// Posts the service message for an election that started or ended.
    private func announce(_ election: PeerAdminElection, in peerContext: PeerContext) {
        func name(_ id: EnginePeer.Id) -> String {
            return peerContext.peers[id]?.compactDisplayTitle ?? "Deleted Account"
        }
        var parts: [(String, Bool)] = []
        switch election.outcome {
        case nil:
            if election.proposerId == election.candidateId {
                parts = [(name(election.proposerId), true), (" is running for admin. Members have \(GroupAdminElectionDemo.rules.duration / 3600) hours to vote.", false)]
            } else {
                parts = [(name(election.proposerId), true), (" proposed ", false), (name(election.candidateId), true), (" as admin. Members have \(GroupAdminElectionDemo.rules.duration / 3600) hours to vote.", false)]
            }
        case .elected:
            parts = [(name(election.candidateId), true), (" was elected admin by the members, \(election.yesCount) of \(election.turnout) voted yes 🎉", false)]
        case .rejected:
            parts = [(name(election.candidateId), true), (" wasn't elected admin, \(election.yesCount) of \(election.turnout) voted yes", false)]
        case let .cancelled(_, reason):
            switch reason {
            case .candidateLeft:
                parts = [("Admin election cancelled: ", false), (name(election.candidateId), true), (" left the group", false)]
            case .adminReturned:
                parts = [("Admin election cancelled: the group has an admin again", false)]
            case .groupUpgraded:
                parts = [("Admin election cancelled: the group was upgraded", false)]
            }
        }
        var text = ""
        var entities: [MessageTextEntity] = []
        for (part, isBold) in parts {
            let start = (text as NSString).length
            text += part
            if isBold {
                entities.append(MessageTextEntity(range: start ..< (text as NSString).length, type: .Bold))
            }
        }
        let _ = self.context.engine.messages.addLocalServiceMessage(peerId: peerContext.peerId, text: text, entities: entities).startStandalone()
    }

    public func state(peerId: EnginePeer.Id) -> Signal<GroupAdminElectionPeerState?, NoError> {
        return Signal { [weak self] subscriber in
            guard let self else {
                subscriber.putCompletion()
                return EmptyDisposable
            }
            return self.peerContext(peerId).state.get().startStandalone(next: subscriber.putNext)
        }
        |> runOn(.mainQueue())
    }

    /// Whether the account can propose `candidateId` now, and if not, why.
    public func validateProposal(peerId: EnginePeer.Id, candidateId: EnginePeer.Id) -> GroupAdminElectionProposeError? {
        let peerContext = self.peerContext(peerId)
        if !peerContext.isBasicGroup || !peerContext.isLoaded {
            return .groupHasAdmin
        }
        return GroupAdminElectionLogic.validateProposal(
            proposerId: self.context.account.peerId,
            candidateId: candidateId,
            members: self.effectiveMembers(peerContext),
            creatorLeftDate: nil,
            history: peerContext.history,
            now: self.now,
            rules: GroupAdminElectionDemo.rules
        )
    }

    public func propose(peerId: EnginePeer.Id, candidateId: EnginePeer.Id) -> GroupAdminElectionProposeError? {
        if let error = self.validateProposal(peerId: peerId, candidateId: candidateId) {
            return error
        }
        let peerContext = self.peerContext(peerId)
        let election = GroupAdminElectionLogic.makeElection(
            id: self.nextElectionId,
            proposerId: self.context.account.peerId,
            candidateId: candidateId,
            members: peerContext.members,
            now: self.now,
            rules: GroupAdminElectionDemo.rules
        )
        self.nextElectionId += 1
        peerContext.history.append(election)
        peerContext.nextSimulatedVoteDate = CFAbsoluteTimeGetCurrent() + 1.0
        self.announce(election, in: peerContext)
        self.update(peerContext)
        return nil
    }

    public func vote(peerId: EnginePeer.Id, yes: Bool) -> GroupAdminElectionVoteError? {
        let peerContext = self.peerContext(peerId)
        guard let index = peerContext.history.lastIndex(where: { $0.isOpen }) else {
            return .electionClosed
        }
        switch GroupAdminElectionLogic.vote(election: peerContext.history[index], voterId: self.context.account.peerId, yes: yes, now: self.now) {
        case let .success(election):
            peerContext.history[index] = election
            self.update(peerContext)
            return nil
        case let .failure(error):
            return error
        }
    }

    public func dismissResult(peerId: EnginePeer.Id) {
        let peerContext = self.peerContext(peerId)
        if let last = peerContext.history.last, !last.isOpen {
            peerContext.dismissedElectionId = last.id
            self.update(peerContext)
        }
    }

    /// `electedAdminId(peerId:)` as it changes.
    public func electedAdminIdSignal(peerId: EnginePeer.Id) -> Signal<EnginePeer.Id?, NoError> {
        return self.state(peerId: peerId)
        |> map { [weak self] _ -> EnginePeer.Id? in
            return self?.electedAdminId(peerId: peerId)
        }
        |> distinctUntilChanged
    }

    /// The member the group elected, while the server does not know about elections yet. The
    /// member list shows them as an admin.
    public func electedAdminId(peerId: EnginePeer.Id) -> EnginePeer.Id? {
        guard let last = self.peerContexts[peerId]?.history.last, case .elected = last.outcome else {
            return nil
        }
        return last.candidateId
    }
}
