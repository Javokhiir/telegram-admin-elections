import Foundation
import UIKit
import Display
import SwiftSignalKit
import AccountContext
import TelegramCore
import TelegramPresentationData
import ComponentFlow
import ViewControllerComponent
import SheetComponent
import AvatarComponent
import MultilineTextComponent
import ButtonComponent
import GroupAdminElectionCore
import ConfettiEffect

public func groupAdminElectionTimeLeftString(_ seconds: Int32) -> String {
    let seconds = max(0, seconds)
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    if hours > 0 {
        return "\(hours)h \(minutes)m left"
    } else if minutes > 0 {
        return "\(minutes)m left"
    } else {
        return "less than a minute left"
    }
}

public func groupAdminElectionMembersString(_ count: Int) -> String {
    return count == 1 ? "1 member" : "\(count) members"
}

private func durationString(_ seconds: Int32) -> String {
    let hours = seconds / 3600
    if hours >= 24 && hours % 24 == 0 {
        let days = hours / 24
        return days == 1 ? "1 day" : "\(days) days"
    }
    return hours == 1 ? "1 hour" : "\(hours) hours"
}

func groupAdminElectionRulesString(_ rules: GroupAdminElectionRules) -> String {
    var text = "Votes are public. "
    if rules.minimumMembershipAge > 0 {
        text += "Members who joined at least \(durationString(rules.minimumMembershipAge)) before the vote can take part, and at least half of them must vote. "
    } else {
        text += "At least half of the members must vote. "
    }
    text += "The new admin can't remove members or add admins for the first \(durationString(rules.probation))."
    return text
}

private final class ResultBarView: UIView {
    private let fill = UIView()
    private let titleLabel = UILabel()
    private let countLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        self.layer.cornerRadius = 12.0
        self.clipsToBounds = true
        self.addSubview(self.fill)
        self.addSubview(self.titleLabel)
        self.addSubview(self.countLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(title: String, count: Int, fraction: CGFloat, isSelected: Bool, color: UIColor, theme: PresentationTheme, size: CGSize, transition: ComponentTransition) {
        self.backgroundColor = theme.list.itemPrimaryTextColor.withMultipliedAlpha(0.06)
        self.fill.backgroundColor = color.withMultipliedAlpha(0.22)

        self.titleLabel.attributedText = NSAttributedString(string: isSelected ? "\(title)  ✓" : title, font: isSelected ? Font.semibold(16.0) : Font.medium(16.0), textColor: theme.list.itemPrimaryTextColor)
        self.countLabel.attributedText = NSAttributedString(string: "\(count)", font: Font.with(size: 16.0, weight: .semibold, traits: .monospacedNumbers), textColor: color)

        let titleSize = self.titleLabel.sizeThatFits(size)
        let countSize = self.countLabel.sizeThatFits(size)
        transition.setFrame(view: self.titleLabel, frame: CGRect(origin: CGPoint(x: 14.0, y: floorToScreenPixels((size.height - titleSize.height) / 2.0)), size: titleSize))
        transition.setFrame(view: self.countLabel, frame: CGRect(origin: CGPoint(x: size.width - 14.0 - countSize.width, y: floorToScreenPixels((size.height - countSize.height) / 2.0)), size: countSize))
        transition.setFrame(view: self.fill, frame: CGRect(origin: .zero, size: CGSize(width: size.width * max(0.0, min(1.0, fraction)), height: size.height)))
    }
}

private final class CandidateRowView: UIControl {
    private let avatar = ComponentView<Empty>()
    private let nameLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let separator = UIView()
    private let highlight = UIView()
    var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        self.highlight.alpha = 0.0
        self.highlight.isUserInteractionEnabled = false
        self.addSubview(self.highlight)
        self.nameLabel.isUserInteractionEnabled = false
        self.addSubview(self.nameLabel)
        self.subtitleLabel.isUserInteractionEnabled = false
        self.addSubview(self.subtitleLabel)
        self.addSubview(self.separator)
        self.addTarget(self, action: #selector(self.pressed), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: self.isHighlighted ? 0.05 : 0.25) {
                self.highlight.alpha = self.isHighlighted ? 1.0 : 0.0
            }
        }
    }

    @objc private func pressed() {
        self.action?()
    }

    func update(context: AccountContext, theme: PresentationTheme, peer: EnginePeer, subtitle: String, isLast: Bool, size: CGSize) {
        let avatarSize = self.avatar.update(transition: .immediate, component: AnyComponent(AvatarComponent(context: context, theme: theme, peer: peer)), environment: {}, containerSize: CGSize(width: 40.0, height: 40.0))
        if let avatarView = self.avatar.view {
            if avatarView.superview == nil {
                avatarView.isUserInteractionEnabled = false
                self.addSubview(avatarView)
            }
            avatarView.frame = CGRect(origin: CGPoint(x: 14.0, y: floorToScreenPixels((size.height - avatarSize.height) / 2.0)), size: avatarSize)
        }
        self.highlight.backgroundColor = theme.list.itemHighlightedBackgroundColor
        self.highlight.frame = CGRect(origin: .zero, size: size)
        self.nameLabel.attributedText = NSAttributedString(string: peer.displayTitle(strings: context.sharedContext.currentPresentationData.with({ $0 }).strings, displayOrder: .firstLast), font: Font.medium(16.0), textColor: theme.list.itemPrimaryTextColor)
        self.subtitleLabel.attributedText = NSAttributedString(string: subtitle, font: Font.regular(14.0), textColor: theme.list.itemSecondaryTextColor)
        let textX: CGFloat = 14.0 + 40.0 + 12.0
        let textWidth = size.width - textX - 14.0
        self.nameLabel.frame = CGRect(x: textX, y: 10.0, width: textWidth, height: 21.0)
        self.subtitleLabel.frame = CGRect(x: textX, y: 31.0, width: textWidth, height: 18.0)
        self.separator.backgroundColor = theme.list.itemPlainSeparatorColor
        self.separator.isHidden = isLast
        self.separator.frame = CGRect(x: textX, y: size.height - UIScreenPixel, width: size.width - textX, height: UIScreenPixel)
    }
}

private final class GroupAdminElectionContentComponent: Component {
    typealias EnvironmentType = ViewControllerComponentContainer.Environment

    let context: AccountContext
    let group: EnginePeer
    let state: GroupAdminElectionPeerState?
    let now: Int32
    let celebrate: Bool
    let vote: (Bool) -> Void
    let propose: (EnginePeer.Id) -> Void
    let dismiss: () -> Void

    init(context: AccountContext, group: EnginePeer, state: GroupAdminElectionPeerState?, now: Int32, celebrate: Bool, vote: @escaping (Bool) -> Void, propose: @escaping (EnginePeer.Id) -> Void, dismiss: @escaping () -> Void) {
        self.context = context
        self.group = group
        self.state = state
        self.now = now
        self.celebrate = celebrate
        self.vote = vote
        self.propose = propose
        self.dismiss = dismiss
    }

    static func ==(lhs: GroupAdminElectionContentComponent, rhs: GroupAdminElectionContentComponent) -> Bool {
        if lhs.context !== rhs.context {
            return false
        }
        if lhs.group != rhs.group {
            return false
        }
        if lhs.state != rhs.state {
            return false
        }
        if lhs.now != rhs.now {
            return false
        }
        return true
    }

    final class View: UIView {
        private let avatar = ComponentView<Empty>()
        private let badge = UIImageView()
        private let title = ComponentView<Empty>()
        private let subtitle = ComponentView<Empty>()
        private let resultsBackground = UIView()
        private let yesBar = ResultBarView()
        private let noBar = ResultBarView()
        private let turnout = ComponentView<Empty>()
        private let status = ComponentView<Empty>()
        private let primaryButton = ComponentView<Empty>()
        private let secondaryButton = ComponentView<Empty>()
        private let footer = ComponentView<Empty>()
        private var wasOpen = false
        private var didCelebrate = false
        private let containerView = UIView()
        private let candidatesBackground = UIView()
        private let candidatesScrollView = UIScrollView()
        private var candidateRows: [EnginePeer.Id: CandidateRowView] = [:]
        private var isShowingCandidates: Bool?

        override init(frame: CGRect) {
            super.init(frame: frame)

            self.addSubview(self.containerView)
            self.candidatesBackground.layer.cornerRadius = 22.0
            self.candidatesBackground.clipsToBounds = true
            self.candidatesScrollView.alwaysBounceVertical = false
            self.candidatesScrollView.showsVerticalScrollIndicator = true
            self.candidatesBackground.addSubview(self.candidatesScrollView)
            self.containerView.addSubview(self.candidatesBackground)

            self.resultsBackground.layer.cornerRadius = 22.0
            self.containerView.addSubview(self.resultsBackground)
            self.resultsBackground.addSubview(self.yesBar)
            self.resultsBackground.addSubview(self.noBar)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func place(_ view: ComponentView<Empty>, component: AnyComponent<Empty>, width: CGFloat, y: CGFloat, centered: Bool = true, sideInset: CGFloat, availableWidth: CGFloat, transition: ComponentTransition) -> CGFloat {
            let size = view.update(transition: transition, component: component, environment: {}, containerSize: CGSize(width: width, height: 1000.0))
            if let componentView = view.view {
                if componentView.superview == nil {
                    self.containerView.addSubview(componentView)
                }
                let x = centered ? floorToScreenPixels((availableWidth - size.width) / 2.0) : sideInset
                transition.setFrame(view: componentView, frame: CGRect(origin: CGPoint(x: x, y: y), size: size))
            }
            return size.height
        }

        private func button(title: String, isPrimary: Bool, theme: PresentationTheme, action: @escaping () -> Void) -> AnyComponent<Empty> {
            let background: ButtonComponent.Background
            let textColor: UIColor
            if isPrimary {
                background = ButtonComponent.Background(style: .glass, color: theme.list.itemCheckColors.fillColor, foreground: theme.list.itemCheckColors.foregroundColor, pressedColor: theme.list.itemCheckColors.fillColor.withMultipliedAlpha(0.9))
                textColor = theme.list.itemCheckColors.foregroundColor
            } else {
                background = ButtonComponent.Background(style: .glass, color: theme.list.itemPrimaryTextColor.withMultipliedAlpha(0.08), foreground: theme.list.itemPrimaryTextColor, pressedColor: theme.list.itemPrimaryTextColor.withMultipliedAlpha(0.14))
                textColor = theme.list.itemPrimaryTextColor
            }
            return AnyComponent(ButtonComponent(
                background: background,
                content: AnyComponentWithIdentity(id: title, component: AnyComponent(ButtonTextContentComponent(text: title, badge: 0, textColor: textColor, fontSize: 17.0, badgeBackground: textColor, badgeForeground: background.color))),
                action: action
            ))
        }

        /// The result moment: the new admin's avatar and badge pop in and confetti falls over the
        /// whole window.
        private func celebrate() {
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                if let avatarView = self.avatar.view {
                    avatarView.layer.animateSpring(from: 0.55 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.7, damping: 70.0)
                }
                self.badge.layer.animateSpring(from: 0.01 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.6, delay: 0.25, damping: 60.0)
                self.badge.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2, delay: 0.25)
                if let window = self.window {
                    window.addSubview(ConfettiView(frame: window.bounds))
                }
                HapticFeedback().success()
            }
        }

        func update(component: GroupAdminElectionContentComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<EnvironmentType>, transition: ComponentTransition) -> CGSize {
            let environment = environment[EnvironmentType.self].value
            let theme = environment.theme
            let sideInset: CGFloat = 24.0
            let contentWidth = max(1.0, availableSize.width - sideInset * 2.0)
            let accountPeerId = component.context.account.peerId

            let electionState = component.state
            let election = electionState?.current

            // Picking a candidate turns the list into the vote in place: the old page slides out
            // and the new one slides in while the sheet resizes.
            let isShowingCandidates = election == nil
            if let previous = self.isShowingCandidates, previous != isShowingCandidates, !transition.animation.isImmediate, let snapshot = self.containerView.snapshotView(afterScreenUpdates: false) {
                snapshot.frame = self.containerView.frame
                self.addSubview(snapshot)
                let offset: CGFloat = isShowingCandidates ? 60.0 : -60.0
                UIView.animate(withDuration: 0.35, delay: 0.0, options: [.curveEaseInOut], animations: {
                    snapshot.alpha = 0.0
                    snapshot.transform = CGAffineTransform(translationX: offset, y: 0.0)
                }, completion: { _ in
                    snapshot.removeFromSuperview()
                })
                self.containerView.alpha = 0.0
                self.containerView.transform = CGAffineTransform(translationX: -offset, y: 0.0)
                UIView.animate(withDuration: 0.45, delay: 0.08, usingSpringWithDamping: 0.86, initialSpringVelocity: 0.0, options: [], animations: {
                    self.containerView.alpha = 1.0
                    self.containerView.transform = .identity
                })
            }
            self.isShowingCandidates = isShowingCandidates
            func name(_ id: EnginePeer.Id) -> String {
                return electionState?.peers[id]?.compactDisplayTitle ?? "Deleted Account"
            }

            let avatarPeer: EnginePeer?
            if let election {
                avatarPeer = electionState?.peers[election.candidateId]
            } else {
                avatarPeer = component.group
            }

            let titleText: String
            let subtitleText: String
            var badgeName: String?
            switch election?.outcome {
            case nil:
                if let election {
                    titleText = "Make \(name(election.candidateId)) an admin?"
                    let proposer = election.proposerId == accountPeerId ? "you" : name(election.proposerId)
                    subtitleText = "Proposed by \(proposer) · \(groupAdminElectionTimeLeftString(election.endDate - component.now))"
                } else {
                    titleText = "This group has no admin"
                    switch electionState?.adminlessReason {
                    case .creatorDeleted:
                        subtitleText = "The owner deleted their account, so nobody can manage \(component.group.compactDisplayTitle) anymore. Pick someone to run for admin."
                    default:
                        subtitleText = "The owner left and nobody else can manage \(component.group.compactDisplayTitle). Pick someone to run for admin."
                    }
                }
            case .elected:
                titleText = "\(name(election!.candidateId)) is now an admin"
                subtitleText = "Elected by \(election!.yesCount) of \(groupAdminElectionMembersString(election!.voterIds.count))."
                badgeName = "checkmark.seal.fill"
            case .rejected:
                titleText = "\(name(election!.candidateId)) wasn't elected"
                let required = GroupAdminElectionLogic.requiredTurnout(voterCount: election!.voterIds.count, rules: electionState?.rules ?? .default)
                if election!.turnout < required {
                    subtitleText = "Not enough members voted. Any member can propose a new candidate."
                } else {
                    subtitleText = "Most members voted no. Any member can propose a new candidate."
                }
                badgeName = "xmark.seal.fill"
            case let .cancelled(_, reason):
                titleText = "Election cancelled"
                switch reason {
                case .candidateLeft:
                    subtitleText = "\(name(election!.candidateId)) left the group."
                case .adminReturned:
                    subtitleText = "The group has an admin again."
                case .groupUpgraded:
                    subtitleText = "The group was upgraded to a supergroup."
                }
                badgeName = "minus.circle.fill"
            }

            var contentHeight: CGFloat = 32.0

            let avatarSize = self.avatar.update(
                transition: transition,
                component: AnyComponent(AvatarComponent(context: component.context, theme: theme, peer: avatarPeer)),
                environment: {},
                containerSize: CGSize(width: 92.0, height: 92.0)
            )
            let avatarFrame = CGRect(origin: CGPoint(x: floorToScreenPixels((availableSize.width - avatarSize.width) / 2.0), y: contentHeight), size: avatarSize)
            if let avatarView = self.avatar.view {
                if avatarView.superview == nil {
                    self.containerView.addSubview(avatarView)
                    self.containerView.addSubview(self.badge)
                }
                transition.setFrame(view: avatarView, frame: avatarFrame)
            }
            if let badgeName {
                let color: UIColor
                switch election?.outcome {
                case .elected:
                    color = UIColor(rgb: 0x34c759)
                case .rejected:
                    color = theme.list.itemDestructiveColor
                default:
                    color = theme.list.itemSecondaryTextColor
                }
                self.badge.image = UIImage(systemName: badgeName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 26.0, weight: .semibold))?.withRenderingMode(.alwaysTemplate)
                self.badge.tintColor = color
                self.badge.backgroundColor = theme.list.modalBlocksBackgroundColor
                self.badge.layer.cornerRadius = 17.0
                self.badge.contentMode = .center
                self.badge.isHidden = false
                transition.setFrame(view: self.badge, frame: CGRect(x: avatarFrame.maxX - 30.0, y: avatarFrame.maxY - 30.0, width: 34.0, height: 34.0))
            } else {
                self.badge.isHidden = true
            }
            contentHeight += avatarSize.height + 16.0

            var isElected = false
            if case .elected = election?.outcome {
                isElected = true
            }
            if isElected && !self.didCelebrate && (self.wasOpen || component.celebrate) {
                self.didCelebrate = true
                self.celebrate()
            }
            self.wasOpen = election?.isOpen ?? false

            contentHeight += self.place(self.title, component: AnyComponent(MultilineTextComponent(
                text: .plain(NSAttributedString(string: titleText, font: Font.semibold(22.0), textColor: theme.list.itemPrimaryTextColor)),
                horizontalAlignment: .center,
                maximumNumberOfLines: 2
            )), width: contentWidth, y: contentHeight, sideInset: sideInset, availableWidth: availableSize.width, transition: transition)
            contentHeight += 8.0

            contentHeight += self.place(self.subtitle, component: AnyComponent(MultilineTextComponent(
                text: .plain(NSAttributedString(string: subtitleText, font: Font.regular(15.0), textColor: theme.list.itemSecondaryTextColor)),
                horizontalAlignment: .center,
                maximumNumberOfLines: 0,
                lineSpacing: 0.15
            )), width: contentWidth, y: contentHeight, sideInset: sideInset, availableWidth: availableSize.width, transition: transition)
            contentHeight += 22.0

            if let election, let electionState {
                self.resultsBackground.isHidden = false
                self.resultsBackground.backgroundColor = theme.list.itemBlocksBackgroundColor
                let barHeight: CGFloat = 46.0
                let inset: CGFloat = 8.0
                let voters = CGFloat(max(1, election.voterIds.count))
                let myVote = election.votes[accountPeerId]
                let barWidth = contentWidth - inset * 2.0
                self.yesBar.update(title: "Yes", count: election.yesCount, fraction: CGFloat(election.yesCount) / voters, isSelected: myVote == true, color: UIColor(rgb: 0x34c759), theme: theme, size: CGSize(width: barWidth, height: barHeight), transition: transition)
                self.noBar.update(title: "No", count: election.noCount, fraction: CGFloat(election.noCount) / voters, isSelected: myVote == false, color: theme.list.itemDestructiveColor, theme: theme, size: CGSize(width: barWidth, height: barHeight), transition: transition)
                transition.setFrame(view: self.yesBar, frame: CGRect(x: inset, y: inset, width: barWidth, height: barHeight))
                transition.setFrame(view: self.noBar, frame: CGRect(x: inset, y: inset + barHeight + 6.0, width: barWidth, height: barHeight))
                let resultsHeight = inset * 2.0 + barHeight * 2.0 + 6.0
                transition.setFrame(view: self.resultsBackground, frame: CGRect(x: sideInset, y: contentHeight, width: contentWidth, height: resultsHeight))
                contentHeight += resultsHeight + 10.0

                let required = GroupAdminElectionLogic.requiredTurnout(voterCount: election.voterIds.count, rules: electionState.rules)
                var turnoutText = "\(election.turnout) of \(groupAdminElectionMembersString(election.voterIds.count)) voted"
                if election.isOpen {
                    if election.voterIds.count < electionState.rules.unanimityThreshold {
                        turnoutText += " · everyone has to agree"
                    } else {
                        turnoutText += " · \(required) needed"
                    }
                }
                contentHeight += self.place(self.turnout, component: AnyComponent(MultilineTextComponent(
                    text: .plain(NSAttributedString(string: turnoutText, font: Font.regular(13.0), textColor: theme.list.itemSecondaryTextColor)),
                    horizontalAlignment: .center
                )), width: contentWidth, y: contentHeight, sideInset: sideInset, availableWidth: availableSize.width, transition: transition)
                contentHeight += 22.0
            } else {
                self.resultsBackground.isHidden = true
                self.turnout.view?.isHidden = true
            }
            self.turnout.view?.isHidden = election == nil

            var statusText: String?
            if let election, election.isOpen, let electionState, !electionState.canVote(accountPeerId) {
                if election.candidateId == accountPeerId {
                    statusText = "You can't vote in your own election."
                } else if election.votes[accountPeerId] != nil {
                    statusText = "Thanks for voting. The result will be shared with the group."
                } else {
                    statusText = "Only members who joined before the vote can take part."
                }
            }
            if let statusText {
                contentHeight += self.place(self.status, component: AnyComponent(MultilineTextComponent(
                    text: .plain(NSAttributedString(string: statusText, font: Font.medium(15.0), textColor: theme.list.itemPrimaryTextColor)),
                    horizontalAlignment: .center,
                    maximumNumberOfLines: 0
                )), width: contentWidth, y: contentHeight, sideInset: sideInset, availableWidth: availableSize.width, transition: transition)
                contentHeight += 18.0
                self.status.view?.isHidden = false
            } else {
                self.status.view?.isHidden = true
            }

            let buttonHeight: CGFloat = 52.0
            if let election, election.isOpen, electionState?.canVote(accountPeerId) == true {
                let halfWidth = floor((contentWidth - 10.0) / 2.0)
                let noSize = self.secondaryButton.update(transition: transition, component: self.button(title: "No", isPrimary: false, theme: theme, action: { component.vote(false) }), environment: {}, containerSize: CGSize(width: halfWidth, height: buttonHeight))
                let yesSize = self.primaryButton.update(transition: transition, component: self.button(title: "Yes", isPrimary: true, theme: theme, action: { component.vote(true) }), environment: {}, containerSize: CGSize(width: halfWidth, height: buttonHeight))
                if let view = self.secondaryButton.view {
                    if view.superview == nil {
                        self.containerView.addSubview(view)
                    }
                    view.isHidden = false
                    transition.setFrame(view: view, frame: CGRect(origin: CGPoint(x: sideInset, y: contentHeight), size: noSize))
                }
                if let view = self.primaryButton.view {
                    if view.superview == nil {
                        self.containerView.addSubview(view)
                    }
                    view.isHidden = false
                    transition.setFrame(view: view, frame: CGRect(origin: CGPoint(x: sideInset + halfWidth + 10.0, y: contentHeight), size: yesSize))
                }
                contentHeight += buttonHeight + 20.0
            } else if election == nil {
                self.secondaryButton.view?.isHidden = true
                self.primaryButton.view?.isHidden = true
                contentHeight += self.updateCandidates(component: component, theme: theme, electionState: electionState, sideInset: sideInset, contentWidth: contentWidth, y: contentHeight, maxHeight: max(160.0, availableSize.height * 0.42))
                contentHeight += 16.0
            } else {
                self.secondaryButton.view?.isHidden = true
                let size = self.primaryButton.update(transition: transition, component: self.button(title: "Done", isPrimary: true, theme: theme, action: component.dismiss), environment: {}, containerSize: CGSize(width: contentWidth, height: buttonHeight))
                if let view = self.primaryButton.view {
                    if view.superview == nil {
                        self.containerView.addSubview(view)
                    }
                    view.isHidden = false
                    transition.setFrame(view: view, frame: CGRect(origin: CGPoint(x: sideInset, y: contentHeight), size: size))
                }
                contentHeight += buttonHeight + 20.0
            }
            self.candidatesBackground.isHidden = election != nil

            contentHeight += self.place(self.footer, component: AnyComponent(MultilineTextComponent(
                text: .plain(NSAttributedString(string: groupAdminElectionRulesString(electionState?.rules ?? .default), font: Font.regular(13.0), textColor: theme.list.itemSecondaryTextColor)),
                horizontalAlignment: .center,
                maximumNumberOfLines: 0,
                lineSpacing: 0.15
            )), width: contentWidth, y: contentHeight, sideInset: sideInset, availableWidth: availableSize.width, transition: transition)
            contentHeight += environment.safeInsets.bottom + 24.0

            self.containerView.bounds = CGRect(origin: .zero, size: CGSize(width: availableSize.width, height: contentHeight))
            self.containerView.center = CGPoint(x: availableSize.width / 2.0, y: contentHeight / 2.0)
            return CGSize(width: availableSize.width, height: contentHeight)
        }

        /// The members who can run, the account first so anyone can put themselves forward.
        private func updateCandidates(component: GroupAdminElectionContentComponent, theme: PresentationTheme, electionState: GroupAdminElectionPeerState?, sideInset: CGFloat, contentWidth: CGFloat, y: CGFloat, maxHeight: CGFloat) -> CGFloat {
            let accountPeerId = component.context.account.peerId
            var candidates: [EnginePeer] = []
            for member in electionState?.members ?? [] {
                guard !member.isBot, !member.isDeleted, let peer = electionState?.peers[member.id] else {
                    continue
                }
                if member.id == accountPeerId {
                    candidates.insert(peer, at: 0)
                } else {
                    candidates.append(peer)
                }
            }

            let rowHeight: CGFloat = 60.0
            var validIds = Set<EnginePeer.Id>()
            for (index, peer) in candidates.enumerated() {
                validIds.insert(peer.id)
                let row: CandidateRowView
                if let current = self.candidateRows[peer.id] {
                    row = current
                } else {
                    row = CandidateRowView()
                    self.candidateRows[peer.id] = row
                    self.candidatesScrollView.addSubview(row)
                }
                let peerId = peer.id
                row.action = {
                    component.propose(peerId)
                }
                let subtitle = peer.id == accountPeerId ? "Run for admin yourself" : "Propose as admin"
                row.update(context: component.context, theme: theme, peer: peer, subtitle: subtitle, isLast: index == candidates.count - 1, size: CGSize(width: contentWidth, height: rowHeight))
                row.frame = CGRect(x: 0.0, y: CGFloat(index) * rowHeight, width: contentWidth, height: rowHeight)
            }
            for (id, row) in self.candidateRows where !validIds.contains(id) {
                row.removeFromSuperview()
                self.candidateRows[id] = nil
            }

            let listHeight = CGFloat(candidates.count) * rowHeight
            let height = min(listHeight, maxHeight)
            self.candidatesBackground.backgroundColor = theme.list.itemBlocksBackgroundColor
            self.candidatesBackground.frame = CGRect(x: sideInset, y: y, width: contentWidth, height: height)
            self.candidatesScrollView.frame = CGRect(origin: .zero, size: CGSize(width: contentWidth, height: height))
            self.candidatesScrollView.contentSize = CGSize(width: contentWidth, height: listHeight)
            return height
        }
    }

    func makeView() -> View {
        return View(frame: CGRect())
    }

    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<EnvironmentType>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}

private final class GroupAdminElectionScreenComponent: Component {
    typealias EnvironmentType = ViewControllerComponentContainer.Environment

    let context: AccountContext
    let group: EnginePeer
    let celebrate: Bool

    init(context: AccountContext, group: EnginePeer, celebrate: Bool) {
        self.context = context
        self.group = group
        self.celebrate = celebrate
    }

    static func ==(lhs: GroupAdminElectionScreenComponent, rhs: GroupAdminElectionScreenComponent) -> Bool {
        if lhs.context !== rhs.context {
            return false
        }
        if lhs.group != rhs.group {
            return false
        }
        return true
    }

    final class View: UIView {
        private let sheet = ComponentView<(EnvironmentType, SheetComponentEnvironment)>()
        private let animateOut = ActionSlot<Action<Void>>()

        private var component: GroupAdminElectionScreenComponent?
        private var environment: EnvironmentType?
        private weak var state: EmptyComponentState?
        private var electionState: GroupAdminElectionPeerState?
        private var stateDisposable: Disposable?

        deinit {
            self.stateDisposable?.dispose()
            if let component = self.component {
                GroupAdminElectionService.shared(context: component.context).setScreenVisible(peerId: component.group.id, false)
            }
        }

        private func dismiss(animated: Bool, completion: (() -> Void)? = nil) {
            guard let controller = self.environment?.controller else {
                completion?()
                return
            }
            if animated {
                self.animateOut.invoke(Action { _ in
                    controller()?.dismiss(completion: completion)
                })
            } else {
                controller()?.dismiss(animated: false, completion: completion)
            }
        }

        func update(component: GroupAdminElectionScreenComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<EnvironmentType>, transition: ComponentTransition) -> CGSize {
            if self.stateDisposable == nil {
                GroupAdminElectionService.shared(context: component.context).setScreenVisible(peerId: component.group.id, true)
                self.stateDisposable = (GroupAdminElectionService.shared(context: component.context).state(peerId: component.group.id)
                |> deliverOnMainQueue).startStrict(next: { [weak self] electionState in
                    guard let self else {
                        return
                    }
                    // The service republishes every second for the countdown; only animate real changes.
                    let animate = self.electionState != nil && self.electionState != electionState
                    self.electionState = electionState
                    self.state?.updated(transition: animate ? .spring(duration: 0.4) : .immediate)
                })
            }
            self.component = component
            self.state = state
            let environment = environment[EnvironmentType.self].value
            self.environment = environment
            let theme = environment.theme
            let service = GroupAdminElectionService.shared(context: component.context)
            let groupId = component.group.id

            let sheetSize = self.sheet.update(
                transition: transition,
                component: AnyComponent(SheetComponent<EnvironmentType>(
                    content: AnyComponent<EnvironmentType>(GroupAdminElectionContentComponent(
                        context: component.context,
                        group: component.group,
                        state: self.electionState,
                        now: Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970),
                        celebrate: component.celebrate,
                        vote: { yes in
                            let _ = service.vote(peerId: groupId, yes: yes)
                            HapticFeedback().success()
                        },
                        propose: { [weak self] candidateId in
                            guard let self, let candidate = self.electionState?.peers[candidateId] else {
                                return
                            }
                            if let error = service.propose(peerId: groupId, candidateId: candidateId) {
                                self.environment?.controller()?.present(groupAdminElectionProposeErrorAlert(context: component.context, error: error, candidate: candidate), in: .window(.root))
                            } else {
                                HapticFeedback().impact(.medium)
                            }
                        },
                        dismiss: { [weak self] in
                            if let current = self?.electionState?.current, !current.isOpen {
                                service.dismissResult(peerId: groupId)
                            }
                            self?.dismiss(animated: true)
                        }
                    )),
                    style: .glass,
                    backgroundColor: .color(theme.list.modalBlocksBackgroundColor),
                    followContentSizeChanges: true,
                    clipsContent: true,
                    animateOut: self.animateOut
                )),
                environment: {
                    environment
                    SheetComponentEnvironment(
                        metrics: environment.metrics,
                        deviceMetrics: environment.deviceMetrics,
                        isDisplaying: environment.isVisible,
                        isCentered: environment.metrics.widthClass == .regular,
                        hasInputHeight: !environment.inputHeight.isZero,
                        regularMetricsSize: CGSize(width: 430.0, height: 900.0),
                        dismiss: { [weak self] animated in
                            self?.dismiss(animated: animated)
                        }
                    )
                },
                containerSize: availableSize
            )
            if let sheetView = self.sheet.view {
                if sheetView.superview == nil {
                    self.addSubview(sheetView)
                }
                transition.setFrame(view: sheetView, frame: CGRect(origin: .zero, size: sheetSize))
            }

            return availableSize
        }
    }

    func makeView() -> View {
        return View(frame: CGRect())
    }

    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<EnvironmentType>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}

/// The vote itself: who is running, how the group voted so far and the Yes / No buttons. With
/// no election running it explains that the group has no admin and how to propose one.
public final class GroupAdminElectionScreen: ViewControllerComponentContainer {
    /// `celebrate` plays the result animation when the sheet opens on an election that was just won.
    public init(context: AccountContext, group: EnginePeer, celebrate: Bool = false) {
        super.init(
            context: context,
            component: GroupAdminElectionScreenComponent(context: context, group: group, celebrate: celebrate),
            navigationBarAppearance: .none,
            statusBarStyle: .ignore,
            theme: .default
        )

        self.navigationPresentation = .flatModal
        self.blocksBackgroundWhenInOverlay = true
    }

    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
