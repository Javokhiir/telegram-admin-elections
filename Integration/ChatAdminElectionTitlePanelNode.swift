import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AnimatedAvatarSetNode
import AccountContext
import ChatPresentationInterfaceState
import LegacyChatHeaderPanelComponent
import GroupAdminElection
import GroupAdminElectionCore

/// The bar on top of a basic group without an admin: invites members to elect one, follows the
/// running election and reports its result.
final class ChatAdminElectionTitlePanelNode: ChatTitleAccessoryPanelNode {
    private final class Params {
        let width: CGFloat
        let leftInset: CGFloat
        let rightInset: CGFloat
        let interfaceState: ChatPresentationInterfaceState

        init(width: CGFloat, leftInset: CGFloat, rightInset: CGFloat, interfaceState: ChatPresentationInterfaceState) {
            self.width = width
            self.leftInset = leftInset
            self.rightInset = rightInset
            self.interfaceState = interfaceState
        }
    }

    private let context: AccountContext
    let peerId: EnginePeer.Id

    private let separatorNode: ASDisplayNode
    private let button: HighlightableButtonNode
    private let iconNode: ASImageNode
    private let avatarsContext: AnimatedAvatarSetContext
    private let avatarsNode: AnimatedAvatarSetNode
    private let titleNode: ImmediateTextNode
    private let subtitleNode: ImmediateTextNode
    private let actionBackgroundNode: ASDisplayNode
    private let actionTitleNode: ImmediateTextNode
    private let closeButton: HighlightableButtonNode
    private let activateAreaNode: AccessibilityAreaNode

    private var theme: PresentationTheme?
    private var params: Params?
    private var electionState: GroupAdminElectionPeerState?
    private var stateDisposable: Disposable?

    init(context: AccountContext, peerId: EnginePeer.Id) {
        self.context = context
        self.peerId = peerId

        self.separatorNode = ASDisplayNode()
        self.separatorNode.isLayerBacked = true

        self.button = HighlightableButtonNode()

        self.iconNode = ASImageNode()
        self.iconNode.displaysAsynchronously = false
        self.iconNode.contentMode = .center

        self.avatarsContext = AnimatedAvatarSetContext()
        self.avatarsNode = AnimatedAvatarSetNode()
        self.avatarsNode.isUserInteractionEnabled = false

        self.titleNode = ImmediateTextNode()
        self.titleNode.maximumNumberOfLines = 1
        self.titleNode.isUserInteractionEnabled = false
        self.subtitleNode = ImmediateTextNode()
        self.subtitleNode.maximumNumberOfLines = 1
        self.subtitleNode.isUserInteractionEnabled = false

        self.actionBackgroundNode = ASDisplayNode()
        self.actionBackgroundNode.isUserInteractionEnabled = false
        self.actionTitleNode = ImmediateTextNode()
        self.actionTitleNode.isUserInteractionEnabled = false

        self.closeButton = HighlightableButtonNode()
        self.closeButton.hitTestSlop = UIEdgeInsets(top: -8.0, left: -8.0, bottom: -8.0, right: -8.0)
        self.closeButton.displaysAsynchronously = false

        self.activateAreaNode = AccessibilityAreaNode()
        self.activateAreaNode.accessibilityTraits = .button

        super.init()

        self.addSubnode(self.separatorNode)
        self.button.addTarget(self, action: #selector(self.buttonPressed), forControlEvents: .touchUpInside)
        self.addSubnode(self.button)
        self.addSubnode(self.iconNode)
        self.addSubnode(self.avatarsNode)
        self.addSubnode(self.titleNode)
        self.addSubnode(self.subtitleNode)
        self.addSubnode(self.actionBackgroundNode)
        self.actionBackgroundNode.addSubnode(self.actionTitleNode)
        self.closeButton.addTarget(self, action: #selector(self.closePressed), forControlEvents: .touchUpInside)
        self.addSubnode(self.closeButton)
        self.addSubnode(self.activateAreaNode)

        self.stateDisposable = (GroupAdminElectionService.shared(context: context).state(peerId: peerId)
        |> deliverOnMainQueue).startStrict(next: { [weak self] state in
            guard let self else {
                return
            }
            let candidateChanged = self.electionState?.current?.candidateId != state?.current?.candidateId
            self.electionState = state
            if let params = self.params {
                let _ = self.updateLayout(width: params.width, leftInset: params.leftInset, rightInset: params.rightInset, transition: candidateChanged ? .immediate : .animated(duration: 0.25, curve: .easeInOut), interfaceState: params.interfaceState)
            }
        })
    }

    deinit {
        self.stateDisposable?.dispose()
    }

    override func updateLayout(width: CGFloat, leftInset: CGFloat, rightInset: CGFloat, transition: ContainedViewLayoutTransition, interfaceState: ChatPresentationInterfaceState) -> LayoutResult {
        self.params = Params(width: width, leftInset: leftInset, rightInset: rightInset, interfaceState: interfaceState)
        let theme = interfaceState.theme

        if theme !== self.theme {
            self.theme = theme
            self.separatorNode.backgroundColor = theme.rootController.navigationBar.separatorColor
            self.closeButton.setImage(generateImage(CGSize(width: 12.0, height: 12.0), contextGenerator: { size, context in
                context.clear(CGRect(origin: CGPoint(), size: size))
                context.setStrokeColor(theme.chat.inputPanel.panelControlColor.cgColor)
                context.setLineWidth(1.33)
                context.setLineCap(.round)
                context.move(to: CGPoint(x: 1.0, y: 1.0))
                context.addLine(to: CGPoint(x: size.width - 1.0, y: size.height - 1.0))
                context.strokePath()
                context.move(to: CGPoint(x: size.width - 1.0, y: 1.0))
                context.addLine(to: CGPoint(x: 1.0, y: size.height - 1.0))
                context.strokePath()
            }), for: [])
        }

        let panelHeight: CGFloat = 50.0
        let accountPeerId = self.context.account.peerId
        let state = self.electionState
        let election = state?.current
        let now = Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970)
        func name(_ id: EnginePeer.Id) -> String {
            return state?.peers[id]?.compactDisplayTitle ?? "Deleted Account"
        }

        let title: String
        let subtitle: String
        var actionTitle: String?
        var actionIsPrimary = true
        var displayClose = false
        var iconName: String?
        var iconColor = theme.chat.inputPanel.panelControlAccentColor

        switch election?.outcome {
        case nil:
            if let election {
                title = "Admin election · \(name(election.candidateId))"
                subtitle = "\(election.turnout) of \(election.voterIds.count) voted · \(groupAdminElectionTimeLeftString(election.endDate - now))"
                if state?.canVote(accountPeerId) == true {
                    actionTitle = "Vote"
                } else {
                    actionTitle = "View"
                    actionIsPrimary = false
                }
            } else {
                title = "This group has no admin"
                subtitle = "Members can elect a new one"
                actionTitle = "Elect"
                iconName = "person.crop.circle.badge.questionmark"
            }
        case .elected:
            title = "\(name(election!.candidateId)) is now an admin"
            subtitle = "Elected by \(election!.yesCount) of \(election!.voterIds.count) members"
            displayClose = true
        case .rejected:
            title = "\(name(election!.candidateId)) wasn't elected"
            subtitle = "Any member can propose a new candidate"
            displayClose = true
        case .cancelled:
            title = "Admin election cancelled"
            subtitle = "Tap to see why"
            displayClose = true
            iconName = "minus.circle"
            iconColor = theme.chat.inputPanel.panelControlColor
        }

        let leadingSize = CGSize(width: 32.0, height: 32.0)
        let leadingFrame = CGRect(origin: CGPoint(x: leftInset + 12.0, y: floorToScreenPixels((panelHeight - leadingSize.height) / 2.0)), size: leadingSize)
        if let iconName {
            self.iconNode.image = UIImage(systemName: iconName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22.0, weight: .regular))?.withTintColor(iconColor, renderingMode: .alwaysOriginal)
            self.iconNode.isHidden = false
            self.avatarsNode.isHidden = true
            transition.updateFrame(node: self.iconNode, frame: leadingFrame)
        } else {
            self.iconNode.isHidden = true
            self.avatarsNode.isHidden = false
            var peers: [EnginePeer] = []
            if let election, let candidate = state?.peers[election.candidateId] {
                peers.append(candidate)
            }
            let content = self.avatarsContext.update(peers: peers, animated: false)
            let avatarsSize = self.avatarsNode.update(context: self.context, content: content, itemSize: leadingSize, animated: false, synchronousLoad: true)
            transition.updateFrame(node: self.avatarsNode, frame: CGRect(origin: leadingFrame.origin, size: avatarsSize))
        }

        var trailingX = width - rightInset - 14.0
        if displayClose {
            self.closeButton.isHidden = false
            self.actionBackgroundNode.isHidden = true
            let closeSize = self.closeButton.measure(CGSize(width: 100.0, height: 100.0))
            let closeFrame = CGRect(origin: CGPoint(x: trailingX - closeSize.width - 3.0, y: floorToScreenPixels((panelHeight - closeSize.height) / 2.0)), size: closeSize)
            transition.updateFrame(node: self.closeButton, frame: closeFrame)
            trailingX = closeFrame.minX - 12.0
        } else {
            self.closeButton.isHidden = true
        }
        if let actionTitle {
            self.actionBackgroundNode.isHidden = false
            let foreground = actionIsPrimary ? theme.chat.inputPanel.actionControlForegroundColor : theme.chat.inputPanel.panelControlAccentColor
            let background = actionIsPrimary ? theme.chat.inputPanel.actionControlFillColor : theme.chat.inputPanel.panelControlAccentColor.withMultipliedAlpha(0.12)
            self.actionTitleNode.attributedText = NSAttributedString(string: actionTitle, font: Font.semibold(14.0), textColor: foreground)
            let actionTitleSize = self.actionTitleNode.updateLayout(CGSize(width: 120.0, height: 30.0))
            let actionSize = CGSize(width: actionTitleSize.width + 28.0, height: 28.0)
            let actionFrame = CGRect(origin: CGPoint(x: trailingX - actionSize.width, y: floorToScreenPixels((panelHeight - actionSize.height) / 2.0)), size: actionSize)
            self.actionBackgroundNode.backgroundColor = background
            self.actionBackgroundNode.cornerRadius = actionSize.height / 2.0
            transition.updateFrame(node: self.actionBackgroundNode, frame: actionFrame)
            self.actionTitleNode.frame = CGRect(origin: CGPoint(x: floorToScreenPixels((actionSize.width - actionTitleSize.width) / 2.0), y: floorToScreenPixels((actionSize.height - actionTitleSize.height) / 2.0)), size: actionTitleSize)
            trailingX = actionFrame.minX - 10.0
        }

        let textX = leadingFrame.maxX + 10.0
        let textWidth = max(1.0, trailingX - textX)
        self.titleNode.attributedText = NSAttributedString(string: title, font: Font.semibold(15.0), textColor: theme.chat.inputPanel.primaryTextColor)
        self.subtitleNode.attributedText = NSAttributedString(string: subtitle, font: Font.regular(13.0), textColor: theme.chat.inputPanel.secondaryTextColor)
        let titleSize = self.titleNode.updateLayout(CGSize(width: textWidth, height: 100.0))
        let subtitleSize = self.subtitleNode.updateLayout(CGSize(width: textWidth, height: 100.0))
        let textHeight = titleSize.height + 1.0 + subtitleSize.height
        let textY = floorToScreenPixels((panelHeight - textHeight) / 2.0)
        transition.updateFrame(node: self.titleNode, frame: CGRect(origin: CGPoint(x: textX, y: textY), size: titleSize))
        transition.updateFrame(node: self.subtitleNode, frame: CGRect(origin: CGPoint(x: textX, y: textY + titleSize.height + 1.0), size: subtitleSize))

        transition.updateFrame(node: self.button, frame: CGRect(origin: .zero, size: CGSize(width: width, height: panelHeight)))
        transition.updateFrame(node: self.separatorNode, frame: CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: width, height: UIScreenPixel)))

        self.activateAreaNode.frame = CGRect(origin: .zero, size: CGSize(width: width, height: panelHeight))
        self.activateAreaNode.accessibilityLabel = "\(title). \(subtitle)"

        return LayoutResult(backgroundHeight: panelHeight, insetHeight: panelHeight, hitTestSlop: 0.0)
    }

    @objc private func buttonPressed() {
        guard let navigationController = self.interfaceInteraction?.getNavigationController() else {
            return
        }
        let context = self.context
        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: self.peerId))
        |> deliverOnMainQueue).startStandalone(next: { [weak navigationController] peer in
            guard let peer, let navigationController else {
                return
            }
            let screen = GroupAdminElectionScreen(context: context, group: peer)
            navigationController.pushViewController(screen)
        })
    }

    @objc private func closePressed() {
        GroupAdminElectionService.shared(context: self.context).dismissResult(peerId: self.peerId)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if !self.closeButton.isHidden, let result = self.closeButton.hitTest(CGPoint(x: point.x - self.closeButton.frame.minX, y: point.y - self.closeButton.frame.minY), with: event) {
            return result
        }
        return super.hitTest(point, with: event)
    }
}
