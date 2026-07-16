import AppKit
import ApplicationServices
import OSLog

private let menuBarLog = Logger(subsystem: "jp.amania.Pull-Notch", category: "MenuBarManager")

struct MenuBarItemInfo: Identifiable, Hashable {
    let id: String
    let title: String
    let pid: pid_t

    static func == (lhs: MenuBarItemInfo, rhs: MenuBarItemInfo) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

@MainActor
final class MenuBarManager {
    static let shared = MenuBarManager()

    private(set) var isActive = false

    private struct SavedItem {
        let element: AXUIElement
        let info: MenuBarItemInfo
        let originalPosition: CGPoint
    }

    private var savedItems: [SavedItem] = []
    private var reapplyTimer: DispatchSourceTimer?
    private static let savedPositionsKey = "PullNotch.menuBar.savedPositions"

    private init() {}

    // MARK: - Public

    func activate() {
        guard !isActive else { return }

        guard checkAccessibilityPermission(prompt: true) else {
            menuBarLog.error("accessibility permission not granted")
            return
        }

        isActive = true
        hideStatusBarItems()
        startReapplyTimer()
        menuBarLog.info("menu bar management activated, \(self.savedItems.count) items hidden")
    }

    func deactivate() {
        guard isActive else { return }

        isActive = false
        stopReapplyTimer()
        restoreAllItems()
        if savedItems.isEmpty {
            clearSavedPositions()
        } else {
            persistSavedPositions()
        }
        menuBarLog.info("menu bar management deactivated, all items restored")
    }

    func toggle() {
        isActive ? deactivate() : activate()
    }

    func restoreOnLaunchIfNeeded() {
        guard let data = UserDefaults.standard.data(forKey: Self.savedPositionsKey) else { return }
        guard checkAccessibilityPermission(prompt: false) else {
            menuBarLog.warning("saved positions retained because accessibility permission is unavailable")
            return
        }

        do {
            let saved = try JSONDecoder().decode([SavedPositionEntry].self, from: data)
            menuBarLog.warning("found \(saved.count) saved positions from previous session — attempting restore")
            var unresolved: [SavedPositionEntry] = []

            for entry in saved {
                guard let pid = entry.pid else {
                    unresolved.append(entry)
                    continue
                }
                let appElement = AXUIElementCreateApplication(pid)
                var menuBarRef: CFTypeRef?
                let menuBarResult = AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarRef)
                guard menuBarResult == .success, let menuBarRef, CFGetTypeID(menuBarRef) == AXUIElementGetTypeID() else {
                    unresolved.append(entry)
                    continue
                }
                let menuBar = unsafeBitCast(menuBarRef, to: AXUIElement.self)

                var childrenRef: CFTypeRef?
                let childrenResult = AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &childrenRef)
                guard childrenResult == .success, let children = childrenRef as? [AXUIElement] else {
                    unresolved.append(entry)
                    continue
                }

                var didRestore = false
                for child in children {
                    let title = getTitle(of: child)
                    if title == entry.title {
                        didRestore = setPosition(of: child, to: entry.position)
                        break
                    }
                }
                if !didRestore {
                    unresolved.append(entry)
                }
            }

            if unresolved.isEmpty {
                clearSavedPositions()
            } else {
                persistSavedPositionEntries(unresolved)
                menuBarLog.warning("retained \(unresolved.count) positions that could not be restored")
            }
        } catch {
            menuBarLog.error("failed to decode saved positions: \(error.localizedDescription)")
        }
    }

    func hiddenItemsInfo() -> [MenuBarItemInfo] {
        savedItems.map(\.info)
    }

    // MARK: - Accessibility Permission

    func checkAccessibilityPermission(prompt: Bool) -> Bool {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt]
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Hide / Restore

    private func hideStatusBarItems() {
        let items = enumerateStatusBarItems()
        savedItems.removeAll()

        let hiddenX = hiddenPositionX

        for item in items {
            guard let position = getPosition(of: item.element) else { continue }
            let title = getTitle(of: item.element)
            let pid = getProcessID(of: item.element)

            let info = MenuBarItemInfo(
                id: "\(pid)_\(title)_\(Int(position.x))",
                title: title,
                pid: pid
            )

            let savedItem = SavedItem(
                element: item.element,
                info: info,
                originalPosition: position
            )

            if setPosition(of: item.element, to: CGPoint(x: hiddenX, y: position.y)) {
                savedItems.append(savedItem)
            }
        }

        persistSavedPositions()
    }

    private func restoreAllItems() {
        savedItems = savedItems.filter { !setPosition(of: $0.element, to: $0.originalPosition) }
    }

    // MARK: - Reapply Timer

    private func startReapplyTimer() {
        stopReapplyTimer()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            self?.reapplyHiddenPositions()
        }
        timer.resume()
        reapplyTimer = timer
    }

    private func stopReapplyTimer() {
        reapplyTimer?.cancel()
        reapplyTimer = nil
    }

    private func reapplyHiddenPositions() {
        guard isActive else { return }

        let hiddenX = hiddenPositionX

        var stillValid: [SavedItem] = []
        for saved in savedItems {
            guard let currentPos = getPosition(of: saved.element) else { continue }
            if abs(currentPos.x - hiddenX) > 50 {
                setPosition(of: saved.element, to: CGPoint(x: hiddenX, y: saved.originalPosition.y))
            }
            stillValid.append(saved)
        }
        savedItems = stillValid
    }

    // MARK: - Enumeration

    private struct EnumeratedItem {
        let element: AXUIElement
    }

    private func enumerateStatusBarItems() -> [EnumeratedItem] {
        var results: [EnumeratedItem] = []
        var seenPositions = Set<String>()

        // Collect candidate PIDs from multiple sources
        var candidatePIDs: [pid_t] = []

        // 1. System processes that manage status bar items
        for app in NSWorkspace.shared.runningApplications {
            let name = app.bundleIdentifier ?? ""
            let localName = app.localizedName ?? ""
            if name.contains("systemuiserver") ||
               name.contains("controlcenter") ||
               name == "com.apple.systemuiserver" ||
               name == "com.apple.controlcenter" ||
               localName == "SystemUIServer" ||
               localName == "Control Centre" ||
               localName == "ControlCenter" {
                candidatePIDs.append(app.processIdentifier)
            }
        }

        // 2. CGWindowList: find menu bar window owners
        candidatePIDs.append(contentsOf: findMenuBarOwningPIDs())

        // 3. Frontmost app (its menu bar includes all status items)
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            candidatePIDs.append(frontmost.processIdentifier)
        }

        // 4. All accessory apps (menu bar item apps)
        for app in NSWorkspace.shared.runningApplications {
            if app.activationPolicy == .accessory {
                candidatePIDs.append(app.processIdentifier)
            }
        }

        // Query each candidate
        var queriedPIDs = Set<pid_t>()
        for pid in candidatePIDs {
            guard pid != 0, queriedPIDs.insert(pid).inserted else { continue }

            // Try both kAXMenuBarAttribute and AXExtrasMenuBar
            for source in ["AXMenuBar", "AXExtrasMenuBar"] {
                guard let items = getMenuBarAttribute(pid: pid, attribute: source) else { continue }

                for item in items {
                    guard let position = getPosition(of: item), let screen = screen(containingX: position.x) else { continue }
                    let posKey = "\(Int(position.x))_\(Int(position.y))"

                    // Dedup by position and filter to right side
                    guard !seenPositions.contains(posKey) else { continue }
                    guard position.x > screen.frame.midX, position.x < screen.frame.maxX + 100 else { continue }

                    seenPositions.insert(posKey)
                    results.append(EnumeratedItem(element: item))
                }
            }
        }

        menuBarLog.info("enumerated \(results.count) status bar items from \(queriedPIDs.count) processes")
        return results
    }

    private func findMenuBarOwningPIDs() -> [pid_t] {
        var pids: [pid_t] = []

        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return pids
        }

        for window in windowList {
            guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let y = bounds["Y"] ?? 0
            let height = bounds["Height"] ?? 0
            let width = bounds["Width"] ?? 0

            // Menu bar is at the very top, full width or near full width
            guard y < 50, height <= 40, height > 0, width > 100 else { continue }

            if let ownerName = window[kCGWindowOwnerName as String] as? String {
                menuBarLog.debug("menu bar window: \(ownerName)")
            }

            if let pid = window[kCGWindowOwnerPID as String] as? Int {
                let pidVal = pid_t(pid)
                if !pids.contains(pidVal) {
                    pids.append(pidVal)
                }
            }
        }

        return pids
    }

    private func getMenuBarAttribute(pid: pid_t, attribute: String) -> [AXUIElement]? {
        let appElement = AXUIElementCreateApplication(pid)

        var menuBarRef: CFTypeRef?
        let r1 = AXUIElementCopyAttributeValue(appElement, attribute as CFString, &menuBarRef)
        guard r1 == .success, let menuBarRef, CFGetTypeID(menuBarRef) == AXUIElementGetTypeID() else { return nil }
        let menuBar = unsafeBitCast(menuBarRef, to: AXUIElement.self)

        var childrenRef: CFTypeRef?
        let r2 = AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &childrenRef)
        guard r2 == .success else { return nil }
        return childrenRef as? [AXUIElement]
    }

    private func getMenuBarChildren(pid: pid_t) -> [AXUIElement]? {
        getMenuBarAttribute(pid: pid, attribute: kAXMenuBarAttribute as String)
    }

    // MARK: - AX Value Helpers

    private func getPosition(of element: AXUIElement) -> CGPoint? {
        var positionRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef)
        guard result == .success, let value = positionRef, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint, AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    @discardableResult
    private func setPosition(of element: AXUIElement, to point: CGPoint) -> Bool {
        var mutablePoint = point
        guard let value = AXValueCreate(.cgPoint, &mutablePoint) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    private var hiddenPositionX: CGFloat {
        (NSScreen.screens.map { $0.frame.maxX }.max() ?? 1920) + 200
    }

    private func screen(containingX x: CGFloat) -> NSScreen? {
        NSScreen.screens.first { x >= $0.frame.minX - 1 && x <= $0.frame.maxX + 1 }
    }

    private func getTitle(of element: AXUIElement) -> String {
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)

        if let title = titleRef as? String, !title.isEmpty {
            return title
        }

        var descRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef)
        return descRef as? String ?? "unknown"
    }

    private func getProcessID(of element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    // MARK: - Persistence (crash safety)

    private struct SavedPositionEntry: Codable {
        let title: String
        let position: CGPoint
        let pid: pid_t?
    }

    private func persistSavedPositions() {
        let entries = savedItems.map { saved in
            SavedPositionEntry(
                title: saved.info.title,
                position: saved.originalPosition,
                pid: saved.info.pid
            )
        }

        persistSavedPositionEntries(entries)
    }

    private func persistSavedPositionEntries(_ entries: [SavedPositionEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.savedPositionsKey)
        }
    }

    private func clearSavedPositions() {
        UserDefaults.standard.removeObject(forKey: Self.savedPositionsKey)
    }
}
