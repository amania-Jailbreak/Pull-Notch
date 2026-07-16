import Foundation

nonisolated struct AppleMusicTrack: Sendable {
    let title: String
    let album: String
    let artist: String
    let isPlaying: Bool
    let bundleIdentifier: String
    let artworkData: Data?
    let durationSeconds: TimeInterval?
    let playbackPositionSeconds: TimeInterval?
}

nonisolated struct IslandPresentation: Equatable, Sendable {
    let id: String
    let detailLine: String?
    let sourceApp: String?
    let artworkData: Data?
    let isPlaying: Bool
}
