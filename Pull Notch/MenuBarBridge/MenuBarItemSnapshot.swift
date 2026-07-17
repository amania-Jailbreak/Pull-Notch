import AppKit
import ApplicationServices
import Foundation

/// A lightweight, Pull Notch friendly representation of a menu bar extra.
///
/// The original AX element is intentionally kept inside the app process only.
/// We do not serialize or expose it to plugin APIs because AXUIElement references
/// are process-local handles and can become stale after SystemUIServer refreshes.
struct MenuBarItemSnapshot: Identifiable, Hashable {
    let id: String
    let title: String
    let frame: CGRect
    let ownerName: String?
    let ownerBundleIdentifier: String?
    let systemImageName: String
    let axElement: AXUIElement

    static func == (lhs: MenuBarItemSnapshot, rhs: MenuBarItemSnapshot) -> Bool {
        lhs.id == rhs.id && lhs.frame == rhs.frame && lhs.title == rhs.title
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(title)
        hasher.combine(frame.origin.x)
        hasher.combine(frame.origin.y)
        hasher.combine(frame.width)
        hasher.combine(frame.height)
    }
}

enum MenuBarBridgePermissionState: Equatable {
    case trusted
    case needsAccessibilityPermission
}

enum MenuBarBridgeError: LocalizedError {
    case pressFailed(AXError)

    var errorDescription: String? {
        switch self {
        case .pressFailed(let error):
            return "Failed to press menu bar item: \(error.rawValue)"
        }
    }
}
