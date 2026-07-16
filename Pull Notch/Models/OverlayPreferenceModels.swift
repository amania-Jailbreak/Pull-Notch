import Foundation

nonisolated enum NowPlayingVisualizerMode: String, Sendable {
    case fake
    case real
}

nonisolated enum OverlayFeature: String, CaseIterable, Identifiable, Sendable {
    case pinnedFile
    case nowPlaying
    case battery
    case weather
    case pomodoro
    case reminders
    case systemStatus
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
        case .reminders:
            return "Reminders"
        case .systemStatus:
            return "System Status"
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
        case .reminders:
            return "今日と期限超過のタスクを表示"
        case .systemStatus:
            return "CPU・メモリ・ストレージを表示"
        case .volumeOverlay:
            return "音量変更時にバーを表示"
        case .hoverTitle:
            return "ホバー時に曲名を表示"
        }
    }
}
