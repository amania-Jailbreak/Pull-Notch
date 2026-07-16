import AppKit
import Foundation
import Observation
import SwiftUI

struct MediaRemotePayload: Decodable, Sendable {
    let bundleIdentifier: String?
    let parentApplicationBundleIdentifier: String?
    let playing: Bool?
    let title: String?
    let album: String?
    let artist: String?
    let playbackRate: Double?
    let artworkData: String?
    let duration: Double?
    let elapsedTime: Double?
    let elapsedTimeNow: Double?
    let durationMicros: Double?
    let elapsedTimeMicros: Double?
    let elapsedTimeNowMicros: Double?
    let timestampEpochMicros: Double?
}

enum CompactWidgetStyle {
    case artwork
    case visualizer(isActive: Bool)
    case symbol(String)
    case labeledSymbol(systemName: String, text: String)
    case circularProgress(systemName: String, progress: CGFloat, isActive: Bool, text: String)
    case custom(render: @MainActor @Sendable () -> AnyView)
}

struct CompactIslandWidget: Identifiable {
    let id: String
    let identity: CompactWidgetIdentity
    let title: String
    let placement: CompactWidgetPlacement
    let style: CompactWidgetStyle
    let preferredWidth: CGFloat
    let artworkData: Data?
}

enum IslandHapticFeedback {
    case generic
    case alignment
    case levelChange

    var pattern: NSHapticFeedbackManager.FeedbackPattern {
        switch self {
        case .generic:
            return .generic
        case .alignment:
            return .alignment
        case .levelChange:
            return .levelChange
        }
    }
}

enum ExpandedIslandPanel {
    case musicPlayer
    case onboarding
}

enum MediaControlCommand: Int {
    case togglePlayPause = 2
    case nextTrack = 4
    case previousTrack = 5
}

enum ExpandedWidgetPageKind: String, Identifiable {
    case nowPlaying
    case widgetBoard
    case pinnedFile
    case weather
    case pomodoro

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nowPlaying:
            return "Now Playing"
        case .widgetBoard:
            return "Widgets"
        case .pinnedFile:
            return "Pinned Files"
        case .weather:
            return "Weather"
        case .pomodoro:
            return "Pomodoro"
        }
    }
}
