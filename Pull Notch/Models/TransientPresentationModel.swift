import Foundation
import Observation

@MainActor
@Observable
final class TransientPresentationModel {
    typealias Sleep = @Sendable (TimeInterval) async -> Void

    @ObservationIgnored var onUpdate: (@MainActor () -> Void)?

    private(set) var showsTrackChange = false
    private(set) var showsTrackText = false
    private(set) var showsHoverChange = false
    private(set) var showsHoverText = false
    private(set) var pluginStatusMessage: String?
    private(set) var showsPluginStatus = false
    private(set) var toastLyricsDismissed = false

    @ObservationIgnored private let sleep: Sleep
    @ObservationIgnored private var trackTask: Task<Void, Never>?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var pluginStatusTask: Task<Void, Never>?
    @ObservationIgnored private var trackGeneration = 0
    @ObservationIgnored private var hoverGeneration = 0
    @ObservationIgnored private var pluginStatusGeneration = 0

    init(sleep: @escaping Sleep = { duration in
        try? await Task.sleep(for: .seconds(duration))
    }) {
        self.sleep = sleep
    }

    deinit {
        trackTask?.cancel()
        hoverTask?.cancel()
        pluginStatusTask?.cancel()
    }

    func showTrackChange(
        displayDuration: TimeInterval = 5,
        fadeDuration: TimeInterval = 0.28
    ) {
        invalidateTrackTask()
        hidePluginStatus(notify: false)
        hideHover(notify: false)
        toastLyricsDismissed = false
        showsTrackChange = true
        showsTrackText = true
        onUpdate?()

        let generation = trackGeneration
        trackTask = Task { @MainActor [weak self, sleep] in
            await sleep(max(0, displayDuration))
            guard
                !Task.isCancelled,
                let self,
                self.trackGeneration == generation
            else {
                return
            }
            self.showsTrackText = false
            self.onUpdate?()

            await sleep(max(0, fadeDuration))
            guard !Task.isCancelled, self.trackGeneration == generation else { return }
            self.showsTrackChange = false
            self.trackTask = nil
            self.onUpdate?()
        }
    }

    @discardableResult
    func dismissToast(
        lyricsToastIsVisible: Bool,
        toastLyricsEnabled: Bool
    ) -> Bool {
        guard showsTrackChange || lyricsToastIsVisible else { return false }
        invalidateTrackTask()
        showsTrackText = false
        showsTrackChange = false
        if toastLyricsEnabled {
            toastLyricsDismissed = true
        }
        onUpdate?()
        return true
    }

    @discardableResult
    func handleSpaceKey(
        lyricsToastIsVisible: Bool,
        toastLyricsEnabled: Bool
    ) -> Bool {
        if dismissToast(
            lyricsToastIsVisible: lyricsToastIsVisible,
            toastLyricsEnabled: toastLyricsEnabled
        ) {
            return true
        }
        guard toastLyricsEnabled, toastLyricsDismissed else { return false }
        toastLyricsDismissed = false
        onUpdate?()
        return true
    }

    func setToastLyricsVisible(_ isVisible: Bool) {
        toastLyricsDismissed = false
        if isVisible {
            invalidateTrackTask()
            showsTrackText = false
            showsTrackChange = false
        }
        onUpdate?()
    }

    func setHoverVisible(
        _ isVisible: Bool,
        canShow: Bool,
        hideDelay: TimeInterval = 0.14
    ) {
        invalidateHoverTask()

        guard canShow else {
            if !isVisible, showsHoverChange || showsHoverText {
                hideHover(notify: true)
            }
            return
        }

        if isVisible {
            guard !showsHoverChange || !showsHoverText else { return }
            showsHoverChange = true
            showsHoverText = true
            onUpdate?()
            return
        }

        let generation = hoverGeneration
        hoverTask = Task { @MainActor [weak self, sleep] in
            await sleep(max(0, hideDelay))
            guard
                !Task.isCancelled,
                let self,
                self.hoverGeneration == generation,
                self.showsHoverChange || self.showsHoverText
            else {
                return
            }
            self.showsHoverChange = false
            self.showsHoverText = false
            self.hoverTask = nil
            self.onUpdate?()
        }
    }

    func disableHover() {
        hideHover(notify: true)
    }

    func showPluginStatus(
        message: String,
        duration: TimeInterval = 3
    ) {
        invalidatePluginStatusTask()
        invalidateTrackTask()
        hideHover(notify: false)
        showsTrackChange = false
        showsTrackText = false
        pluginStatusMessage = message
        showsPluginStatus = true
        onUpdate?()

        let generation = pluginStatusGeneration
        pluginStatusTask = Task { @MainActor [weak self, sleep] in
            await sleep(max(0, duration))
            guard
                !Task.isCancelled,
                let self,
                self.pluginStatusGeneration == generation
            else {
                return
            }
            self.showsPluginStatus = false
            self.pluginStatusMessage = nil
            self.pluginStatusTask = nil
            self.onUpdate?()
        }
    }

    func hideForVolume() {
        invalidateTrackTask()
        showsTrackChange = false
        showsTrackText = false
        hidePluginStatus(notify: false)
        hideHover(notify: false)
        onUpdate?()
    }

    func hideTrackAndPluginStatus() {
        invalidateTrackTask()
        showsTrackChange = false
        showsTrackText = false
        hidePluginStatus(notify: false)
        onUpdate?()
    }

    func hidePluginStatus() {
        hidePluginStatus(notify: true)
    }

    func hidePluginStatusAndHover() {
        hidePluginStatus(notify: false)
        hideHover(notify: false)
        onUpdate?()
    }

    func reset() {
        invalidateTrackTask()
        showsTrackChange = false
        showsTrackText = false
        hidePluginStatus(notify: false)
        hideHover(notify: false)
        toastLyricsDismissed = false
        onUpdate?()
    }

    private func hideHover(notify: Bool) {
        invalidateHoverTask()
        showsHoverChange = false
        showsHoverText = false
        if notify { onUpdate?() }
    }

    private func hidePluginStatus(notify: Bool) {
        invalidatePluginStatusTask()
        showsPluginStatus = false
        pluginStatusMessage = nil
        if notify { onUpdate?() }
    }

    private func invalidateTrackTask() {
        trackGeneration += 1
        trackTask?.cancel()
        trackTask = nil
    }

    private func invalidateHoverTask() {
        hoverGeneration += 1
        hoverTask?.cancel()
        hoverTask = nil
    }

    private func invalidatePluginStatusTask() {
        pluginStatusGeneration += 1
        pluginStatusTask?.cancel()
        pluginStatusTask = nil
    }
}
