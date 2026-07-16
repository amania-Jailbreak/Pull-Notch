import AppKit
import EventKit
import Foundation
import Observation

nonisolated private final class CalendarWidgetModelReference: @unchecked Sendable {
    weak var value: CalendarWidgetModel?

    init(_ value: CalendarWidgetModel) {
        self.value = value
    }
}

nonisolated enum CalendarAccessState: Equatable, Sendable {
    case notDetermined
    case requesting
    case authorized
    case denied
    case restricted
}

nonisolated struct CalendarEventItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let calendarTitle: String
}

@MainActor
@Observable
final class CalendarWidgetModel {
    private(set) var accessState: CalendarAccessState
    private(set) var events: [CalendarEventItem] = []
    private(set) var displayedMonth: Date
    private(set) var selectedDate: Date
    private(set) var errorMessage: String?

    @ObservationIgnored private let eventStore: EKEventStore
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var hasPrepared = false

    init(eventStore: EKEventStore = EKEventStore(), calendar: Calendar = .autoupdatingCurrent) {
        self.eventStore = eventStore
        self.calendar = calendar
        let today = calendar.startOfDay(for: Date())
        selectedDate = today
        displayedMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
        accessState = Self.accessState(for: EKEventStore.authorizationStatus(for: .event))
        let weakReference = CalendarWidgetModelReference(self)

        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: eventStore,
                queue: .main
            ) { _ in
                Task { @MainActor in weakReference.value?.refresh() }
            }
        )
        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    weakReference.value?.refreshAuthorizationState()
                    weakReference.value?.refresh()
                }
            }
        )
        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: .NSCalendarDayChanged,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in weakReference.value?.handleDayChange() }
            }
        )
    }

    deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    var monthTitle: String {
        displayedMonth.formatted(.dateTime.year().month(.wide))
    }

    var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard !symbols.isEmpty else { return [] }
        let firstIndex = max(0, min(symbols.count - 1, calendar.firstWeekday - 1))
        return Array(symbols[firstIndex...] + symbols[..<firstIndex])
    }

    var monthGridDates: [Date?] {
        guard let monthRange = calendar.range(of: .day, in: .month, for: displayedMonth) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: displayedMonth)
        let leadingEmptyCount = (firstWeekday - calendar.firstWeekday + 7) % 7
        var dates = Array<Date?>(repeating: nil, count: leadingEmptyCount)
        dates.append(contentsOf: monthRange.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: displayedMonth)
        }.map(Optional.some))
        while dates.count < 42 { dates.append(nil) }
        return Array(dates.prefix(42))
    }

    var todayEvents: [CalendarEventItem] {
        events(on: Date()).prefix(3).map { $0 }
    }

    var selectedDateEvents: [CalendarEventItem] {
        events(on: selectedDate)
    }

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
        guard accessState == .notDetermined || accessState == .denied else { return }
        if accessState == .denied {
            openSystemSettings()
            return
        }
        accessState = .requesting
        do {
            _ = try await eventStore.requestFullAccessToEvents()
            refreshAuthorizationState()
            refresh()
        } catch {
            refreshAuthorizationState()
            errorMessage = error.localizedDescription
        }
    }

    func refresh() {
        guard accessState == .authorized else {
            events = []
            return
        }
        guard let interval = visibleFetchInterval else { return }
        let predicate = eventStore.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        events = eventStore.events(matching: predicate)
            .map {
                CalendarEventItem(
                    id: $0.eventIdentifier ?? "\($0.calendarItemIdentifier)-\($0.startDate.timeIntervalSince1970)",
                    title: $0.title?.isEmpty == false ? $0.title! : "Untitled Event",
                    startDate: $0.startDate,
                    endDate: $0.endDate,
                    isAllDay: $0.isAllDay,
                    calendarTitle: $0.calendar.title
                )
            }
            .sorted {
                if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
                return $0.startDate < $1.startDate
            }
        errorMessage = nil
    }

    func moveMonth(by value: Int) {
        guard let next = calendar.date(byAdding: .month, value: value, to: displayedMonth),
              let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: next)) else { return }
        displayedMonth = monthStart
        selectedDate = monthStart
        refresh()
    }

    func select(date: Date) {
        selectedDate = calendar.startOfDay(for: date)
    }

    func hasEvents(on date: Date) -> Bool {
        !events(on: date).isEmpty
    }

    func isToday(_ date: Date) -> Bool { calendar.isDateInToday(date) }
    func isSelected(_ date: Date) -> Bool { calendar.isDate(date, inSameDayAs: selectedDate) }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else { return }
        NSWorkspace.shared.open(url)
    }

    private var visibleFetchInterval: DateInterval? {
        guard let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth),
              let start = calendar.date(byAdding: .day, value: -7, to: monthInterval.start),
              let end = calendar.date(byAdding: .day, value: 7, to: monthInterval.end) else { return nil }
        let today = calendar.startOfDay(for: Date())
        let todayEnd = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        return DateInterval(start: min(start, today), end: max(end, todayEnd))
    }

    private func events(on date: Date) -> [CalendarEventItem] {
        guard let dayInterval = calendar.dateInterval(of: .day, for: date) else { return [] }
        return events.filter { event in
            event.startDate < dayInterval.end && event.endDate > dayInterval.start
        }
    }

    private func refreshAuthorizationState() {
        accessState = Self.accessState(for: EKEventStore.authorizationStatus(for: .event))
    }

    private func handleDayChange() {
        selectedDate = calendar.startOfDay(for: Date())
        displayedMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: selectedDate)) ?? selectedDate
        refresh()
    }

    private static func accessState(for status: EKAuthorizationStatus) -> CalendarAccessState {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied, .writeOnly: return .denied
        case .authorized, .fullAccess: return .authorized
        @unknown default: return .denied
        }
    }
}
