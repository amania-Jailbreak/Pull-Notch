import Foundation
import Observation

@MainActor
@Observable
final class MenuBarBridgeController {
    private let scanner: AXMenuBarScanner
    private var refreshTask: Task<Void, Never>?

    private(set) var items: [MenuBarItemSnapshot] = []
    private(set) var permissionState: MenuBarBridgePermissionState = .needsAccessibilityPermission
    private(set) var lastErrorMessage: String?

    init(scanner: AXMenuBarScanner = AXMenuBarScanner()) {
        self.scanner = scanner
        refresh()
    }

    deinit {
        refreshTask?.cancel()
    }

    func startAutoRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func requestPermission() {
        scanner.requestAccessibilityPermissionPrompt()
        refresh()
    }

    func refresh() {
        permissionState = scanner.permissionState
        guard permissionState == .trusted else {
            items = []
            return
        }
        items = scanner.scan()
    }

    func activate(_ item: MenuBarItemSnapshot) {
        do {
            try scanner.press(item)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }
}
