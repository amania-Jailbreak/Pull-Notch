import Foundation
import Observation

nonisolated protocol LyricsLoading: Sendable {
    func lyrics(
        trackName: String,
        artistName: String,
        albumName: String,
        durationSeconds: TimeInterval?
    ) async -> ResolvedLyrics?

    func parseSyncedLyrics(_ syncedLyrics: String?) async -> [SyncedLyricLine]
}

@MainActor
@Observable
final class LyricsModel {
    @ObservationIgnored var onUpdate: (@MainActor () -> Void)?

    private(set) var syncedLyrics: [SyncedLyricLine] = []
    private(set) var plainLyricsText: String?
    private(set) var loadState: LyricsLoadState = .idle
    private(set) var provider: LyricsProvider?

    @ObservationIgnored private let loader: any LyricsLoading
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var currentRequestKey: RequestKey?

    init(loader: any LyricsLoading) {
        self.loader = loader
    }

    deinit {
        loadTask?.cancel()
    }

    func update(for track: LyricsTrackMetadata) {
        let requestKey = RequestKey(track: track)
        guard requestKey != currentRequestKey else { return }

        loadTask?.cancel()
        currentRequestKey = requestKey
        syncedLyrics = []
        plainLyricsText = nil
        provider = nil

        guard let requestKey else {
            loadState = .unavailable
            onUpdate?()
            return
        }

        loadState = .loading
        onUpdate?()

        let loader = self.loader
        loadTask = Task { @MainActor [weak self] in
            let lyrics = await loader.lyrics(
                trackName: requestKey.trackName,
                artistName: requestKey.artistName,
                albumName: requestKey.albumName,
                durationSeconds: TimeInterval(requestKey.durationSeconds)
            )

            guard
                !Task.isCancelled,
                let self,
                self.currentRequestKey == requestKey
            else {
                return
            }

            let parsedSyncedLyrics = await loader.parseSyncedLyrics(lyrics?.syncedLyrics)
            guard !Task.isCancelled, self.currentRequestKey == requestKey else { return }

            self.syncedLyrics = parsedSyncedLyrics
            self.plainLyricsText = lyrics?.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.provider = lyrics?.provider
            self.loadState = !parsedSyncedLyrics.isEmpty || self.plainLyricsText?.isEmpty == false
                ? .ready
                : .unavailable
            self.onUpdate?()
        }
    }

    func reset() {
        loadTask?.cancel()
        loadTask = nil
        currentRequestKey = nil
        syncedLyrics = []
        plainLyricsText = nil
        loadState = .idle
        provider = nil
        onUpdate?()
    }

    func activeLineIndex(at playbackPosition: TimeInterval) -> Int? {
        guard !syncedLyrics.isEmpty else { return nil }

        var currentIndex: Int?
        for (index, line) in syncedLyrics.enumerated()
        where line.timestamp <= max(0, playbackPosition) + 0.12 {
            currentIndex = index
        }
        return currentIndex
    }

    func visibleLines(
        at playbackPosition: TimeInterval
    ) -> [(line: SyncedLyricLine, isActive: Bool, isContext: Bool)] {
        guard !syncedLyrics.isEmpty else { return [] }

        guard let activeIndex = activeLineIndex(at: playbackPosition) else {
            return Array(syncedLyrics.prefix(2)).map { ($0, false, true) }
        }

        let upperBound = min(syncedLyrics.count - 1, activeIndex + 1)
        return Array(syncedLyrics[activeIndex...upperBound].enumerated()).map { offset, line in
            let index = activeIndex + offset
            return (line, index == activeIndex, index != activeIndex)
        }
    }

    var statusText: String {
        switch loadState {
        case .idle:
            return "Lyrics"
        case .loading:
            return "Loading lyrics..."
        case .unavailable:
            return "Lyrics unavailable"
        case .ready:
            let providerName = provider?.rawValue ?? "Lyrics"
            return syncedLyrics.isEmpty
                ? "Plain lyrics via \(providerName)"
                : "Synced via \(providerName)"
        }
    }

    var fallbackPreviewText: String? {
        guard syncedLyrics.isEmpty, let plainLyricsText else { return nil }

        let preview = plainLyricsText
            .split(whereSeparator: \.isNewline)
            .prefix(2)
            .map(String.init)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.isEmpty ? nil : preview
    }

    func toastText(
        at playbackPosition: TimeInterval,
        fallbackDetail: String?
    ) -> String? {
        if let activeIndex = activeLineIndex(at: playbackPosition) {
            let text = syncedLyrics[activeIndex].text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        if let firstPlainLine = plainLyricsText?
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return firstPlainLine
        }

        switch loadState {
        case .idle, .ready:
            return fallbackDetail
        case .loading:
            return "Loading lyrics..."
        case .unavailable:
            return fallbackDetail ?? "Lyrics unavailable"
        }
    }
}

private extension LyricsModel {
    nonisolated struct RequestKey: Equatable, Sendable {
        let trackName: String
        let artistName: String
        let albumName: String
        let durationSeconds: Int

        init?(track: LyricsTrackMetadata) {
            guard let duration = track.durationSeconds, duration > 0 else { return nil }

            let trackName = track.trackName.trimmingCharacters(in: .whitespacesAndNewlines)
            let artistName = track.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
            let albumName = track.albumName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trackName.isEmpty, !artistName.isEmpty else { return nil }

            self.trackName = trackName
            self.artistName = artistName
            self.albumName = albumName
            durationSeconds = Int(duration.rounded())
        }

        static func == (lhs: RequestKey, rhs: RequestKey) -> Bool {
            lhs.trackName.lowercased() == rhs.trackName.lowercased()
                && lhs.artistName.lowercased() == rhs.artistName.lowercased()
                && lhs.albumName.lowercased() == rhs.albumName.lowercased()
                && lhs.durationSeconds == rhs.durationSeconds
        }
    }
}
