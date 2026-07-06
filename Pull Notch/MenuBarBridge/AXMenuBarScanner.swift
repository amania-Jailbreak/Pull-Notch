import AppKit
import ApplicationServices
import Foundation

/// Scans visible menu bar extras using the Accessibility tree.
///
/// This is the first bridge layer for an Ice/Bartender style integration:
/// Pull Notch renders snapshots inside the notch and forwards clicks back to
/// the original AX elements instead of trying to re-parent private NSStatusItems.
final class AXMenuBarScanner {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    var permissionState: MenuBarBridgePermissionState {
        AXIsProcessTrusted() ? .trusted : .needsAccessibilityPermission
    }

    func requestAccessibilityPermissionPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func scan() -> [MenuBarItemSnapshot] {
        guard permissionState == .trusted else { return [] }

        let candidates = workspace.runningApplications
            .filter { application in
                application.activationPolicy == .accessory
                    || application.bundleIdentifier == "com.apple.systemuiserver"
                    || application.localizedName == "SystemUIServer"
            }

        return candidates.flatMap(scanMenuBarItems(for:))
            .filter { !$0.title.isEmpty || !$0.frame.isEmpty }
            .sorted { lhs, rhs in
                if abs(lhs.frame.midY - rhs.frame.midY) > 1 {
                    return lhs.frame.midY > rhs.frame.midY
                }
                return lhs.frame.minX < rhs.frame.minX
            }
    }

    func press(_ item: MenuBarItemSnapshot) throws {
        let error = AXUIElementPerformAction(item.axElement, kAXPressAction as CFString)
        guard error == .success else {
            throw MenuBarBridgeError.pressFailed(error)
        }
    }

    private func scanMenuBarItems(for application: NSRunningApplication) -> [MenuBarItemSnapshot] {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        let menuBars = children(for: appElement, attribute: kAXMenuBarAttribute)
            + children(for: appElement, attribute: kAXExtrasMenuBarAttribute)

        return menuBars.flatMap { menuBar in
            descendants(from: menuBar)
                .compactMap { element in
                    snapshot(from: element, owner: application)
                }
        }
    }

    private func snapshot(from element: AXUIElement, owner: NSRunningApplication) -> MenuBarItemSnapshot? {
        let role = stringAttribute(kAXRoleAttribute, from: element)
        let subrole = stringAttribute(kAXSubroleAttribute, from: element)

        guard role == kAXMenuBarItemRole as String || subrole?.contains("MenuExtra") == true else {
            return nil
        }

        let frame = frameAttribute(from: element)
        let title = [
            stringAttribute(kAXTitleAttribute, from: element),
            stringAttribute(kAXDescriptionAttribute, from: element),
            stringAttribute(kAXHelpAttribute, from: element),
            owner.localizedName
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty }) ?? "Menu Item"

        let idParts = [
            owner.bundleIdentifier ?? owner.localizedName ?? "unknown",
            title,
            String(format: "%.0f", frame.minX),
            String(format: "%.0f", frame.minY),
            String(format: "%.0f", frame.width),
            String(format: "%.0f", frame.height)
        ]

        return MenuBarItemSnapshot(
            id: idParts.joined(separator: ":"),
            title: title,
            frame: frame,
            ownerName: owner.localizedName,
            ownerBundleIdentifier: owner.bundleIdentifier,
            systemImageName: systemImageName(for: title, owner: owner),
            axElement: element
        )
    }

    private func descendants(from element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth < 5 else { return [] }

        let directChildren = children(for: element, attribute: kAXChildrenAttribute)
        return directChildren + directChildren.flatMap { descendants(from: $0, depth: depth + 1) }
    }

    private func children(for element: AXUIElement, attribute: String) -> [AXUIElement] {
        var rawValue: AnyObject?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard error == .success else { return [] }

        if let element = rawValue as! AXUIElement? {
            return [element]
        }
        return rawValue as? [AXUIElement] ?? []
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var rawValue: AnyObject?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard error == .success else { return nil }
        return rawValue as? String
    }

    private func frameAttribute(from element: AXUIElement) -> CGRect {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?

        let positionError = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
        let sizeError = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)

        guard
            positionError == .success,
            sizeError == .success,
            let position = positionValue as? AXValue,
            let size = sizeValue as? AXValue
        else {
            return .zero
        }

        var point = CGPoint.zero
        var cgSize = CGSize.zero
        AXValueGetValue(position, .cgPoint, &point)
        AXValueGetValue(size, .cgSize, &cgSize)
        return CGRect(origin: point, size: cgSize)
    }

    private func systemImageName(for title: String, owner: NSRunningApplication) -> String {
        let normalized = [title, owner.localizedName, owner.bundleIdentifier]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        if normalized.contains("battery") { return "battery.75" }
        if normalized.contains("wi-fi") || normalized.contains("wifi") { return "wifi" }
        if normalized.contains("bluetooth") { return "bolt.horizontal.circle" }
        if normalized.contains("clock") || normalized.contains("time") { return "clock" }
        if normalized.contains("control") { return "switch.2" }
        if normalized.contains("sound") || normalized.contains("volume") { return "speaker.wave.2.fill" }
        if normalized.contains("vpn") { return "lock.shield" }
        return "circle.grid.2x2.fill"
    }
}
