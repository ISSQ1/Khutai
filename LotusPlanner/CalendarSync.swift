import EventKit
import Foundation
import SwiftUI

/// موعد من تقويم macOS بصيغة بسيطة يعرضها التطبيق.
struct CalendarAppointment: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarTitle: String
    let color: Color
    /// أُنشئ من خُطاي (في تقويم «خُطاي»)، فيمكن حذفه من داخل التطبيق.
    let isKhutai: Bool

    var durationMinutes: Int {
        max(0, Int(end.timeIntervalSince(start) / 60))
    }
}

/// تقويم يمكن اختياره من الإعدادات.
struct CalendarChoice: Identifiable, Hashable {
    let id: String
    let title: String
    let color: Color
}

/// لقطة من تذكير في تطبيق «التذكيرات» (قيم بسيطة آمنة للنقل بين الخيوط).
struct ReminderSnapshot: Sendable {
    let id: String
    let externalID: String?
    let title: String
    let notes: String
    let isCompleted: Bool
    let dueDate: Date?
    /// أوقات تنبيهات التذكير (لمعرفة إن احتاجت تحديثًا).
    let alarmDates: [Date]
}

/// الربط مع «التقويم» و«التذكيرات» في macOS عبر EventKit. كل شيء محلي على الجهاز.
@MainActor
final class CalendarService: ObservableObject {
    static let khutaiTitle = "خُطاي"

    @Published private(set) var eventsAuthorized = false
    @Published private(set) var remindersAuthorized = false

    private let eventStore = EKEventStore()

    init() {
        refreshAuthorization()
    }

    func refreshAuthorization() {
        eventsAuthorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        remindersAuthorized = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    func requestEventsAccess() async -> Bool {
        let granted: Bool = await withCheckedContinuation { continuation in
            eventStore.requestFullAccessToEvents { @Sendable (granted, _) in
                continuation.resume(returning: granted)
            }
        }
        refreshAuthorization()
        return granted
    }

    func requestRemindersAccess() async -> Bool {
        let granted: Bool = await withCheckedContinuation { continuation in
            eventStore.requestFullAccessToReminders { @Sendable (granted, _) in
                continuation.resume(returning: granted)
            }
        }
        refreshAuthorization()
        return granted
    }

    /// تُستدعى عند تغيّر قاعدة بيانات التقويم من خارج التطبيق.
    func resetCaches() {
        eventStore.reset()
        refreshAuthorization()
    }

    // MARK: - التقويم

    func availableCalendars() -> [CalendarChoice] {
        guard eventsAuthorized else { return [] }
        return eventStore.calendars(for: .event)
            .sorted { $0.title < $1.title }
            .map { CalendarChoice(id: $0.calendarIdentifier, title: $0.title, color: Color(cgColor: $0.cgColor)) }
    }

    /// مواعيد الفترة من التقاويم المختارة (والقائمة الفارغة تعني الكل)، مع تقويم «خُطاي» دائمًا.
    func appointments(from start: Date, to end: Date, calendarIDs: [String]) -> [CalendarAppointment] {
        guard eventsAuthorized, end > start else { return [] }
        let allCalendars = eventStore.calendars(for: .event)
        let selected = calendarIDs.isEmpty
            ? allCalendars
            : allCalendars.filter { calendarIDs.contains($0.calendarIdentifier) || $0.title == Self.khutaiTitle }
        guard !selected.isEmpty else { return [] }
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: selected)
        return eventStore.events(matching: predicate)
            .map { event in
                CalendarAppointment(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "موعد",
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    calendarTitle: event.calendar?.title ?? "",
                    color: event.calendar.map { Color(cgColor: $0.cgColor) } ?? .gray,
                    isKhutai: event.calendar?.title == Self.khutaiTitle
                )
            }
            .sorted { $0.start < $1.start }
    }

    /// يضيف موعدًا إلى تقويم «خُطاي» فيظهر أيضًا في تطبيق «التقويم» وعلى الهاتف.
    func addAppointment(
        title: String,
        start: Date,
        durationMinutes: Int,
        notes: String,
        recurrence: TaskRecurrence
    ) throws {
        guard eventsAuthorized else { throw CalendarServiceError.notAuthorized }
        let calendar = try khutaiEventCalendar()
        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(TimeInterval(max(5, durationMinutes) * 60))
        let cleanNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        event.notes = cleanNotes.isEmpty ? nil : cleanNotes
        switch recurrence {
        case .none: break
        case .weekly: event.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil))
        case .monthly: event.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil))
        }
        try eventStore.save(event, span: .futureEvents, commit: true)
    }

    /// يحذف هذا الموعد بعينه (وفي المواعيد المتكررة: هذه المرة فقط).
    func deleteAppointment(_ appointment: CalendarAppointment) throws {
        guard eventsAuthorized, appointment.isKhutai else { return }
        let calendars = eventStore.calendars(for: .event).filter { $0.title == Self.khutaiTitle }
        guard !calendars.isEmpty else { return }
        let predicate = eventStore.predicateForEvents(
            withStart: appointment.start.addingTimeInterval(-60),
            end: appointment.end.addingTimeInterval(60),
            calendars: calendars
        )
        guard let event = eventStore.events(matching: predicate).first(where: {
            $0.eventIdentifier == appointment.id && abs($0.startDate.timeIntervalSince(appointment.start)) < 1
        }) else { return }
        try eventStore.remove(event, span: .thisEvent, commit: true)
    }

    private func khutaiEventCalendar() throws -> EKCalendar {
        if let existing = eventStore.calendars(for: .event)
            .first(where: { $0.title == Self.khutaiTitle && $0.allowsContentModifications }) {
            return existing
        }
        let calendar = EKCalendar(for: .event, eventStore: eventStore)
        calendar.title = Self.khutaiTitle
        guard let source = eventStore.defaultCalendarForNewEvents?.source
            ?? eventStore.sources.first(where: { $0.sourceType == .local }) else {
            throw CalendarServiceError.noSource
        }
        calendar.source = source
        try eventStore.saveCalendar(calendar, commit: true)
        return calendar
    }

    // MARK: - التذكيرات

    /// يعيد nil إن تعذرت القراءة (وليس قائمة فارغة)، حتى لا تُفك روابط المهام خطأً.
    func fetchKhutaiReminders() async -> [ReminderSnapshot]? {
        guard remindersAuthorized, let list = try? khutaiReminderList() else { return nil }
        let predicate = eventStore.predicateForReminders(in: [list])
        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { @Sendable (reminders) in
                continuation.resume(returning: reminders.map(makeReminderSnapshots))
            }
        }
    }

    /// ينشئ تذكيرًا للمهمة الرئيسية أو يحدّثه، ويعيد معرّفه ومعرّفه الخارجي.
    /// `alarmDates` تنبيهات التذكير المطلوبة في التفاصيل، فتصل إلى الهاتف أيضًا.
    func upsertReminder(for task: PlannerTask, alarmDates: [Date]?) throws -> (id: String, externalID: String?) {
        guard remindersAuthorized else { throw CalendarServiceError.notAuthorized }
        let reminder: EKReminder
        if let id = task.reminderItemID, !id.isEmpty,
           let existing = eventStore.calendarItem(withIdentifier: id) as? EKReminder {
            reminder = existing
        } else {
            reminder = EKReminder(eventStore: eventStore)
            reminder.calendar = try khutaiReminderList()
        }
        reminder.title = task.title
        reminder.notes = task.trimmedNotes.isEmpty ? nil : task.trimmedNotes
        reminder.dueDateComponents = PlannerCalendar.current.dateComponents([.year, .month, .day], from: task.deadline)
        reminder.isCompleted = task.isDone
        // nil = لا نغيّر التنبيهات الموجودة.
        if let alarmDates {
            for alarm in reminder.alarms ?? [] {
                reminder.removeAlarm(alarm)
            }
            for date in alarmDates {
                reminder.addAlarm(EKAlarm(absoluteDate: date))
            }
        }
        try eventStore.save(reminder, commit: true)
        return (reminder.calendarItemIdentifier, reminder.calendarItemExternalIdentifier)
    }

    func removeReminder(id: String) {
        guard remindersAuthorized, !id.isEmpty,
              let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else { return }
        try? eventStore.remove(reminder, commit: true)
    }

    private func khutaiReminderList() throws -> EKCalendar {
        if let existing = eventStore.calendars(for: .reminder)
            .first(where: { $0.title == Self.khutaiTitle && $0.allowsContentModifications }) {
            return existing
        }
        let list = EKCalendar(for: .reminder, eventStore: eventStore)
        list.title = Self.khutaiTitle
        guard let source = eventStore.defaultCalendarForNewReminders()?.source
            ?? eventStore.sources.first(where: { $0.sourceType == .local }) else {
            throw CalendarServiceError.noSource
        }
        list.source = source
        try eventStore.saveCalendar(list, commit: true)
        return list
    }
}

enum CalendarServiceError: LocalizedError {
    case notAuthorized
    case noSource

    var errorDescription: String? {
        switch self {
        case .notAuthorized: "يلزم السماح لخُطاي بالوصول إلى التقويم أو التذكيرات من الإعدادات."
        case .noSource: "تعذر العثور على حساب تقويم لحفظ مواعيد خُطاي."
        }
    }
}

/// خارج نطاق MainActor لأنها تُستدعى من خيط EventKit.
private func makeReminderSnapshots(_ reminders: [EKReminder]) -> [ReminderSnapshot] {
    reminders.map { reminder in
        ReminderSnapshot(
            id: reminder.calendarItemIdentifier,
            externalID: reminder.calendarItemExternalIdentifier,
            title: reminder.title ?? "",
            notes: reminder.notes ?? "",
            isCompleted: reminder.isCompleted,
            dueDate: reminder.dueDateComponents.flatMap { PlannerCalendar.current.date(from: $0) },
            alarmDates: (reminder.alarms ?? []).compactMap(\.absoluteDate)
        )
    }
}
