import Foundation
import Observation

@MainActor
@Observable
final class OverlayPreferencesStore {
    private enum Key {
        static let hasShownOnboarding = "PullNotch.hasShownOnboarding"
        static let featurePrefix = "PullNotch.feature."
        static let manualWeatherLocation = "PullNotch.weather.manualLocation"
        static let nowPlayingArtworkVisible = "PullNotch.nowPlaying.artworkVisible"
        static let nowPlayingVisualizerVisible = "PullNotch.nowPlaying.visualizerVisible"
        static let nowPlayingVisualizerAnimated = "PullNotch.nowPlaying.visualizerAnimated"
        static let nowPlayingVisualizerMode = "PullNotch.nowPlaying.visualizerMode"
        static let toastLyricsVisible = "PullNotch.toast.lyricsVisible"
        static let pinnedFileBookmark = "PullNotch.pinnedFileBookmark"
    }

    private(set) var featureStates: [OverlayFeature: Bool]
    private(set) var manualWeatherLocation: String?
    private(set) var nowPlayingShowsArtwork: Bool
    private(set) var nowPlayingShowsVisualizer: Bool
    private(set) var nowPlayingAnimatesVisualizer: Bool
    private(set) var nowPlayingVisualizerMode: NowPlayingVisualizerMode
    private(set) var toastShowsLyrics: Bool
    private(set) var hasShownOnboarding: Bool
    private(set) var pinnedFileURL: URL?

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        featureStates = Dictionary(
            uniqueKeysWithValues: OverlayFeature.allCases.map { feature in
                let storedValue = defaults.object(forKey: Key.featurePrefix + feature.rawValue) as? Bool
                return (feature, storedValue ?? true)
            }
        )
        manualWeatherLocation = defaults.string(forKey: Key.manualWeatherLocation)
        nowPlayingShowsArtwork = Self.bool(
            forKey: Key.nowPlayingArtworkVisible,
            defaultValue: true,
            defaults: defaults
        )
        nowPlayingShowsVisualizer = Self.bool(
            forKey: Key.nowPlayingVisualizerVisible,
            defaultValue: true,
            defaults: defaults
        )
        nowPlayingAnimatesVisualizer = Self.bool(
            forKey: Key.nowPlayingVisualizerAnimated,
            defaultValue: true,
            defaults: defaults
        )
        toastShowsLyrics = Self.bool(
            forKey: Key.toastLyricsVisible,
            defaultValue: false,
            defaults: defaults
        )
        nowPlayingVisualizerMode = defaults
            .string(forKey: Key.nowPlayingVisualizerMode)
            .flatMap(NowPlayingVisualizerMode.init(rawValue:))
            ?? .fake
        hasShownOnboarding = defaults.bool(forKey: Key.hasShownOnboarding)
        pinnedFileURL = Self.restorePinnedFileURL(defaults: defaults)
    }

    func isFeatureEnabled(_ feature: OverlayFeature) -> Bool {
        featureStates[feature] ?? true
    }

    func setFeatureEnabled(_ feature: OverlayFeature, isEnabled: Bool) {
        featureStates[feature] = isEnabled
        defaults.set(isEnabled, forKey: Key.featurePrefix + feature.rawValue)
    }

    @discardableResult
    func setManualWeatherLocation(_ location: String?) -> String? {
        let trimmedLocation = location?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLocation = trimmedLocation?.isEmpty == false ? trimmedLocation : nil
        manualWeatherLocation = normalizedLocation

        if let normalizedLocation {
            defaults.set(normalizedLocation, forKey: Key.manualWeatherLocation)
        } else {
            defaults.removeObject(forKey: Key.manualWeatherLocation)
        }
        return normalizedLocation
    }

    func setNowPlayingArtworkVisible(_ isVisible: Bool) {
        nowPlayingShowsArtwork = isVisible
        defaults.set(isVisible, forKey: Key.nowPlayingArtworkVisible)
    }

    func setNowPlayingVisualizerVisible(_ isVisible: Bool) {
        nowPlayingShowsVisualizer = isVisible
        defaults.set(isVisible, forKey: Key.nowPlayingVisualizerVisible)
    }

    func setNowPlayingVisualizerAnimated(_ isAnimated: Bool) {
        nowPlayingAnimatesVisualizer = isAnimated
        defaults.set(isAnimated, forKey: Key.nowPlayingVisualizerAnimated)
    }

    func setNowPlayingVisualizerMode(_ mode: NowPlayingVisualizerMode) {
        nowPlayingVisualizerMode = mode
        defaults.set(mode.rawValue, forKey: Key.nowPlayingVisualizerMode)
    }

    func setToastLyricsVisible(_ isVisible: Bool) {
        toastShowsLyrics = isVisible
        defaults.set(isVisible, forKey: Key.toastLyricsVisible)
    }

    func completeOnboarding() {
        hasShownOnboarding = true
        defaults.set(true, forKey: Key.hasShownOnboarding)
    }

    func setPinnedFileURL(_ url: URL) {
        pinnedFileURL = url
        if let bookmarkData = try? url.bookmarkData() {
            defaults.set(bookmarkData, forKey: Key.pinnedFileBookmark)
        } else {
            defaults.removeObject(forKey: Key.pinnedFileBookmark)
        }
    }

    func clearPinnedFileURL() {
        pinnedFileURL = nil
        defaults.removeObject(forKey: Key.pinnedFileBookmark)
    }

    private static func bool(
        forKey key: String,
        defaultValue: Bool,
        defaults: UserDefaults
    ) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }

    private static func restorePinnedFileURL(defaults: UserDefaults) -> URL? {
        guard let bookmarkData = defaults.data(forKey: Key.pinnedFileBookmark) else { return nil }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            bookmarkDataIsStale: &isStale
        ) else {
            defaults.removeObject(forKey: Key.pinnedFileBookmark)
            return nil
        }
        if isStale, let refreshedBookmark = try? url.bookmarkData() {
            defaults.set(refreshedBookmark, forKey: Key.pinnedFileBookmark)
        }
        return url
    }
}
