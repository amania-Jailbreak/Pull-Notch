import Foundation
import Observation

nonisolated enum PomodoroPhase: Sendable {
    case focus
    case `break`

    var title: String {
        switch self {
        case .focus: return "Focus Session"
        case .break: return "Break Time"
        }
    }

    var duration: Int {
        switch self {
        case .focus: return 25 * 60
        case .break: return 5 * 60
        }
    }

    var symbolName: String {
        switch self {
        case .focus: return "timer"
        case .break: return "cup.and.saucer.fill"
        }
    }

    var actionTitle: String {
        switch self {
        case .focus: return "Start Focus"
        case .break: return "Start Break"
        }
    }

    var next: PomodoroPhase {
        switch self {
        case .focus: return .break
        case .break: return .focus
        }
    }
}

@MainActor
@Observable
final class PomodoroModel {
    private(set) var phase: PomodoroPhase
    private(set) var remainingSeconds: Int
    private(set) var isRunning = false

    @ObservationIgnored var onUpdate: (() -> Void)?
    @ObservationIgnored var onPhaseTransition: (() -> Void)?

    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var phaseEndsAt: Date?
    @ObservationIgnored private let nowProvider: () -> Date

    init(
        phase: PomodoroPhase = .focus,
        remainingSeconds: Int? = nil,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.phase = phase
        self.remainingSeconds = remainingSeconds ?? phase.duration
        self.nowProvider = nowProvider
    }

    var timeText: String {
        let minutes = remainingSeconds / 60
        let seconds = remainingSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var progress: CGFloat {
        let duration = max(CGFloat(phase.duration), 1)
        let remaining = CGFloat(remainingSeconds)
        return max(0, min(1, 1 - (remaining / duration)))
    }

    func toggle() {
        isRunning ? pause() : start()
        onUpdate?()
    }

    func reset() {
        stopTimer(preservingRemainingTime: false)
        phase = .focus
        remainingSeconds = phase.duration
        onUpdate?()
    }

    func skip() {
        stopTimer(preservingRemainingTime: false)
        phase = phase.next
        remainingSeconds = phase.duration
        onUpdate?()
    }

    private func start() {
        timerTask?.cancel()
        isRunning = true
        phaseEndsAt = nowProvider().addingTimeInterval(TimeInterval(remainingSeconds))
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.isRunning else { return }
                self.synchronize(at: self.nowProvider())
            }
        }
    }

    private func pause() {
        stopTimer(preservingRemainingTime: true)
    }

    private func stopTimer(preservingRemainingTime: Bool) {
        if preservingRemainingTime, let phaseEndsAt {
            remainingSeconds = max(0, Int(ceil(phaseEndsAt.timeIntervalSince(nowProvider()))))
        }
        phaseEndsAt = nil
        isRunning = false
        timerTask?.cancel()
        timerTask = nil
    }

    func synchronize(at now: Date) {
        guard var phaseEndsAt else { return }

        var didTransition = false
        while now >= phaseEndsAt {
            phase = phase.next
            phaseEndsAt = phaseEndsAt.addingTimeInterval(TimeInterval(phase.duration))
            didTransition = true
        }

        self.phaseEndsAt = phaseEndsAt
        remainingSeconds = max(0, Int(ceil(phaseEndsAt.timeIntervalSince(now))))

        if didTransition {
            onPhaseTransition?()
        }
        onUpdate?()
    }
}
