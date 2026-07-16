import Foundation
import Observation

@MainActor
@Observable
final class VolumeOverlayModel {
    typealias Sleep = @Sendable (TimeInterval) async -> Void

    @ObservationIgnored var onUpdate: (@MainActor () -> Void)?

    private(set) var isVisible = false
    private(set) var level: Double = 0
    private(set) var outputDeviceName: String?

    @ObservationIgnored private let sleep: Sleep
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var presentationGeneration = 0

    init(sleep: @escaping Sleep = { duration in
        try? await Task.sleep(for: .seconds(duration))
    }) {
        self.sleep = sleep
    }

    deinit {
        hideTask?.cancel()
    }

    func show(
        level: Double,
        outputDeviceName: String?,
        duration: TimeInterval = 2.6
    ) {
        presentationGeneration += 1
        let generation = presentationGeneration
        hideTask?.cancel()

        self.level = max(0, min(1, level))
        let trimmedDeviceName = outputDeviceName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.outputDeviceName = trimmedDeviceName?.isEmpty == false ? trimmedDeviceName : nil
        isVisible = true
        onUpdate?()

        hideTask = Task { @MainActor [weak self, sleep] in
            await sleep(max(0, duration))
            guard
                !Task.isCancelled,
                let self,
                self.presentationGeneration == generation
            else {
                return
            }
            self.dismiss()
        }
    }

    func dismiss(resetLevel: Bool = false) {
        presentationGeneration += 1
        hideTask?.cancel()
        hideTask = nil
        isVisible = false
        outputDeviceName = nil
        if resetLevel {
            level = 0
        }
        onUpdate?()
    }
}
