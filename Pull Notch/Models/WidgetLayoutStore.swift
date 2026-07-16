import Foundation
import Observation

nonisolated enum CompactWidgetPlacement: Equatable, Hashable, Sendable {
    case leading
    case trailing

    var storageKey: String {
        switch self {
        case .leading: return "leading"
        case .trailing: return "trailing"
        }
    }
}

nonisolated enum CompactWidgetZone: String, CaseIterable, Identifiable, Sendable {
    case leading
    case trailing
    case hidden

    var id: String { rawValue }
    var storageKey: String { rawValue }

    var title: String {
        switch self {
        case .leading: return "Left Slot"
        case .trailing: return "Right Slot"
        case .hidden: return "Hidden"
        }
    }
}

nonisolated enum MoveDirection: Sendable {
    case up
    case down
}

nonisolated enum CompactWidgetKind: String, CaseIterable, Identifiable, Sendable {
    case pinnedFile
    case nowPlayingArtwork
    case battery
    case nowPlayingVisualizer
    case weather
    case pomodoro
    case chargingPower
    case todayTasks
    case systemStatus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pinnedFile: return "Pinned File"
        case .nowPlayingArtwork: return "Now Playing Artwork"
        case .battery: return "Battery"
        case .nowPlayingVisualizer: return "Now Playing Visualizer"
        case .weather: return "Weather"
        case .pomodoro: return "Pomodoro"
        case .chargingPower: return "Charging Power"
        case .todayTasks: return "Today Tasks"
        case .systemStatus: return "System Status"
        }
    }

    var placement: CompactWidgetPlacement {
        switch self {
        case .pinnedFile, .nowPlayingArtwork, .battery, .todayTasks:
            return .leading
        case .nowPlayingVisualizer, .weather, .pomodoro, .chargingPower, .systemStatus:
            return .trailing
        }
    }
}

nonisolated enum CompactWidgetIdentity: Hashable, Sendable {
    case builtIn(CompactWidgetKind)
    case plugin(String)

    var storageToken: String {
        switch self {
        case .builtIn(let kind): return "builtin:\(kind.rawValue)"
        case .plugin(let id): return "plugin:\(id)"
        }
    }

    init?(storageToken: String) {
        if storageToken.hasPrefix("builtin:"),
           let kind = CompactWidgetKind(rawValue: String(storageToken.dropFirst("builtin:".count))) {
            self = .builtIn(kind)
        } else if storageToken.hasPrefix("plugin:") {
            self = .plugin(String(storageToken.dropFirst("plugin:".count)))
        } else {
            return nil
        }
    }
}

nonisolated struct CompactWidgetLayout: Equatable, Sendable {
    var leading: [CompactWidgetIdentity]
    var trailing: [CompactWidgetIdentity]
    var hidden: [CompactWidgetIdentity]

    subscript(zone: CompactWidgetZone) -> [CompactWidgetIdentity] {
        get {
            switch zone {
            case .leading: return leading
            case .trailing: return trailing
            case .hidden: return hidden
            }
        }
        set {
            switch zone {
            case .leading: leading = newValue
            case .trailing: trailing = newValue
            case .hidden: hidden = newValue
            }
        }
    }
}

nonisolated struct CompactWidgetLayoutItem: Identifiable, Sendable {
    let id: String
    let identity: CompactWidgetIdentity
    let title: String
    let zone: CompactWidgetZone
}

@MainActor
@Observable
final class WidgetLayoutStore {
    private(set) var layout: CompactWidgetLayout

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storagePrefix: String

    init(
        defaults: UserDefaults = .standard,
        storagePrefix: String = "PullNotch.compactWidgetLayout."
    ) {
        self.defaults = defaults
        self.storagePrefix = storagePrefix
        let loaded = Self.load(defaults: defaults, storagePrefix: storagePrefix)
        let normalized = Self.normalized(loaded, availablePluginIDs: [])
        layout = normalized
        if normalized != loaded {
            Self.save(normalized, defaults: defaults, storagePrefix: storagePrefix)
        }
    }

    func synchronize(availablePluginIDs: [String]) {
        let normalized = Self.normalized(layout, availablePluginIDs: availablePluginIDs)
        guard normalized != layout else { return }
        layout = normalized
        save()
    }

    func canMove(_ identity: CompactWidgetIdentity, in zone: CompactWidgetZone, direction: MoveDirection) -> Bool {
        guard let index = layout[zone].firstIndex(of: identity) else { return false }
        switch direction {
        case .up: return index > 0
        case .down: return index < layout[zone].count - 1
        }
    }

    @discardableResult
    func move(_ identity: CompactWidgetIdentity, in zone: CompactWidgetZone, direction: MoveDirection) -> Bool {
        var updated = layout
        var identities = updated[zone]
        guard let index = identities.firstIndex(of: identity) else { return false }

        let targetIndex: Int
        switch direction {
        case .up:
            guard index > 0 else { return false }
            targetIndex = index - 1
        case .down:
            guard index < identities.count - 1 else { return false }
            targetIndex = index + 1
        }

        identities.swapAt(index, targetIndex)
        updated[zone] = identities
        commit(updated)
        return true
    }

    @discardableResult
    func move(_ identity: CompactWidgetIdentity, to targetZone: CompactWidgetZone) -> Bool {
        var updated = layout
        for zone in CompactWidgetZone.allCases {
            updated[zone].removeAll { $0 == identity }
        }
        updated[targetZone].append(identity)
        guard updated != layout else { return false }
        commit(updated)
        return true
    }

    private func commit(_ updated: CompactWidgetLayout) {
        layout = Self.normalized(updated, availablePluginIDs: [])
        save()
    }

    private func save() {
        Self.save(layout, defaults: defaults, storagePrefix: storagePrefix)
    }

    private static func save(
        _ layout: CompactWidgetLayout,
        defaults: UserDefaults,
        storagePrefix: String
    ) {
        for zone in CompactWidgetZone.allCases {
            defaults.set(layout[zone].map(\.storageToken), forKey: storagePrefix + zone.storageKey)
        }
    }

    private static func load(defaults: UserDefaults, storagePrefix: String) -> CompactWidgetLayout {
        let hasSavedLayout = CompactWidgetZone.allCases.contains {
            defaults.object(forKey: storagePrefix + $0.storageKey) != nil
        }
        guard hasSavedLayout else { return defaultLayout() }

        var layout = CompactWidgetLayout(leading: [], trailing: [], hidden: [])
        for zone in CompactWidgetZone.allCases {
            let tokens = defaults.stringArray(forKey: storagePrefix + zone.storageKey) ?? []
            layout[zone] = tokens.compactMap(CompactWidgetIdentity.init(storageToken:))
        }
        return layout
    }

    private static func normalized(
        _ layout: CompactWidgetLayout,
        availablePluginIDs: [String]
    ) -> CompactWidgetLayout {
        var normalized = CompactWidgetLayout(leading: [], trailing: [], hidden: [])
        var seen: Set<CompactWidgetIdentity> = []

        for zone in CompactWidgetZone.allCases {
            for identity in layout[zone] where seen.insert(identity).inserted {
                normalized[zone].append(identity)
            }
        }

        for kind in CompactWidgetKind.allCases {
            let identity = CompactWidgetIdentity.builtIn(kind)
            guard seen.insert(identity).inserted else { continue }
            normalized[defaultZone(for: kind)].append(identity)
        }

        for id in availablePluginIDs {
            let identity = CompactWidgetIdentity.plugin(id)
            guard seen.insert(identity).inserted else { continue }
            normalized.hidden.append(identity)
        }

        return normalized
    }

    private static func defaultLayout() -> CompactWidgetLayout {
        CompactWidgetLayout(
            leading: CompactWidgetKind.allCases
                .filter { defaultZone(for: $0) == .leading }
                .map(CompactWidgetIdentity.builtIn),
            trailing: CompactWidgetKind.allCases
                .filter { defaultZone(for: $0) == .trailing }
                .map(CompactWidgetIdentity.builtIn),
            hidden: []
        )
    }

    private static func defaultZone(for kind: CompactWidgetKind) -> CompactWidgetZone {
        if kind == .todayTasks || kind == .systemStatus {
            return .hidden
        }
        switch kind.placement {
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }
}
