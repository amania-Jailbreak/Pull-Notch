import AppKit
import Foundation
import Observation
import SwiftUI

struct AppleMusicTrack {
    let title: String
    let album: String
    let artist: String
    let isPlaying: Bool
    let bundleIdentifier: String
    let artworkData: Data?
    let durationSeconds: TimeInterval?
    let playbackPositionSeconds: TimeInterval?
}

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

struct SyncedLyricLine: Equatable, Identifiable, Sendable {
    let timestamp: TimeInterval
    let text: String

    var id: String {
        "\(timestamp)-\(text)"
    }
}

enum LyricsLoadState: Equatable {
    case idle
    case loading
    case unavailable
    case ready
}

enum LyricsProvider: String, Sendable {
    case lrclib = "LRCLIB"
    case petitLyrics = "PetitLyrics"
    case musanovaKit = "MusanovaKit"
    case qqMusic = "QQ Music"
    case netEase = "NetEase"
}

struct ResolvedLyrics: Sendable {
    let plainLyrics: String?
    let syncedLyrics: String?
    let provider: LyricsProvider
}

struct IslandPresentation: Equatable {
    let id: String
    let detailLine: String?
    let sourceApp: String?
    let artworkData: Data?
    let isPlaying: Bool
}

enum CompactWidgetStyle {
    case artwork
    case visualizer(isActive: Bool)
    case symbol(String)
    case labeledSymbol(systemName: String, text: String)
    case circularProgress(systemName: String, progress: CGFloat, isActive: Bool, text: String)
    case custom(render: @MainActor () -> AnyView)
}

enum NowPlayingVisualizerMode: String {
    case fake
    case real
}

enum CompactWidgetPlacement: Equatable {
    case leading
    case trailing
}

enum MoveDirection {
    case up
    case down
}

enum ExpandedPageNavigationDirection {
    case forward
    case backward
}

enum CompactWidgetKind: String, CaseIterable, Identifiable {
    case pinnedFile
    case nowPlayingArtwork
    case battery
    case nowPlayingVisualizer
    case weather
    case pomodoro
    case chargingPower

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pinnedFile:
            return "Pinned File"
        case .nowPlayingArtwork:
            return "Now Playing Artwork"
        case .battery:
            return "Battery"
        case .nowPlayingVisualizer:
            return "Now Playing Visualizer"
        case .weather:
            return "Weather"
        case .pomodoro:
            return "Pomodoro"
        case .chargingPower:
            return "Charging Power"
        }
    }

    var placement: CompactWidgetPlacement {
        switch self {
        case .pinnedFile, .nowPlayingArtwork, .battery:
            return .leading
        case .nowPlayingVisualizer, .weather, .pomodoro, .chargingPower:
            return .trailing
        }
    }
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
    case pinnedFile
    case weather
    case pomodoro

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nowPlaying:
            return "Now Playing"
        case .pinnedFile:
            return "Pinned File"
        case .weather:
            return "Weather"
        case .pomodoro:
            return "Pomodoro"
        }
    }
}

enum OverlayFeature: String, CaseIterable, Identifiable {
    case pinnedFile
    case nowPlaying
    case battery
    case weather
    case pomodoro
    case volumeOverlay
    case hoverTitle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pinnedFile:
            return "Pinned File"
        case .nowPlaying:
            return "Now Playing"
        case .battery:
            return "Battery"
        case .weather:
            return "Weather"
        case .pomodoro:
            return "Pomodoro"
        case .volumeOverlay:
            return "Volume Overlay"
        case .hoverTitle:
            return "Hover Title"
        }
    }

    var subtitle: String {
        switch self {
        case .pinnedFile:
            return "ドラッグしたファイルを常時表示"
        case .nowPlaying:
            return "曲情報とミニプレイヤーを表示"
        case .battery:
            return "バッテリー残量を常時表示"
        case .weather:
            return "現在地の天気を表示"
        case .pomodoro:
            return "25分 / 5分の集中タイマーを表示"
        case .volumeOverlay:
            return "音量変更時にバーを表示"
        case .hoverTitle:
            return "ホバー時に曲名を表示"
        }
    }
}

enum PomodoroPhase {
    case focus
    case `break`

    var title: String {
        switch self {
        case .focus:
            return "Focus Session"
        case .break:
            return "Break Time"
        }
    }

    var duration: Int {
        switch self {
        case .focus:
            return 25 * 60
        case .break:
            return 5 * 60
        }
    }

    var symbolName: String {
        switch self {
        case .focus:
            return "timer"
        case .break:
            return "cup.and.saucer.fill"
        }
    }

    var actionTitle: String {
        switch self {
        case .focus:
            return "Start Focus"
        case .break:
            return "Start Break"
        }
    }

    var next: PomodoroPhase {
        switch self {
        case .focus:
            return .break
        case .break:
            return .focus
        }
    }
}
