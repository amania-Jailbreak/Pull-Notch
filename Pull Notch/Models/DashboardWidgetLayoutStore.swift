import Foundation
import Observation

nonisolated enum DashboardWidgetSlot: String, CaseIterable, Identifiable, Sendable {
    case leading
    case trailing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leading: return "Left Pane"
        case .trailing: return "Right Pane"
        }
    }
}

nonisolated enum BuiltInDashboardWidgetKind: String, CaseIterable, Identifiable, Sendable {
    case todayAgenda
    case monthCalendar
    case nowPlayingArtwork
    case weather
    case pomodoro
    case pinnedFile
    case battery
    case todayTasks
    case systemStatus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .todayAgenda: return "Today's Schedule"
        case .monthCalendar: return "Calendar"
        case .nowPlayingArtwork: return "Cover Art"
        case .weather: return "Weather"
        case .pomodoro: return "Pomodoro"
        case .pinnedFile: return "Pinned File"
        case .battery: return "Battery"
        case .todayTasks: return "Today Tasks"
        case .systemStatus: return "System Status"
        }
    }

    var symbolName: String {
        switch self {
        case .todayAgenda: return "list.bullet.rectangle"
        case .monthCalendar: return "calendar"
        case .nowPlayingArtwork: return "music.note"
        case .weather: return "cloud.sun.fill"
        case .pomodoro: return "timer"
        case .pinnedFile: return "pin.fill"
        case .battery: return "battery.100percent"
        case .todayTasks: return "checklist"
        case .systemStatus: return "gauge.with.dots.needle.50percent"
        }
    }
}

nonisolated enum DashboardWidgetIdentity: Hashable, Sendable {
    case builtIn(BuiltInDashboardWidgetKind)
    case plugin(String)

    var storageToken: String {
        switch self {
        case .builtIn(let kind): return "builtin:\(kind.rawValue)"
        case .plugin(let id): return "plugin:\(id)"
        }
    }

    init?(storageToken: String) {
        if storageToken.hasPrefix("builtin:"),
           let kind = BuiltInDashboardWidgetKind(rawValue: String(storageToken.dropFirst("builtin:".count))) {
            self = .builtIn(kind)
        } else if storageToken.hasPrefix("plugin:") {
            let id = String(storageToken.dropFirst("plugin:".count))
            guard !id.isEmpty else { return nil }
            self = .plugin(id)
        } else {
            return nil
        }
    }
}

nonisolated struct DashboardWidgetLayout: Equatable, Sendable {
    var leading: DashboardWidgetIdentity
    var trailing: DashboardWidgetIdentity

    subscript(slot: DashboardWidgetSlot) -> DashboardWidgetIdentity {
        get { slot == .leading ? leading : trailing }
        set {
            switch slot {
            case .leading: leading = newValue
            case .trailing: trailing = newValue
            }
        }
    }
}

@MainActor
@Observable
final class DashboardWidgetLayoutStore {
    private(set) var layout: DashboardWidgetLayout

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storagePrefix: String

    init(
        defaults: UserDefaults = .standard,
        storagePrefix: String = "PullNotch.dashboardWidgetLayout."
    ) {
        self.defaults = defaults
        self.storagePrefix = storagePrefix
        layout = Self.load(defaults: defaults, storagePrefix: storagePrefix)
    }

    func select(_ identity: DashboardWidgetIdentity, for slot: DashboardWidgetSlot) {
        guard layout[slot] != identity else { return }
        layout[slot] = identity
        defaults.set(identity.storageToken, forKey: storagePrefix + slot.rawValue)
    }

    private static func load(defaults: UserDefaults, storagePrefix: String) -> DashboardWidgetLayout {
        let leading = defaults.string(forKey: storagePrefix + DashboardWidgetSlot.leading.rawValue)
            .flatMap(DashboardWidgetIdentity.init(storageToken:))
            ?? .builtIn(.monthCalendar)
        let trailing = defaults.string(forKey: storagePrefix + DashboardWidgetSlot.trailing.rawValue)
            .flatMap(DashboardWidgetIdentity.init(storageToken:))
            ?? .builtIn(.weather)
        return DashboardWidgetLayout(leading: leading, trailing: trailing)
    }
}
