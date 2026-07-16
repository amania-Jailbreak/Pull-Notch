import Foundation
import SwiftUI
import PullNotchPluginKit

enum ExpandedPageSource {
    case builtIn(ExpandedWidgetPageKind)
    case plugin(String)
}

struct ExpandedPageDescriptor: Identifiable {
    let id: String
    let title: String
    let source: ExpandedPageSource
    let preferredWidth: CGFloat?
    let render: (@MainActor @Sendable () -> AnyView)?
}

struct BridgeWidgetPayload: Codable, Sendable {
    let id: String
    let title: String
    let placement: String
    let priority: Int?
    let kind: String
    let preferredWidth: Double?
    let systemName: String?
    let text: String?
    let progress: Double?
    let isActive: Bool?
    let artworkBase64: String?

    func pluginDescriptor() -> PluginWidgetDescriptor? {
        let placement: PluginWidgetPlacement = placement.lowercased() == "leading" ? .leading : .trailing
        let style: PluginWidgetStyle

        switch kind.lowercased() {
        case "artwork":
            style = .artwork
        case "visualizer":
            style = .visualizer(isActive: isActive ?? true)
        case "symbol":
            guard let systemName else { return nil }
            style = .symbol(systemName)
        case "labeledsymbol":
            guard let systemName, let text else { return nil }
            style = .labeledSymbol(systemName: systemName, text: text)
        case "circularprogress":
            guard let systemName, let text else { return nil }
            style = .circularProgress(
                systemName: systemName,
                progress: CGFloat(progress ?? 0),
                isActive: isActive ?? true,
                text: text
            )
        default:
            return nil
        }

        let artworkData = artworkBase64.flatMap { Data(base64Encoded: $0) }

        return PluginWidgetDescriptor(
            id: id,
            title: title,
            placement: placement,
            priority: priority ?? 100,
            style: style,
            preferredWidth: CGFloat(preferredWidth ?? 24),
            artworkData: artworkData
        )
    }
}

struct BridgePagePayload: Codable, Sendable {
    let id: String
    let title: String
    let preferredWidth: Double?
    let symbolName: String?
    let headline: String?
    let subheadline: String?
    let body: String?
    let footnote: String?
    let elements: [BridgePageElementPayload]?
    let notification: Bool?
}

struct BridgeDashboardWidgetPayload: Codable, Sendable {
    let id: String
    let title: String
    let symbolName: String?
    let headline: String?
    let subheadline: String?
    let body: String?
    let footnote: String?
    let elements: [BridgePageElementPayload]?

    var pagePayload: BridgePagePayload {
        BridgePagePayload(
            id: id,
            title: title,
            preferredWidth: nil,
            symbolName: symbolName,
            headline: headline,
            subheadline: subheadline,
            body: body,
            footnote: footnote,
            elements: elements,
            notification: nil
        )
    }
}

struct BridgePageElementPayload: Codable, Sendable {
    let type: String
    let id: String?
    let text: String?
    let label: String?
    let value: Double?
    let title: String?
    let systemName: String?
    let placeholder: String?
    let postURL: String?
    let body: [String: String]?
    let postExit: Bool?
}

struct BridgePluginRuntimeSnapshot: Codable, Sendable {
    let id: String
    let displayName: String
    let version: String
    let capabilities: [String]
    let state: String
    let errorMessage: String?
}

struct BridgeNowPlayingSnapshot: Codable, Sendable {
    let title: String
    let artist: String
    let album: String
    let sourceApp: String?
    let isPlaying: Bool
}

struct BridgeWeatherSnapshot: Codable, Sendable {
    let temperatureText: String?
    let symbolName: String?
    let manualLocation: String?
}

struct BridgeVolumeSnapshot: Codable, Sendable {
    let level: Double
    let outputDeviceName: String?
}

struct BridgeStateSnapshot: Codable, Sendable {
    let nowPlaying: BridgeNowPlayingSnapshot?
    let weather: BridgeWeatherSnapshot
    let volume: BridgeVolumeSnapshot?
    let expandedPanel: String?
    let activeExpandedPageID: String?
    let pluginStatusMessage: String?
    let plugins: [BridgePluginRuntimeSnapshot]
}
