import Foundation
import Observation

@MainActor
@Observable
final class NowPlayingModel {
    private(set) var currentPresentation: IslandPresentation?
    private(set) var title: String?
    private(set) var artist: String?
    private(set) var albumName: String?
    private(set) var durationSeconds: TimeInterval?
    private(set) var playbackPositionSeconds: TimeInterval = 0
    private(set) var playbackPositionUpdatedAt: Date?

    var detailLine: String? { currentPresentation?.detailLine }
    var sourceApp: String? { currentPresentation?.sourceApp }
    var artworkData: Data? { currentPresentation?.artworkData }
    var isPlaying: Bool { currentPresentation?.isPlaying ?? false }

    @discardableResult
    func update(track: AppleMusicTrack, at updateDate: Date = .now) -> Bool {
        let presentation = IslandPresentation(
            id: [track.title, track.artist, track.album].joined(separator: "||"),
            detailLine: [track.title, track.artist]
                .filter { !$0.isEmpty }
                .joined(separator: " - "),
            sourceApp: track.bundleIdentifier,
            artworkData: track.artworkData,
            isPlaying: track.isPlaying
        )
        let didChangeTrack = currentPresentation?.id != presentation.id

        currentPresentation = presentation
        title = track.title
        artist = track.artist
        albumName = track.album.isEmpty ? nil : track.album
        durationSeconds = track.durationSeconds
        playbackPositionSeconds = max(0, track.playbackPositionSeconds ?? 0)
        playbackPositionUpdatedAt = updateDate
        return didChangeTrack
    }

    func present(_ presentation: IslandPresentation) {
        currentPresentation = presentation
        let components = presentation.detailLine?.components(separatedBy: " - ") ?? []
        title = components.first
        artist = components.dropFirst().joined(separator: " - ")
    }

    func estimatedPlaybackPosition(at date: Date = .now) -> TimeInterval {
        let basePosition = max(0, playbackPositionSeconds)
        guard isPlaying, let updatedAt = playbackPositionUpdatedAt else {
            return clampedPlaybackPosition(basePosition)
        }

        let advancedPosition = basePosition + max(0, date.timeIntervalSince(updatedAt))
        return clampedPlaybackPosition(advancedPosition)
    }

    func clear() {
        currentPresentation = nil
        title = nil
        artist = nil
        albumName = nil
        durationSeconds = nil
        playbackPositionSeconds = 0
        playbackPositionUpdatedAt = nil
    }

    private func clampedPlaybackPosition(_ position: TimeInterval) -> TimeInterval {
        guard let durationSeconds, durationSeconds > 0 else {
            return max(0, position)
        }
        return min(max(0, position), durationSeconds)
    }
}
