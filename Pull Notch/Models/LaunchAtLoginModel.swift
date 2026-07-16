import Foundation
import ServiceManagement

enum LaunchAtLoginServiceStatus: Equatable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
    case unknown
}

@MainActor
protocol LaunchAtLoginServicing {
    var status: LaunchAtLoginServiceStatus { get }
    func register() throws
    func unregister() throws
}

@MainActor
struct SystemLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginServiceStatus {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered:
            return .notRegistered
        case .notFound:
            return .notFound
        @unknown default:
            return .unknown
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

@MainActor
final class LaunchAtLoginModel {
    private(set) var isEnabled = false
    private(set) var statusText = "ログイン時には起動しません。"

    private let service: any LaunchAtLoginServicing
    private let isSupported: Bool

    init(
        service: (any LaunchAtLoginServicing)? = nil,
        isSupported: Bool = {
            if #available(macOS 13.0, *) {
                return true
            }
            return false
        }()
    ) {
        self.service = service ?? SystemLaunchAtLoginService()
        self.isSupported = isSupported
    }

    func refresh() {
        guard isSupported else {
            isEnabled = false
            statusText = "この macOS では自動起動設定を変更できません。"
            return
        }
        apply(service.status)
    }

    func setEnabled(_ shouldEnable: Bool) {
        guard isSupported else {
            refresh()
            return
        }

        do {
            if shouldEnable {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            // Keep the operation error visible while still reflecting the
            // authoritative service state in the toggle.
            isEnabled = service.status == .enabled
            statusText = error.localizedDescription
            return
        }

        apply(service.status)
    }

    private func apply(_ status: LaunchAtLoginServiceStatus) {
        switch status {
        case .enabled:
            isEnabled = true
            statusText = "ログイン時に Pull Notch を自動で起動します。"
        case .requiresApproval:
            isEnabled = false
            statusText = "システム設定のログイン項目で許可が必要です。"
        case .notRegistered:
            isEnabled = false
            statusText = "ログイン時には起動しません。"
        case .notFound:
            isEnabled = false
            statusText = "配布ビルドで利用できる自動起動サービスが見つかりません。"
        case .unknown:
            isEnabled = false
            statusText = "自動起動の状態を判定できませんでした。"
        }
    }
}
