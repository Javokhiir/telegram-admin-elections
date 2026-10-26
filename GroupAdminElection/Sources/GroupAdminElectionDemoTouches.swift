import Foundation
import UIKit
import ObjectiveC

/// Draws a ring where the screen is touched, so a screen recording of the demo shows every tap.
/// Only with `GroupAdminElectionDemo` on.
public enum GroupAdminElectionDemoTouches {
    private static var isInstalled = false

    public static func installIfEnabled() {
        guard GroupAdminElectionDemo.isEnabled, !self.isInstalled else {
            return
        }
        self.isInstalled = true
        guard let original = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.sendEvent(_:))), let replacement = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.groupAdminElectionDemo_sendEvent(_:))) else {
            return
        }
        method_exchangeImplementations(original, replacement)
    }

    private static var rings: [ObjectIdentifier: UIView] = [:]

    fileprivate static func handle(_ event: UIEvent, in window: UIWindow) {
        guard event.type == .touches, let touches = event.allTouches else {
            return
        }
        for touch in touches where touch.window === window {
            let key = ObjectIdentifier(touch)
            let location = touch.location(in: window)
            switch touch.phase {
            case .began:
                let ring = UIView(frame: CGRect(x: 0.0, y: 0.0, width: 46.0, height: 46.0))
                ring.isUserInteractionEnabled = false
                ring.layer.cornerRadius = 23.0
                ring.layer.borderWidth = 3.0
                ring.layer.borderColor = UIColor.white.cgColor
                ring.backgroundColor = UIColor.white.withAlphaComponent(0.25)
                ring.layer.shadowColor = UIColor.black.cgColor
                ring.layer.shadowOpacity = 0.25
                ring.layer.shadowRadius = 6.0
                ring.layer.shadowOffset = .zero
                ring.center = location
                ring.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
                ring.alpha = 0.0
                window.addSubview(ring)
                UIView.animate(withDuration: 0.15) {
                    ring.transform = .identity
                    ring.alpha = 1.0
                }
                self.rings[key] = ring
            case .moved, .stationary:
                if let ring = self.rings[key] {
                    ring.center = location
                    window.bringSubviewToFront(ring)
                }
            case .ended, .cancelled:
                if let ring = self.rings.removeValue(forKey: key) {
                    ring.center = location
                    UIView.animate(withDuration: 0.3, animations: {
                        ring.transform = CGAffineTransform(scaleX: 1.35, y: 1.35)
                        ring.alpha = 0.0
                    }, completion: { _ in
                        ring.removeFromSuperview()
                    })
                }
            default:
                break
            }
        }
    }
}

extension UIWindow {
    // Swapped with sendEvent(_:) by GroupAdminElectionDemoTouches, so this calls the original.
    @objc fileprivate func groupAdminElectionDemo_sendEvent(_ event: UIEvent) {
        self.groupAdminElectionDemo_sendEvent(event)
        GroupAdminElectionDemoTouches.handle(event, in: self)
    }
}
