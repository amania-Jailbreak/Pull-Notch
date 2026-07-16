import AppKit
import Foundation
import PullNotchPluginKit
import UniformTypeIdentifiers

struct CompactWidgetFactoryState {
    struct PinnedFile {
        let isEnabled: Bool
        let selectedURL: URL?
        let selectedDisplayName: String?
        let count: Int
    }

    struct NowPlaying {
        let isEnabled: Bool
        let isAvailable: Bool
        let showsArtwork: Bool
        let artworkData: Data?
        let showsVisualizer: Bool
        let animatesVisualizer: Bool
        let isPlaying: Bool
    }

    struct Battery {
        let isEnabled: Bool
        let level: Int?
        let symbolName: String?
        let chargingPowerText: String?
    }

    struct Weather {
        let isEnabled: Bool
        let temperatureText: String?
        let symbolName: String?
    }

    struct Pomodoro {
        let isEnabled: Bool
        let symbolName: String
        let progress: CGFloat
        let isRunning: Bool
        let remainingSeconds: Int
        let timeText: String
    }

    struct Reminders {
        let isEnabled: Bool
        let isAuthorized: Bool
        let remainingCount: Int
        let overdueCount: Int
    }

    struct SystemStatus {
        let isEnabled: Bool
        let cpuUsage: Double?
    }

    let pinnedFile: PinnedFile
    let nowPlaying: NowPlaying
    let battery: Battery
    let weather: Weather
    let pomodoro: Pomodoro
    let reminders: Reminders
    let systemStatus: SystemStatus
}

@MainActor
struct CompactWidgetFactory {
    func firstAvailableWidget(
        identities: [CompactWidgetIdentity],
        placement: CompactWidgetPlacement,
        state: CompactWidgetFactoryState,
        pluginWidgets: [PluginWidgetDescriptor]
    ) -> CompactIslandWidget? {
        identities.lazy.compactMap {
            widget(
                for: $0,
                placement: placement,
                state: state,
                pluginWidgets: pluginWidgets
            )
        }.first
    }

    func widget(
        for identity: CompactWidgetIdentity,
        placement: CompactWidgetPlacement,
        state: CompactWidgetFactoryState,
        pluginWidgets: [PluginWidgetDescriptor]
    ) -> CompactIslandWidget? {
        switch identity {
        case .builtIn(let kind):
            return builtInWidget(kind, placement: placement, state: state)
        case .plugin(let id):
            guard let descriptor = pluginWidgets.first(where: { $0.id == id }) else { return nil }
            return pluginWidget(from: descriptor, placement: placement)
        }
    }

    func title(
        for identity: CompactWidgetIdentity,
        pluginWidgets: [PluginWidgetDescriptor]
    ) -> String? {
        switch identity {
        case .builtIn(let kind):
            return kind.title
        case .plugin(let id):
            return pluginWidgets.first(where: { $0.id == id })?.title
        }
    }

    func chargingPowerWidget(state: CompactWidgetFactoryState) -> CompactIslandWidget? {
        guard
            state.battery.isEnabled,
            let text = state.battery.chargingPowerText
        else {
            return nil
        }

        return makeBuiltInWidget(
            id: "charging-power-widget",
            kind: .chargingPower,
            placement: .trailing,
            style: .labeledSymbol(systemName: "bolt.fill", text: text)
        )
    }

    func urgentPomodoroWidget(state: CompactWidgetFactoryState) -> CompactIslandWidget? {
        let pomodoro = state.pomodoro
        guard pomodoro.isEnabled, pomodoro.isRunning, pomodoro.remainingSeconds <= 5 else { return nil }

        return makeBuiltInWidget(
            id: "urgent-pomodoro-widget",
            kind: .pomodoro,
            placement: .trailing,
            style: .circularProgress(
                systemName: "exclamationmark",
                progress: pomodoro.progress,
                isActive: true,
                text: pomodoro.timeText
            )
        )
    }

    private func builtInWidget(
        _ kind: CompactWidgetKind,
        placement: CompactWidgetPlacement,
        state: CompactWidgetFactoryState
    ) -> CompactIslandWidget? {
        let source: CompactIslandWidget?

        switch kind {
        case .pinnedFile:
            source = pinnedFileWidget(state: state)
        case .nowPlayingArtwork:
            source = nowPlayingArtworkWidget(state: state)
        case .battery:
            source = batteryWidget(state: state)
        case .nowPlayingVisualizer:
            source = nowPlayingVisualizerWidget(state: state)
        case .weather:
            source = weatherWidget(state: state)
        case .pomodoro:
            source = pomodoroWidget(state: state)
        case .chargingPower:
            source = chargingPowerWidget(state: state)
        case .todayTasks:
            source = todayTasksWidget(state: state)
        case .systemStatus:
            source = systemStatusWidget(state: state)
        }

        guard let source else { return nil }
        return CompactIslandWidget(
            id: "\(source.id)-\(placement.storageKey)",
            identity: source.identity,
            title: source.title,
            placement: placement,
            style: source.style,
            preferredWidth: source.preferredWidth,
            artworkData: source.artworkData
        )
    }

    private func pinnedFileWidget(state: CompactWidgetFactoryState) -> CompactIslandWidget? {
        guard state.pinnedFile.isEnabled,
              state.pinnedFile.count > 0
        else {
            return nil
        }
        let url = state.pinnedFile.selectedURL
            ?? URL(fileURLWithPath: state.pinnedFile.selectedDisplayName ?? "Pinned File")
        let fullName = state.pinnedFile.selectedDisplayName
            ?? url.lastPathComponent
        let extensionSuffix = ".\(url.pathExtension)"
        let nameWithoutExtension = !url.pathExtension.isEmpty
            && fullName.lowercased().hasSuffix(extensionSuffix.lowercased())
            ? String(fullName.dropLast(extensionSuffix.count))
            : fullName
        let baseName = nameWithoutExtension.count > 18
            ? String(nameWithoutExtension.prefix(17)) + "…"
            : nameWithoutExtension
        let style = CompactWidgetStyle.labeledSymbol(
            systemName: fileSymbolName(for: url.pathExtension),
            text: "\(baseName) · \(state.pinnedFile.count)"
        )
        return makeBuiltInWidget(
            id: "pinned-file-widget",
            kind: .pinnedFile,
            placement: .leading,
            style: style
        )
    }

    private func nowPlayingArtworkWidget(state: CompactWidgetFactoryState) -> CompactIslandWidget? {
        let nowPlaying = state.nowPlaying
        guard nowPlaying.isEnabled, nowPlaying.isAvailable, nowPlaying.showsArtwork else { return nil }
        return makeBuiltInWidget(
            id: "now-playing-artwork",
            kind: .nowPlayingArtwork,
            placement: .leading,
            style: .artwork,
            artworkData: nowPlaying.artworkData
        )
    }

    private func batteryWidget(state: CompactWidgetFactoryState) -> CompactIslandWidget? {
        guard
            state.battery.isEnabled,
            let level = state.battery.level,
            let symbolName = state.battery.symbolName
        else {
            return nil
        }

        return makeBuiltInWidget(
            id: "battery-widget",
            kind: .battery,
            placement: .leading,
            style: .labeledSymbol(systemName: symbolName, text: "\(level)%")
        )
    }

    private func nowPlayingVisualizerWidget(state: CompactWidgetFactoryState) -> CompactIslandWidget? {
        let nowPlaying = state.nowPlaying
        guard nowPlaying.isEnabled, nowPlaying.isAvailable, nowPlaying.showsVisualizer else { return nil }
        let style: CompactWidgetStyle = nowPlaying.animatesVisualizer
            ? .visualizer(isActive: nowPlaying.isPlaying)
            : .symbol("music.note")
        return makeBuiltInWidget(
            id: "now-playing-visualizer",
            kind: .nowPlayingVisualizer,
            placement: .trailing,
            style: style
        )
    }

    private func weatherWidget(state: CompactWidgetFactoryState) -> CompactIslandWidget? {
        guard
            state.weather.isEnabled,
            let temperatureText = state.weather.temperatureText,
            let symbolName = state.weather.symbolName
        else {
            return nil
        }

        return makeBuiltInWidget(
            id: "weather-widget",
            kind: .weather,
            placement: .trailing,
            style: .labeledSymbol(systemName: symbolName, text: temperatureText)
        )
    }

    private func pomodoroWidget(state: CompactWidgetFactoryState) -> CompactIslandWidget? {
        let pomodoro = state.pomodoro
        guard pomodoro.isEnabled else { return nil }
        return makeBuiltInWidget(
            id: "pomodoro-widget",
            kind: .pomodoro,
            placement: .trailing,
            style: .circularProgress(
                systemName: pomodoro.symbolName,
                progress: pomodoro.progress,
                isActive: pomodoro.isRunning,
                text: pomodoro.timeText
            )
        )
    }

    private func todayTasksWidget(state: CompactWidgetFactoryState) -> CompactIslandWidget? {
        let reminders = state.reminders
        guard reminders.isEnabled, reminders.isAuthorized else { return nil }
        let count = reminders.overdueCount > 0 ? reminders.overdueCount : reminders.remainingCount
        let symbol = reminders.overdueCount > 0 ? "exclamationmark.circle.fill" : "checklist"
        let text = reminders.overdueCount > 0 ? "\(count) overdue" : "\(count) today"
        return makeBuiltInWidget(
            id: "today-tasks-widget",
            kind: .todayTasks,
            placement: .leading,
            style: .labeledSymbol(systemName: symbol, text: text)
        )
    }

    private func systemStatusWidget(state: CompactWidgetFactoryState) -> CompactIslandWidget? {
        guard state.systemStatus.isEnabled, let cpuUsage = state.systemStatus.cpuUsage else { return nil }
        let percent = Int((cpuUsage * 100).rounded())
        return makeBuiltInWidget(
            id: "system-status-widget",
            kind: .systemStatus,
            placement: .trailing,
            style: .circularProgress(
                systemName: "cpu",
                progress: CGFloat(cpuUsage),
                isActive: cpuUsage >= 0.85,
                text: "\(percent)%"
            )
        )
    }

    private func pluginWidget(
        from descriptor: PluginWidgetDescriptor,
        placement: CompactWidgetPlacement
    ) -> CompactIslandWidget {
        let style: CompactWidgetStyle
        switch descriptor.style {
        case .artwork:
            style = .artwork
        case .visualizer(let isActive):
            style = .visualizer(isActive: isActive)
        case .symbol(let systemName):
            style = .symbol(systemName)
        case .labeledSymbol(let systemName, let text):
            style = .labeledSymbol(systemName: systemName, text: text)
        case .circularProgress(let systemName, let progress, let isActive, let text):
            style = .circularProgress(
                systemName: systemName,
                progress: progress,
                isActive: isActive,
                text: text
            )
        case .custom(let render):
            style = .custom(render: render)
        }

        return CompactIslandWidget(
            id: "plugin-widget-\(descriptor.id)-\(placement.storageKey)",
            identity: .plugin(descriptor.id),
            title: descriptor.title,
            placement: placement,
            style: style,
            preferredWidth: descriptor.preferredWidth,
            artworkData: descriptor.artworkData
        )
    }

    private func makeBuiltInWidget(
        id: String,
        kind: CompactWidgetKind,
        placement: CompactWidgetPlacement,
        style: CompactWidgetStyle,
        artworkData: Data? = nil
    ) -> CompactIslandWidget {
        CompactIslandWidget(
            id: id,
            identity: .builtIn(kind),
            title: kind.title,
            placement: placement,
            style: style,
            preferredWidth: preferredWidth(for: style),
            artworkData: artworkData
        )
    }

    private func preferredWidth(for style: CompactWidgetStyle) -> CGFloat {
        switch style {
        case .artwork, .symbol, .custom:
            return 24
        case .visualizer:
            return 26
        case .labeledSymbol(let systemName, let text):
            let textWidth = NSString(string: text).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold)
            ]).width
            let iconWidth: CGFloat = systemName.isEmpty ? 0 : 12
            return ceil(textWidth) + iconWidth + 16
        case .circularProgress(_, _, _, let text):
            let textWidth = NSString(string: text).size(withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            ]).width
            return ceil(textWidth) + 42
        }
    }

    private func fileSymbolName(for pathExtension: String) -> String {
        guard let type = UTType(filenameExtension: pathExtension) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "archivebox" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}
