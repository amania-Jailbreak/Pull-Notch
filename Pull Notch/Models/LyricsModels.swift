import Foundation

nonisolated struct LyricsTrackMetadata: Sendable {
    let trackName: String
    let artistName: String
    let albumName: String
    let durationSeconds: TimeInterval?
}

nonisolated struct SyncedLyricLine: Equatable, Identifiable, Sendable {
    let timestamp: TimeInterval
    let text: String

    var id: String {
        "\(timestamp)-\(text)"
    }
}

nonisolated enum LyricsLoadState: Equatable, Sendable {
    case idle
    case loading
    case unavailable
    case ready
}

nonisolated enum LyricsProvider: String, Sendable {
    case lrclib = "LRCLIB"
    case petitLyrics = "PetitLyrics"
    case musanovaKit = "MusanovaKit"
    case qqMusic = "QQ Music"
    case netEase = "NetEase"
    case amaniaLyrics = "Amania Lyrics"
}

nonisolated struct ResolvedLyrics: Sendable {
    let plainLyrics: String?
    let syncedLyrics: String?
    let provider: LyricsProvider
}
