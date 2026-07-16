import Foundation
import Observation
import PullNotchPluginKit

nonisolated enum PluginRuntimeState: String, Sendable {
    case loaded
    case disabled
    case failed
}

nonisolated struct PluginRuntimeInfo: Identifiable, Sendable {
    let id: String
    let displayName: String
    let version: String
    let capabilities: Set<PluginCapability>
    let state: PluginRuntimeState
    let errorMessage: String?
    let bundlePath: String
}

nonisolated struct PluginHostChange: OptionSet, Sendable {
    let rawValue: Int

    static let widgets = PluginHostChange(rawValue: 1 << 0)
    static let expandedPages = PluginHostChange(rawValue: 1 << 1)
    static let settings = PluginHostChange(rawValue: 1 << 2)
    static let runtimeInfos = PluginHostChange(rawValue: 1 << 3)
    static let dashboardWidgets = PluginHostChange(rawValue: 1 << 4)
    static let allContent: PluginHostChange = [.widgets, .expandedPages, .settings, .dashboardWidgets]
}

@MainActor
@Observable
final class PluginHostStore {
    @ObservationIgnored var onChange: (@MainActor (PluginHostChange) -> Void)?

    private(set) var widgets: [PluginWidgetDescriptor] = []
    private(set) var expandedPages: [PluginExpandedPageDescriptor] = []
    private(set) var dashboardWidgets: [PluginDashboardWidgetDescriptor] = []
    private(set) var runtimeInfos: [PluginRuntimeInfo] = []
    private(set) var settingsSections: [PluginSettingsSectionDescriptor] = []

    private(set) var nowPlayingSnapshot: PluginNowPlayingSnapshot?
    private(set) var weatherSnapshot = PluginWeatherSnapshot(
        temperatureText: nil,
        symbolName: nil,
        manualLocation: nil
    )
    private(set) var volumeSnapshot: PluginVolumeSnapshot? = PluginVolumeSnapshot(
        level: 0,
        outputDeviceName: nil
    )

    @ObservationIgnored private var eventHandlers: [UUID: EventHandlerRegistration] = [:]

    var availableWidgetIDs: [String] {
        widgets.sorted { $0.priority < $1.priority }.map(\.id)
    }

    func updateRuntimeInfos(_ infos: [PluginRuntimeInfo]) {
        runtimeInfos = infos
        onChange?(.runtimeInfos)
    }

    func registerWidget(_ descriptor: PluginWidgetDescriptor, pluginID: String) {
        let scoped = PluginWidgetDescriptor(
            id: scopedID(descriptor.id, pluginID: pluginID),
            title: descriptor.title,
            placement: descriptor.placement,
            priority: descriptor.priority,
            style: descriptor.style,
            preferredWidth: descriptor.preferredWidth,
            artworkData: descriptor.artworkData
        )
        widgets.removeAll { $0.id == scoped.id }
        widgets.append(scoped)
        onChange?(.widgets)
    }

    func unregisterWidget(id: String, pluginID: String) {
        let scopedID = scopedID(id, pluginID: pluginID)
        guard widgets.contains(where: { $0.id == scopedID }) else { return }
        widgets.removeAll { $0.id == scopedID }
        onChange?(.widgets)
    }

    func registerExpandedPage(_ descriptor: PluginExpandedPageDescriptor, pluginID: String) {
        let scoped = PluginExpandedPageDescriptor(
            id: scopedID(descriptor.id, pluginID: pluginID),
            title: descriptor.title,
            preferredWidth: descriptor.preferredWidth,
            render: descriptor.render
        )
        expandedPages.removeAll { $0.id == scoped.id }
        expandedPages.append(scoped)
        onChange?(.expandedPages)
    }

    func unregisterExpandedPage(id: String, pluginID: String) {
        let scopedID = scopedID(id, pluginID: pluginID)
        guard expandedPages.contains(where: { $0.id == scopedID }) else { return }
        expandedPages.removeAll { $0.id == scopedID }
        onChange?(.expandedPages)
    }

    func registerDashboardWidget(_ descriptor: PluginDashboardWidgetDescriptor, pluginID: String) {
        let scoped = PluginDashboardWidgetDescriptor(
            id: scopedID(descriptor.id, pluginID: pluginID),
            title: descriptor.title,
            symbolName: descriptor.symbolName,
            render: descriptor.render
        )
        dashboardWidgets.removeAll { $0.id == scoped.id }
        dashboardWidgets.append(scoped)
        onChange?(.dashboardWidgets)
    }

    func unregisterDashboardWidget(id: String, pluginID: String) {
        let scopedID = scopedID(id, pluginID: pluginID)
        guard dashboardWidgets.contains(where: { $0.id == scopedID }) else { return }
        dashboardWidgets.removeAll { $0.id == scopedID }
        onChange?(.dashboardWidgets)
    }

    func registerSettingsSection(_ descriptor: PluginSettingsSectionDescriptor, pluginID: String) {
        let scoped = PluginSettingsSectionDescriptor(
            id: scopedID(descriptor.id, pluginID: pluginID),
            title: descriptor.title,
            subtitle: descriptor.subtitle,
            render: descriptor.render
        )
        settingsSections.removeAll { $0.id == scoped.id }
        settingsSections.append(scoped)
        onChange?(.settings)
    }

    func unregisterSettingsSection(id: String, pluginID: String) {
        let scopedID = scopedID(id, pluginID: pluginID)
        guard settingsSections.contains(where: { $0.id == scopedID }) else { return }
        settingsSections.removeAll { $0.id == scopedID }
        onChange?(.settings)
    }

    func unregisterContent(for pluginID: String) {
        let prefix = "\(pluginID)::"
        let previousCounts = (widgets.count, expandedPages.count, settingsSections.count, dashboardWidgets.count)
        widgets.removeAll { $0.id.hasPrefix(prefix) }
        expandedPages.removeAll { $0.id.hasPrefix(prefix) }
        settingsSections.removeAll { $0.id.hasPrefix(prefix) }
        dashboardWidgets.removeAll { $0.id.hasPrefix(prefix) }
        eventHandlers = eventHandlers.filter { $0.value.pluginID != pluginID }

        var change: PluginHostChange = []
        if widgets.count != previousCounts.0 { change.insert(.widgets) }
        if expandedPages.count != previousCounts.1 { change.insert(.expandedPages) }
        if settingsSections.count != previousCounts.2 { change.insert(.settings) }
        if dashboardWidgets.count != previousCounts.3 { change.insert(.dashboardWidgets) }
        if !change.isEmpty { onChange?(change) }
    }

    func settingsSections(for pluginID: String) -> [PluginSettingsSectionDescriptor] {
        let prefix = "\(pluginID)::"
        return settingsSections.filter { $0.id.hasPrefix(prefix) }
    }

    func makeContext(
        for manifest: PluginManifest,
        showStatus: @escaping @MainActor (String, TimeInterval) -> Void
    ) -> PluginContext {
        PluginContext(
            manifest: manifest,
            registerWidgetHandler: { [weak self] in self?.registerWidget($0, pluginID: manifest.id) },
            unregisterWidgetHandler: { [weak self] in self?.unregisterWidget(id: $0, pluginID: manifest.id) },
            registerExpandedPageHandler: { [weak self] in self?.registerExpandedPage($0, pluginID: manifest.id) },
            unregisterExpandedPageHandler: { [weak self] in self?.unregisterExpandedPage(id: $0, pluginID: manifest.id) },
            registerDashboardWidgetHandler: { [weak self] in self?.registerDashboardWidget($0, pluginID: manifest.id) },
            unregisterDashboardWidgetHandler: { [weak self] in self?.unregisterDashboardWidget(id: $0, pluginID: manifest.id) },
            registerSettingsSectionHandler: { [weak self] in self?.registerSettingsSection($0, pluginID: manifest.id) },
            unregisterSettingsSectionHandler: { [weak self] in self?.unregisterSettingsSection(id: $0, pluginID: manifest.id) },
            showStatusHandler: showStatus,
            subscribeHandler: { [weak self] in self?.subscribe(pluginID: manifest.id, handler: $0) ?? UUID() },
            unsubscribeHandler: { [weak self] in self?.unsubscribe($0) },
            nowPlayingProvider: { [weak self] in self?.nowPlayingSnapshot },
            weatherProvider: { [weak self] in self?.weatherSnapshot ?? PluginWeatherSnapshot(temperatureText: nil, symbolName: nil, manualLocation: nil) },
            volumeProvider: { [weak self] in self?.volumeSnapshot }
        )
    }

    func updateNowPlayingSnapshot(_ snapshot: PluginNowPlayingSnapshot?) {
        nowPlayingSnapshot = snapshot
        broadcast(.nowPlaying(snapshot))
    }

    func updateWeatherSnapshot(_ snapshot: PluginWeatherSnapshot) {
        weatherSnapshot = snapshot
        broadcast(.weather(snapshot))
    }

    func updateVolumeSnapshot(_ snapshot: PluginVolumeSnapshot) {
        volumeSnapshot = snapshot
        broadcast(.volume(snapshot))
    }

    func synchronizeVolumeSnapshot(_ snapshot: PluginVolumeSnapshot) {
        volumeSnapshot = snapshot
    }

    private func scopedID(_ id: String, pluginID: String) -> String {
        "\(pluginID)::\(id)"
    }

    private func subscribe(
        pluginID: String,
        handler: @escaping @MainActor @Sendable (PluginHostEvent) -> Void
    ) -> UUID {
        let token = UUID()
        eventHandlers[token] = EventHandlerRegistration(pluginID: pluginID, handler: handler)
        handler(.nowPlaying(nowPlayingSnapshot))
        handler(.weather(weatherSnapshot))
        if let volumeSnapshot {
            handler(.volume(volumeSnapshot))
        }
        return token
    }

    private func unsubscribe(_ token: UUID) {
        eventHandlers[token] = nil
    }

    private func broadcast(_ event: PluginHostEvent) {
        let handlers = eventHandlers.values.map(\.handler)
        for handler in handlers {
            handler(event)
        }
    }
}

private extension PluginHostStore {
    struct EventHandlerRegistration {
        let pluginID: String
        let handler: @MainActor @Sendable (PluginHostEvent) -> Void
    }
}
