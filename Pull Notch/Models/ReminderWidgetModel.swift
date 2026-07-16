import AppKit
@preconcurrency import EventKit
import Foundation
import Observation

nonisolated enum ReminderAccessState: Equatable, Sendable {
    case notDetermined
    case requesting
    case authorized
    case denied
    case restricted
}

nonisolated struct ReminderListItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
}

nonisolated struct ReminderWidgetItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let dueDate: Date
    let listTitle: String
    let isOverdue: Bool
}

nonisolated private final class ReminderWidgetModelReference: @unchecked Sendable {
    weak var value: ReminderWidgetModel?
    init(_ value: ReminderWidgetModel) { self.value = value }
}

nonisolated private final class ReminderFetchBatch: @unchecked Sendable {
    let reminders: [EKReminder]
    let generation: Int
    init(_ reminders: [EKReminder], generation: Int) {
        self.reminders = reminders
        self.generation = generation
    }
}

@MainActor
@Observable
final class ReminderWidgetModel {
    private enum Key {
        static let selectedListIDs = "PullNotch.reminders.selectedListIDs"
        static let hasCustomizedLists = "PullNotch.reminders.hasCustomizedLists"
    }

    private(set) var accessState: ReminderAccessState
    private(set) var lists: [ReminderListItem] = []
    private(set) var selectedListIDs: Set<String>
    private(set) var items: [ReminderWidgetItem] = []
    private(set) var errorMessage: String?
    private(set) var isLoading = false

    @ObservationIgnored var onUpdate: (@MainActor () -> Void)?

    @ObservationIgnored private let eventStore: EKEventStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var reminderByID: [String: EKReminder] = [:]
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var hasPrepared = false
    @ObservationIgnored private var hasCustomizedLists: Bool
    @ObservationIgnored private var fetchGeneration = 0

    init(
        eventStore: EKEventStore = EKEventStore(),
        defaults: UserDefaults = .standard,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.eventStore = eventStore
        self.defaults = defaults
        self.calendar = calendar
        selectedListIDs = Set(defaults.stringArray(forKey: Key.selectedListIDs) ?? [])
        hasCustomizedLists = defaults.bool(forKey: Key.hasCustomizedLists)
        accessState = Self.accessState(for: EKEventStore.authorizationStatus(for: .reminder))

        let reference = ReminderWidgetModelReference(self)
        notificationTokens.append(
            NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: eventStore, queue: .main) { _ in
                Task { @MainActor in reference.value?.refresh() }
            }
        )
        notificationTokens.append(
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    reference.value?.refreshAuthorizationState()
                    reference.value?.refresh()
                }
            }
        )
        notificationTokens.append(
            NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { _ in
                Task { @MainActor in reference.value?.refresh() }
            }
        )
    }

    deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    var overdueCount: Int { items.lazy.filter(\.isOverdue).count }
    var remainingCount: Int { items.count }

    func prepareIfNeeded() async {
        guard !hasPrepared else { return }
        hasPrepared = true
        refreshAuthorizationState()
        if accessState == .notDetermined {
            await requestAccess()
        } else {
            refresh()
        }
    }

    func requestAccess() async {
        refreshAuthorizationState()
        if accessState == .denied || accessState == .restricted {
            openSystemSettings()
            return
        }
        guard accessState == .notDetermined else {
            refresh()
            return
        }

        accessState = .requesting
        onUpdate?()
        do {
            _ = try await eventStore.requestFullAccessToReminders()
            refreshAuthorizationState()
            refresh()
        } catch {
            refreshAuthorizationState()
            errorMessage = error.localizedDescription
            onUpdate?()
        }
    }

    func refresh() {
        fetchGeneration += 1
        let generation = fetchGeneration
        refreshAuthorizationState()
        guard accessState == .authorized else {
            lists = []
            items = []
            reminderByID = [:]
            isLoading = false
            onUpdate?()
            return
        }

        refreshLists()
        let selectedCalendars = eventStore.calendars(for: .reminder).filter {
            selectedListIDs.contains($0.calendarIdentifier)
        }
        guard !selectedCalendars.isEmpty else {
            items = []
            reminderByID = [:]
            isLoading = false
            errorMessage = nil
            onUpdate?()
            return
        }

        isLoading = true
        onUpdate?()
        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: endOfToday,
            calendars: selectedCalendars
        )
        let reference = ReminderWidgetModelReference(self)
        eventStore.fetchReminders(matching: predicate) { reminders in
            let batch = ReminderFetchBatch(reminders ?? [], generation: generation)
            Task { @MainActor in
                reference.value?.apply(batch)
            }
        }
    }

    func setListEnabled(id: String, isEnabled: Bool) {
        hasCustomizedLists = true
        defaults.set(true, forKey: Key.hasCustomizedLists)
        if isEnabled {
            selectedListIDs.insert(id)
        } else {
            selectedListIDs.remove(id)
        }
        defaults.set(Array(selectedListIDs).sorted(), forKey: Key.selectedListIDs)
        refresh()
    }

    func isListEnabled(id: String) -> Bool {
        selectedListIDs.contains(id)
    }

    func complete(id: String) {
        guard let reminder = reminderByID[id] else { return }
        do {
            reminder.isCompleted = true
            reminder.completionDate = Date()
            try eventStore.save(reminder, commit: true)
            errorMessage = nil
            refresh()
        } catch {
            reminder.isCompleted = false
            reminder.completionDate = nil
            errorMessage = "Could not complete task: \(error.localizedDescription)"
            onUpdate?()
        }
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") else { return }
        NSWorkspace.shared.open(url)
    }

    private var endOfToday: Date {
        let today = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: 1, to: today) ?? Date()
    }

    private func refreshLists() {
        let available = eventStore.calendars(for: .reminder)
            .map { ReminderListItem(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let availableIDs = Set(available.map(\.id))

        if hasCustomizedLists {
            let normalized = selectedListIDs.intersection(availableIDs)
            if normalized != selectedListIDs {
                selectedListIDs = normalized
                defaults.set(Array(normalized).sorted(), forKey: Key.selectedListIDs)
            }
        } else {
            selectedListIDs = availableIDs
        }
        lists = available
    }

    private func apply(_ batch: ReminderFetchBatch) {
        guard batch.generation == fetchGeneration else { return }
        let startOfToday = calendar.startOfDay(for: Date())
        var references: [String: EKReminder] = [:]
        let mapped = batch.reminders.compactMap { reminder -> ReminderWidgetItem? in
            guard !reminder.isCompleted,
                  let dueDate = reminder.dueDateComponents?.date,
                  dueDate < endOfToday else { return nil }
            let id = reminder.calendarItemIdentifier
            references[id] = reminder
            return ReminderWidgetItem(
                id: id,
                title: reminder.title?.isEmpty == false ? reminder.title! : "Untitled Reminder",
                dueDate: dueDate,
                listTitle: reminder.calendar.title,
                isOverdue: dueDate < startOfToday
            )
        }
        items = mapped.sorted {
            if $0.isOverdue != $1.isOverdue { return $0.isOverdue }
            if $0.dueDate != $1.dueDate { return $0.dueDate < $1.dueDate }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        reminderByID = references
        isLoading = false
        errorMessage = nil
        onUpdate?()
    }

    private func refreshAuthorizationState() {
        accessState = Self.accessState(for: EKEventStore.authorizationStatus(for: .reminder))
    }

    private static func accessState(for status: EKAuthorizationStatus) -> ReminderAccessState {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied, .writeOnly: return .denied
        case .authorized, .fullAccess: return .authorized
        @unknown default: return .denied
        }
    }
}
