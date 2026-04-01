import CoreGraphics
import Foundation
import SwiftUI

public enum PluginCapability: String, CaseIterable, Sendable {
    case widget
    case expandedPage
    case settings
}

public struct PluginManifest: Sendable {
    public let id: String
    public let displayName: String
    public let version: String
    public let capabilities: Set<PluginCapability>

    public init(id: String, displayName: String, version: String, capabilities: Set<PluginCapability>) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.capabilities = capabilities
    }
}

public enum PluginWidgetPlacement: String, Sendable {
    case leading
    case trailing
}

public enum PluginWidgetStyle {
    case artwork
    case visualizer(isActive: Bool)
    case symbol(String)
    case labeledSymbol(systemName: String, text: String)
    case circularProgress(systemName: String, progress: CGFloat, isActive: Bool, text: String)
    case custom(render: @MainActor () -> AnyView)
}

public struct PluginWidgetDescriptor: Identifiable {
    public let id: String
    public let title: String
    public let placement: PluginWidgetPlacement
    public let priority: Int
    public let style: PluginWidgetStyle
    public let preferredWidth: CGFloat
    public let artworkData: Data?

    public init(
        id: String,
        title: String,
        placement: PluginWidgetPlacement,
        priority: Int,
        style: PluginWidgetStyle,
        preferredWidth: CGFloat,
        artworkData: Data? = nil
    ) {
        self.id = id
        self.title = title
        self.placement = placement
        self.priority = priority
        self.style = style
        self.preferredWidth = preferredWidth
        self.artworkData = artworkData
    }
}

public struct PluginExpandedPageDescriptor: Identifiable {
    public let id: String
    public let title: String
    public let preferredWidth: CGFloat
    public let render: @MainActor () -> AnyView

    public init(id: String, title: String, preferredWidth: CGFloat, render: @escaping @MainActor () -> AnyView) {
        self.id = id
        self.title = title
        self.preferredWidth = preferredWidth
        self.render = render
    }
}

public struct PluginSettingsSectionDescriptor: Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let render: @MainActor () -> AnyView

    public init(id: String, title: String, subtitle: String? = nil, render: @escaping @MainActor () -> AnyView) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.render = render
    }
}

public struct PluginNowPlayingSnapshot: Sendable {
    public let title: String
    public let artist: String
    public let album: String
    public let sourceApp: String?
    public let isPlaying: Bool

    public init(title: String, artist: String, album: String, sourceApp: String?, isPlaying: Bool) {
        self.title = title
        self.artist = artist
        self.album = album
        self.sourceApp = sourceApp
        self.isPlaying = isPlaying
    }
}

public struct PluginWeatherSnapshot: Sendable {
    public let temperatureText: String?
    public let symbolName: String?
    public let manualLocation: String?

    public init(temperatureText: String?, symbolName: String?, manualLocation: String?) {
        self.temperatureText = temperatureText
        self.symbolName = symbolName
        self.manualLocation = manualLocation
    }
}

public struct PluginVolumeSnapshot: Sendable {
    public let level: Double
    public let outputDeviceName: String?

    public init(level: Double, outputDeviceName: String?) {
        self.level = level
        self.outputDeviceName = outputDeviceName
    }
}

public enum PluginHostEvent: Sendable {
    case nowPlaying(PluginNowPlayingSnapshot?)
    case weather(PluginWeatherSnapshot)
    case volume(PluginVolumeSnapshot)
}

@MainActor
public protocol PullNotchPlugin: AnyObject {
    static var manifest: PluginManifest { get }
    init()
    func activate(context: PluginContext) async throws
    func deactivate() async
}

@MainActor
public final class PluginContext {
    public let manifest: PluginManifest

    private let registerWidgetHandler: (PluginWidgetDescriptor) -> Void
    private let unregisterWidgetHandler: (String) -> Void
    private let registerExpandedPageHandler: (PluginExpandedPageDescriptor) -> Void
    private let unregisterExpandedPageHandler: (String) -> Void
    private let registerSettingsSectionHandler: (PluginSettingsSectionDescriptor) -> Void
    private let unregisterSettingsSectionHandler: (String) -> Void
    private let showStatusHandler: (String, TimeInterval) -> Void
    private let subscribeHandler: (@escaping @MainActor (PluginHostEvent) -> Void) -> UUID
    private let unsubscribeHandler: (UUID) -> Void
    private let nowPlayingProvider: () -> PluginNowPlayingSnapshot?
    private let weatherProvider: () -> PluginWeatherSnapshot
    private let volumeProvider: () -> PluginVolumeSnapshot?

    public init(
        manifest: PluginManifest,
        registerWidgetHandler: @escaping (PluginWidgetDescriptor) -> Void,
        unregisterWidgetHandler: @escaping (String) -> Void,
        registerExpandedPageHandler: @escaping (PluginExpandedPageDescriptor) -> Void,
        unregisterExpandedPageHandler: @escaping (String) -> Void,
        registerSettingsSectionHandler: @escaping (PluginSettingsSectionDescriptor) -> Void,
        unregisterSettingsSectionHandler: @escaping (String) -> Void,
        showStatusHandler: @escaping (String, TimeInterval) -> Void,
        subscribeHandler: @escaping (@escaping @MainActor (PluginHostEvent) -> Void) -> UUID,
        unsubscribeHandler: @escaping (UUID) -> Void,
        nowPlayingProvider: @escaping () -> PluginNowPlayingSnapshot?,
        weatherProvider: @escaping () -> PluginWeatherSnapshot,
        volumeProvider: @escaping () -> PluginVolumeSnapshot?
    ) {
        self.manifest = manifest
        self.registerWidgetHandler = registerWidgetHandler
        self.unregisterWidgetHandler = unregisterWidgetHandler
        self.registerExpandedPageHandler = registerExpandedPageHandler
        self.unregisterExpandedPageHandler = unregisterExpandedPageHandler
        self.registerSettingsSectionHandler = registerSettingsSectionHandler
        self.unregisterSettingsSectionHandler = unregisterSettingsSectionHandler
        self.showStatusHandler = showStatusHandler
        self.subscribeHandler = subscribeHandler
        self.unsubscribeHandler = unsubscribeHandler
        self.nowPlayingProvider = nowPlayingProvider
        self.weatherProvider = weatherProvider
        self.volumeProvider = volumeProvider
    }

    public func registerWidget(_ descriptor: PluginWidgetDescriptor) {
        registerWidgetHandler(descriptor)
    }

    public func unregisterWidget(id: String) {
        unregisterWidgetHandler(id)
    }

    public func registerExpandedPage(_ descriptor: PluginExpandedPageDescriptor) {
        registerExpandedPageHandler(descriptor)
    }

    public func unregisterExpandedPage(id: String) {
        unregisterExpandedPageHandler(id)
    }

    public func registerSettingsSection(_ descriptor: PluginSettingsSectionDescriptor) {
        registerSettingsSectionHandler(descriptor)
    }

    public func unregisterSettingsSection(id: String) {
        unregisterSettingsSectionHandler(id)
    }

    public func showStatus(_ message: String, duration: TimeInterval = 3) {
        showStatusHandler(message, duration)
    }

    @discardableResult
    public func subscribe(_ handler: @escaping @MainActor (PluginHostEvent) -> Void) -> UUID {
        subscribeHandler(handler)
    }

    public func unsubscribe(_ token: UUID) {
        unsubscribeHandler(token)
    }

    public var currentNowPlaying: PluginNowPlayingSnapshot? {
        nowPlayingProvider()
    }

    public var currentWeather: PluginWeatherSnapshot {
        weatherProvider()
    }

    public var currentVolume: PluginVolumeSnapshot? {
        volumeProvider()
    }
}
