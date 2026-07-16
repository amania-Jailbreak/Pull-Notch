import Foundation
import Observation

@MainActor
@Observable
final class TemporaryWidgetStore {
    typealias Sleep = @Sendable (TimeInterval) async -> Void

    @ObservationIgnored var onUpdate: (@MainActor () -> Void)?

    private(set) var widgets: [CompactWidgetPlacement: CompactIslandWidget] = [:]

    @ObservationIgnored private let sleep: Sleep
    @ObservationIgnored private var removalTasks: [CompactWidgetPlacement: Task<Void, Never>] = [:]
    @ObservationIgnored private var generations: [CompactWidgetPlacement: Int] = [:]

    init(sleep: @escaping Sleep = { duration in
        try? await Task.sleep(for: .seconds(duration))
    }) {
        self.sleep = sleep
    }

    deinit {
        for task in removalTasks.values {
            task.cancel()
        }
    }

    func set(_ widget: CompactIslandWidget) {
        let placement = widget.placement
        invalidateRemoval(for: placement)
        widgets[placement] = widget
        onUpdate?()
    }

    func present(_ widget: CompactIslandWidget, duration: TimeInterval) {
        let placement = widget.placement
        invalidateRemoval(for: placement)
        widgets[placement] = widget
        onUpdate?()

        let generation = generations[placement] ?? 0
        removalTasks[placement] = Task { @MainActor [weak self, sleep] in
            await sleep(max(0, duration))
            guard
                !Task.isCancelled,
                let self,
                self.generations[placement] == generation
            else {
                return
            }
            self.clear(placement: placement, identity: widget.identity)
        }
    }

    @discardableResult
    func clear(
        placement: CompactWidgetPlacement,
        identity: CompactWidgetIdentity? = nil
    ) -> Bool {
        guard let currentWidget = widgets[placement] else { return false }
        if let identity, currentWidget.identity != identity {
            return false
        }

        invalidateRemoval(for: placement)
        widgets[placement] = nil
        onUpdate?()
        return true
    }

    private func invalidateRemoval(for placement: CompactWidgetPlacement) {
        generations[placement, default: 0] += 1
        removalTasks[placement]?.cancel()
        removalTasks[placement] = nil
    }
}
