import Combine
import Foundation
import WidgetKit

/// خطوات يوم واحد مجمّعة تحت مهمتها الأم، حتى لا تختلط خطوات المهام ببعضها.
struct DayTaskGroup: Identifiable {
    let task: PlannerTask
    let steps: [PlannerSubtask]

    var id: UUID { task.id }
}

/// مهمة رئيسية مقترح العمل عليها اليوم.
struct FocusItem: Identifiable {
    let task: PlannerTask
    let info: TaskScheduleInfo

    var id: UUID { task.id }
}

@MainActor
final class PlannerStore: ObservableObject {
    @Published private(set) var tasks: [PlannerTask] = []
    @Published private(set) var dailyPlan: DailyPlan?
    @Published private(set) var storedAchievements: [PlannerAchievement] = []
    @Published private(set) var isPlanning = false
    @Published private(set) var connectionMessage: String?
    @Published private(set) var theme: PlannerTheme = .lotus
    @Published private(set) var settings = PlannerSettings()
    /// اقتراحات الجدولة لكل مهمة رئيسية (تُحسب ولا تُحفظ).
    @Published private(set) var scheduleInfo: [UUID: TaskScheduleInfo] = [:]
    /// مواعيد التقويم مجمّعة بحسب اليوم (yyyy-MM-dd).
    @Published private(set) var appointmentsByDay: [String: [CalendarAppointment]] = [:]
    @Published var calendarMessage: String?
    /// هل أداة المساعد المختارة مثبتة؟ (تُفحص عند التغيير لا عند كل رسم).
    @Published private(set) var isConnected = false
    /// فهرس المواعيد النهائية بحسب اليوم، لرسم التقويم بسرعة.
    private var deadlineIndex: [String: [PlannerTask]] = [:]
    /// تذكيرات حُذفت مهامها في هذه الجلسة، حتى لا تُستورد من جديد.
    private var removedReminderIDs: Set<String> = []
    /// وقت تنبيه كل موعد يُثبَّت أول مرة، فلا يتكرر التنبيه عند إعادة الحساب.
    private var appointmentFireDates: [String: Date] = [:]
    /// أول جدولة بعد التشغيل لا تضيف تنبيهات متأخرة (قد تكون أُرسلت قبل الإغلاق).
    private var hasScheduledNotifications = false

    let calendarService: CalendarService
    private var appointmentFocusMonth = Date()
    private var reminderSyncTask: Task<Void, Never>?
    private var isSyncingReminders = false

    init(calendarService: CalendarService) {
        self.calendarService = calendarService
        theme = PlannerStorage.loadTheme()
        settings = PlannerStorage.loadSettings()
        tasks = PlannerStorage.loadTasks()
        dailyPlan = PlannerStorage.loadDailyPlan()
        storedAchievements = PlannerStorage.loadAchievements()
        migrateLegacyPlanIntoSubtasks()
        markExistingBreakdownsAsInterpreted()
        restoreMissingCompletionDates()
        restoreStoredAchievements()
        refreshAssistantAvailability()
        recompute()
    }

    private func refreshAssistantAvailability() {
        let available = PlannerAssistant.isAvailable(settings.provider)
        if available != isConnected { isConnected = available }
    }

    var providerName: String {
        settings.provider == .codex ? "Codex" : "Claude"
    }

    // MARK: - الإعدادات

    func updateSettings(_ newSettings: PlannerSettings) {
        let oldSettings = settings
        guard newSettings != oldSettings else { return }
        settings = newSettings
        PlannerStorage.saveSettings(newSettings)
        refreshAssistantAvailability()
        if newSettings.appointmentLeadMinutes != oldSettings.appointmentLeadMinutes {
            appointmentFireDates = [:]
        }
        // وقت التذكيرات أو تفعيلها تغيّر: تُحدَّث التنبيهات في «التذكيرات» أيضًا.
        if newSettings.reminderTimeMinutes != oldSettings.reminderTimeMinutes
            || newSettings.deadlineRemindersEnabled != oldSettings.deadlineRemindersEnabled
            || newSettings.notificationsEnabled != oldSettings.notificationsEnabled {
            scheduleReminderSync()
        }
        if newSettings.notificationsEnabled && !oldSettings.notificationsEnabled {
            NotificationService.shared.activate()
        }
        recompute()
    }

    /// يمسح كل المهام والخطوات والسجل ويبدأ من جديد (السمة والإعدادات تبقى).
    /// مواعيد «التقويم» وعناصر «التذكيرات» لا تُمس.
    func resetAllData() {
        reminderSyncTask?.cancel()
        // نوقف مزامنة «التذكيرات» حتى لا تعود العناصر القديمة كمهام جديدة.
        // نتجاهل تذكيرات المهام الممسوحة إن فُعّلت المزامنة لاحقًا، فلا تعود كمهام.
        let linkedReminderIDs = tasks.flatMap { [$0.reminderItemID, $0.reminderExternalID] }
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        if settings.remindersSyncEnabled || !linkedReminderIDs.isEmpty {
            var newSettings = settings
            newSettings.remindersSyncEnabled = false
            newSettings.ignoredReminderIDs = Array(Set(newSettings.ignoredReminderIDs + linkedReminderIDs))
            settings = newSettings
            PlannerStorage.saveSettings(newSettings)
        }
        PlannerStorage.resetAllTaskData()
        tasks = []
        storedAchievements = []
        dailyPlan = nil
        connectionMessage = nil
        PlannerStorage.saveTasks(tasks)
        recompute()
    }

    /// يطلب إذن التقويم ثم يفعّل عرض المواعيد.
    func enableCalendar() async {
        var granted = calendarService.eventsAuthorized
        if !granted {
            granted = await calendarService.requestEventsAccess()
        }
        var newSettings = settings
        newSettings.calendarSyncEnabled = granted
        calendarMessage = granted ? nil : "لم يُمنح الإذن. يمكن السماح من إعدادات النظام ← الخصوصية والأمان ← التقاويم."
        updateSettings(newSettings)
        recompute()
    }

    /// يطلب إذن التذكيرات ثم يفعّل المزامنة مع قائمة «خُطاي».
    func enableReminders() async {
        var granted = calendarService.remindersAuthorized
        if !granted {
            granted = await calendarService.requestRemindersAccess()
        }
        var newSettings = settings
        newSettings.remindersSyncEnabled = granted
        calendarMessage = granted ? nil : "لم يُمنح الإذن. يمكن السماح من إعدادات النظام ← الخصوصية والأمان ← التذكيرات."
        updateSettings(newSettings)
        if granted { await syncReminders() }
    }

    /// يبدّل سمة الألوان ويحفظها، ثم يُحدّث الودجت ليطابق التطبيق.
    func toggleTheme() {
        theme = theme.next
        PlannerStorage.saveTheme(theme)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - المهام الرئيسية

    var pendingTasks: [PlannerTask] {
        let calendar = PlannerCalendar.current
        return tasks
            .filter { !$0.isDone }
            .sorted { lhs, rhs in
                if calendar.isDateInToday(lhs.deadline) != calendar.isDateInToday(rhs.deadline) {
                    return calendar.isDateInToday(lhs.deadline)
                }
                return lhs.deadline < rhs.deadline
            }
    }

    /// المهام الظاهرة في القائمة النشطة. المنجزة تختفي من هنا بعد يوم،
    /// لكنها تبقى محفوظة في السجل ولا تُحذف تلقائيًا أبدًا.
    func visibleTasks(at date: Date) -> [PlannerTask] {
        tasks
            .filter { $0.isVisible(at: date) }
            .sorted { $0.deadline < $1.deadline }
    }

    func task(withID id: UUID) -> PlannerTask? {
        tasks.first { $0.id == id }
    }

    func add(title: String, notes: String, deadline: Date, category: TaskCategory, priority: TaskPriority = .normal) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }

        tasks.append(
            PlannerTask(
                title: cleanTitle,
                deadline: deadline,
                category: category,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                priority: priority
            )
        )
        persist()
    }

    func toggle(_ task: PlannerTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        setCompletion(at: index, done: !tasks[index].isDone)
        persist()
    }

    /// نقل المهمة بين «الدوام» و«خارج الدوام» في أي وقت.
    func setCategory(_ category: TaskCategory, for taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }),
              tasks[index].category != category else { return }
        tasks[index].category = category
        persist()
    }

    private func setCompletion(at index: Int, done: Bool, completedAt: Date = .now) {
        guard tasks[index].isDone != done else { return }
        tasks[index].isDone = done
        tasks[index].completedAt = done ? completedAt : nil
        if !done { tasks[index].startReminderDateKey = nil }
        syncAchievement(for: tasks[index])
        if done { spawnNextOccurrenceIfNeeded(afterTaskAt: index) }
    }

    /// المهمة المتكررة: عند إنجازها تُنشأ نسختها التالية بموعد جديد،
    /// بخطوات غير منجزة، وتبقى المنجزة في السجل.
    private func spawnNextOccurrenceIfNeeded(afterTaskAt index: Int) {
        let task = tasks[index]
        guard task.recurrence != .none, task.nextOccurrenceID == nil else { return }
        let calendar = PlannerCalendar.current
        let component: Calendar.Component = task.recurrence == .weekly ? .weekOfYear : .month
        guard let nextDeadline = calendar.date(byAdding: component, value: 1, to: task.deadline) else { return }
        let shiftedSteps = task.subtasks.map { step in
            PlannerSubtask(
                title: step.title,
                note: step.note,
                estimatedMinutes: step.estimatedMinutes,
                scheduledDate: step.scheduledDate
                    .flatMap(PlannerStorage.date(fromKey:))
                    .flatMap { calendar.date(byAdding: component, value: 1, to: $0) }
                    .map(PlannerStorage.dateKey(for:)),
                fromNotes: step.fromNotes
            )
        }
        var next = PlannerTask(
            title: task.title,
            deadline: nextDeadline,
            category: task.category,
            notes: task.notes,
            subtasks: shiftedSteps,
            planning: task.planning.map { planning in
                var copy = planning
                copy.earliestStart = nil
                return copy
            },
            reminders: task.reminders.map { reminder in
                TaskReminder(
                    label: reminder.label,
                    minutesBeforeDeadline: reminder.minutesBeforeDeadline,
                    dateTime: reminder.dateTime.flatMap { Self.shiftReminderDateTime($0, by: component) }
                )
            },
            interpretedNotes: task.interpretedNotes ?? task.trimmedNotes,
            priority: task.priority,
            recurrence: task.recurrence
        )
        next.interpretedNotes = task.trimmedNotes
        tasks[index].nextOccurrenceID = next.id
        tasks.append(next)
    }

    private static func shiftReminderDateTime(_ text: String, by component: Calendar.Component) -> String? {
        let formatter = DateFormatter()
        formatter.calendar = PlannerCalendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        guard let date = formatter.date(from: text),
              let shifted = PlannerCalendar.current.date(byAdding: component, value: 1, to: date) else { return nil }
        return formatter.string(from: shifted)
    }

    /// يحدّث الحقول القابلة للتعديل فقط، حتى لا يكتب محرر مفتوح منذ مدة
    /// نسخة قديمة فوق خطوات وُلدت أو أُنجزت في أثناء ذلك.
    func update(_ updatedTask: PlannerTask) {
        guard let index = tasks.firstIndex(where: { $0.id == updatedTask.id }) else { return }
        if tasks[index].deadline != updatedTask.deadline || tasks[index].priority != updatedTask.priority {
            tasks[index].startReminderDateKey = nil
        }
        tasks[index].title = updatedTask.title
        tasks[index].notes = updatedTask.notes
        tasks[index].deadline = updatedTask.deadline
        tasks[index].category = updatedTask.category
        tasks[index].priority = updatedTask.priority
        tasks[index].recurrence = updatedTask.recurrence
        // إن مُسحت التفاصيل تُمسح معها الطلبات المستخرجة منها.
        if tasks[index].trimmedNotes.isEmpty {
            tasks[index].planning = nil
            tasks[index].reminders = []
            tasks[index].interpretedNotes = ""
        }
        syncAchievement(for: tasks[index])
        persist()

        // إن تغيّرت التفاصيل تُقرأ من جديد كتعليمات لهذه المهمة وحدها.
        let task = tasks[index]
        if task.needsInterpretation, isConnected {
            Task { await runAssistant(for: [task], mode: .interpretNotes) }
        }
    }

    /// الحذف لا يحدث إلا بطلب صريح من المستخدمة.
    func delete(_ task: PlannerTask) {
        if let reminderID = task.reminderItemID, !reminderID.isEmpty {
            removedReminderIDs.insert(reminderID)
            calendarService.removeReminder(id: reminderID)
        }
        tasks.removeAll { $0.id == task.id }
        removeAchievement(taskID: task.id.uuidString)
        persist()
    }

    // MARK: - الخطوات الفرعية

    /// خطوات يوم معيّن مجمّعة بحسب المهمة الأم.
    func dayGroups(on date: Date) -> [DayTaskGroup] {
        let dateKey = PlannerStorage.dateKey(for: date)
        return tasks
            .compactMap { task -> DayTaskGroup? in
                let steps = task.subtasks.filter { $0.scheduledDate == dateKey }
                return steps.isEmpty ? nil : DayTaskGroup(task: task, steps: steps)
            }
            .sorted { $0.task.deadline < $1.task.deadline }
    }

    func plannedSteps(on date: Date) -> [PlannerSubtask] {
        dayGroups(on: date).flatMap(\.steps)
    }

    /// تأشير خطوة. إن كانت آخر خطوة غير منجزة في المهمة تكتمل المهمة الأم معها.
    /// (الإكمال التلقائي يحدث هنا فقط، فلا يُعاد إكمال مهمة ألغت المستخدمة إنجازها.)
    func toggleSubtask(_ subtaskID: UUID, in taskID: UUID) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }),
              let subtaskIndex = tasks[taskIndex].subtasks.firstIndex(where: { $0.id == subtaskID }) else { return }
        tasks[taskIndex].subtasks[subtaskIndex].isDone.toggle()
        let isNowDone = tasks[taskIndex].subtasks[subtaskIndex].isDone
        tasks[taskIndex].subtasks[subtaskIndex].completedAt = isNowDone ? .now : nil
        if isNowDone, !tasks[taskIndex].isDone, tasks[taskIndex].subtasks.allSatisfy(\.isDone) {
            setCompletion(at: taskIndex, done: true)
        }
        persist()
    }

    func updateSubtask(_ updatedSubtask: PlannerSubtask, in taskID: UUID) {
        modifySubtask(updatedSubtask.id, in: taskID) { subtask in
            subtask = updatedSubtask
        }
    }

    func addSubtask(to taskID: UUID, title: String, scheduledDate: Date?) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty,
              let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].subtasks.append(
            PlannerSubtask(
                title: cleanTitle,
                scheduledDate: scheduledDate.map(PlannerStorage.dateKey(for:))
            )
        )
        persist()
    }

    func deleteSubtask(_ subtaskID: UUID, from taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].subtasks.removeAll { $0.id == subtaskID }
        persist()
    }

    private func modifySubtask(_ subtaskID: UUID, in taskID: UUID, change: (inout PlannerSubtask) -> Void) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }),
              let subtaskIndex = tasks[taskIndex].subtasks.firstIndex(where: { $0.id == subtaskID }) else { return }
        change(&tasks[taskIndex].subtasks[subtaskIndex])
        persist()
    }

    /// خطوات حُدد لها يوم مضى ولم تُنجز بعد (لا تُنقل تلقائيًا).
    var overdueStepGroups: [DayTaskGroup] {
        let todayKey = PlannerStorage.dateKey(for: .now)
        return tasks
            .filter { !$0.isDone }
            .compactMap { task -> DayTaskGroup? in
                let steps = task.subtasks.filter { !$0.isDone && ($0.scheduledDate ?? "9999-99-99") < todayKey }
                return steps.isEmpty ? nil : DayTaskGroup(task: task, steps: steps)
            }
            .sorted { $0.task.deadline < $1.task.deadline }
    }

    /// ينقل خطوة إلى يوم آخر، أو يزيل يومها إن كان nil. بطلب صريح فقط.
    func reschedule(stepID: UUID, in taskID: UUID, to date: Date?) {
        modifySubtask(stepID, in: taskID) { subtask in
            subtask.scheduledDate = date.map(PlannerStorage.dateKey(for:))
        }
    }

    /// تُستدعى عند عودة التطبيق للواجهة، لتحديث العرض إن تغيّر اليوم.
    func refreshOnActivate() {
        refreshAssistantAvailability()
        recompute()
        scheduleReminderSync()
    }

    // MARK: - الجدولة المقترحة

    func info(for task: PlannerTask) -> TaskScheduleInfo? {
        scheduleInfo[task.id]
    }

    /// المهام الرئيسية التي حان وقت العمل عليها اليوم بحسب الجدولة المقترحة.
    var focusItems: [FocusItem] {
        let todayKey = PlannerStorage.dateKey(for: .now)
        return pendingTasks.compactMap { task -> FocusItem? in
            guard let info = scheduleInfo[task.id],
                  let start = info.startDateKey, start <= todayKey else { return nil }
            return FocusItem(task: task, info: info)
        }
    }

    var atRiskItems: [FocusItem] {
        pendingTasks.compactMap { task -> FocusItem? in
            guard let info = scheduleInfo[task.id], info.isAtRisk else { return nil }
            return FocusItem(task: task, info: info)
        }
    }

    /// حمل اليوم المقترح بالدقائق: العمل المقترح + الخطوات المحددة لليوم + المواعيد.
    var todayLoadMinutes: Int {
        let suggested = scheduleInfo.values.reduce(0) { $0 + $1.todayMinutes }
        let steps = plannedSteps(on: .now).filter { !$0.isDone }.compactMap(\.estimatedMinutes).reduce(0, +)
        let busy = appointments(on: .now).filter { !$0.isAllDay }.reduce(0) { $0 + $1.durationMinutes }
        return suggested + steps + busy
    }

    var todayCapacityMinutes: Int {
        settings.workCapacityMinutes + settings.personalCapacityMinutes
    }

    var isTodayOverloaded: Bool {
        todayLoadMinutes > todayCapacityMinutes
    }

    // MARK: - المواعيد (التقويم)

    func appointments(on date: Date) -> [CalendarAppointment] {
        guard settings.calendarSyncEnabled else { return [] }
        return appointmentsByDay[PlannerStorage.dateKey(for: date)] ?? []
    }

    /// يحمّل مواعيد الشهر المعروض في التقويم إضافة إلى الأسابيع القادمة.
    func focusAppointments(onMonthOf date: Date) {
        appointmentFocusMonth = date
        refreshAppointments()
    }

    func addAppointment(title: String, start: Date, durationMinutes: Int, notes: String, recurrence: TaskRecurrence) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        do {
            try calendarService.addAppointment(
                title: cleanTitle,
                start: start,
                durationMinutes: durationMinutes,
                notes: notes,
                recurrence: recurrence
            )
            calendarMessage = nil
        } catch {
            calendarMessage = error.localizedDescription
        }
        recompute()
    }

    func deleteAppointment(_ appointment: CalendarAppointment) {
        do {
            try calendarService.deleteAppointment(appointment)
        } catch {
            calendarMessage = error.localizedDescription
        }
        recompute()
    }

    /// تغيّرت قاعدة بيانات التقويم أو التذكيرات (من التطبيق أو من خارجه).
    func calendarStoreDidChange() {
        calendarService.resetCaches()
        recompute()
        scheduleReminderSync()
    }

    private func refreshAppointments() {
        guard settings.calendarSyncEnabled, calendarService.eventsAuthorized else {
            if !appointmentsByDay.isEmpty { appointmentsByDay = [:] }
            return
        }
        let calendar = PlannerCalendar.current
        let today = calendar.startOfDay(for: .now)
        let monthStart = calendar.dateInterval(of: .month, for: appointmentFocusMonth)?.start ?? today
        // نافذتان منفصلتان: الأيام القادمة (للجدولة والإشعارات) والشهر المعروض في التقويم.
        let windows = [
            (calendar.date(byAdding: .day, value: -1, to: today) ?? today,
             calendar.date(byAdding: .day, value: 60, to: today) ?? today),
            (calendar.date(byAdding: .day, value: -7, to: monthStart) ?? monthStart,
             calendar.date(byAdding: .day, value: 45, to: monthStart) ?? monthStart)
        ]
        var fetched: [CalendarAppointment] = []
        var seenOccurrences = Set<String>()
        for (start, end) in windows {
            for appointment in calendarService.appointments(from: start, to: end, calendarIDs: settings.selectedCalendarIDs) {
                let key = "\(appointment.id)|\(appointment.start.timeIntervalSince1970)"
                if seenOccurrences.insert(key).inserted { fetched.append(appointment) }
            }
        }

        var grouped: [String: [CalendarAppointment]] = [:]
        for appointment in fetched.sorted(by: { $0.start < $1.start }) {
            // الموعد الممتد لعدة أيام يظهر في كل يوم منها (حتى أسبوع).
            var day = calendar.startOfDay(for: appointment.start)
            var count = 0
            repeat {
                grouped[PlannerStorage.dateKey(for: day), default: []].append(appointment)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
                count += 1
            } while day < appointment.end && count < 7
        }
        if grouped != appointmentsByDay { appointmentsByDay = grouped }
    }

    // MARK: - إعادة الحساب

    /// يعيد حساب الجدولة والإشعارات والودجت من البيانات الحالية.
    func recompute() {
        refreshAppointments()

        var index: [String: [PlannerTask]] = [:]
        for task in tasks {
            index[PlannerStorage.dateKey(for: task.deadline), default: []].append(task)
        }
        deadlineIndex = index.mapValues { $0.sorted { $0.title < $1.title } }

        var busy: [String: Int] = [:]
        for (key, items) in appointmentsByDay {
            busy[key] = items.filter { !$0.isAllDay }.reduce(0) { $0 + min($1.durationMinutes, 24 * 60) }
        }
        scheduleInfo = TaskScheduler.plan(
            SchedulerInput(
                tasks: tasks,
                busyMinutesByDay: busy,
                workCapacity: settings.workCapacityMinutes,
                personalCapacity: settings.personalCapacityMinutes,
                today: .now
            )
        )
        recordStartReminderDates()
        rescheduleNotifications()
        writeWidgetSnapshot()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// يسجّل أول يوم بدء مقترح لكل مهمة، فيُرسل تذكير البدء مرة واحدة لا كل يوم.
    /// إن صار اليوم المقترح أبكر (زاد الجهد مثلًا) يُحدَّث التذكير إلى اليوم الأبكر.
    private func recordStartReminderDates() {
        let todayKey = PlannerStorage.dateKey(for: .now)
        var changed = false
        for index in tasks.indices where !tasks[index].isDone {
            guard let info = scheduleInfo[tasks[index].id], !info.isAtRisk,
                  let startKey = info.startDateKey, startKey >= todayKey else { continue }
            if let recorded = tasks[index].startReminderDateKey, recorded <= startKey { continue }
            tasks[index].startReminderDateKey = startKey
            changed = true
        }
        if changed { PlannerStorage.saveTasks(tasks) }
    }

    private func writeWidgetSnapshot() {
        let now = Date()
        let nextAppointment = appointmentsByDay.values
            .flatMap { $0 }
            .filter { !$0.isAllDay && $0.start > now }
            .min { $0.start < $1.start }
        let focus = focusItems.first?.task ?? pendingTasks.first
        PlannerStorage.saveWidgetSnapshot(
            WidgetSnapshot(
                nextAppointmentTitle: nextAppointment?.title,
                nextAppointmentStart: nextAppointment?.start,
                focusTaskTitle: focus?.title
            )
        )
    }

    // MARK: - الإشعارات

    private func rescheduleNotifications() {
        let service = NotificationService.shared
        guard settings.notificationsEnabled else {
            service.removeAll()
            return
        }
        let calendar = PlannerCalendar.current
        let today = calendar.startOfDay(for: .now)
        func at(_ day: Date, minutes: Int) -> Date {
            calendar.date(byAdding: .minute, value: minutes, to: calendar.startOfDay(for: day)) ?? day
        }
        var items: [PlannedNotification] = []

        if settings.dailySummaryEnabled {
            for offset in 0..<7 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
                items.append(
                    PlannedNotification(
                        id: "summary-\(PlannerStorage.dateKey(for: day))",
                        title: "\(theme.symbol) خطة اليوم",
                        body: morningSummary(for: day),
                        fireDate: at(day, minutes: settings.dailySummaryMinutes),
                        isMorningSummary: true
                    )
                )
            }
        }

        if settings.appointmentRemindersEnabled {
            let lead = max(0, settings.appointmentLeadMinutes)
            var seen = Set<String>()
            for offset in 0..<7 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
                for appointment in appointments(on: day) where !appointment.isAllDay {
                    let key = "\(appointment.id)-\(Int(appointment.start.timeIntervalSince1970))"
                    guard seen.insert(key).inserted else { continue }
                    let now = Date()
                    let normalFire = appointment.start.addingTimeInterval(TimeInterval(-lead * 60))
                    let fireDate: Date
                    if let recorded = appointmentFireDates[key] {
                        fireDate = recorded // ثابت؛ إن مضى وقته لا يُعاد إرساله
                    } else if normalFire > now || !hasScheduledNotifications {
                        fireDate = normalFire
                        appointmentFireDates[key] = fireDate
                    } else {
                        // موعد جديد أُضيف قبل بدايته بأقل من مدة التنبيه: نذكّر بعد دقيقة.
                        fireDate = min(now.addingTimeInterval(60), appointment.start)
                        appointmentFireDates[key] = fireDate
                    }
                    let minutesLeft = max(0, Int(appointment.start.timeIntervalSince(fireDate) / 60))
                    items.append(
                        PlannedNotification(
                            id: "appointment-\(key)",
                            title: minutesLeft > 0 ? "موعد بعد \(minutesLeft) دقيقة" : "حان الموعد",
                            body: "\(appointment.title) · \(PlannerCalendar.text(for: appointment.start, format: "h:mm a"))",
                            fireDate: fireDate,
                            isMorningSummary: false
                        )
                    )
                }
            }
        }

        let todayKey = PlannerStorage.dateKey(for: today)
        for task in pendingTasks {
            let deadlineText = PlannerCalendar.text(for: task.deadline, format: "d MMMM")
            if settings.startRemindersEnabled,
               scheduleInfo[task.id]?.isAtRisk == false,
               let startKey = task.startReminderDateKey, startKey >= todayKey,
               let startDay = PlannerStorage.date(fromKey: startKey) {
                items.append(
                    PlannedNotification(
                        id: "start-\(task.id.uuidString)",
                        title: "حان وقت البدء",
                        body: "«\(task.title)» · الموعد النهائي \(deadlineText)",
                        fireDate: at(startDay, minutes: settings.reminderTimeMinutes),
                        isMorningSummary: false
                    )
                )
            }
            // إن كانت المهمة مربوطة بـ«التذكيرات» فالتنبيه يصل من هناك (للماك والهاتف)،
            // فلا نكرره بإشعار من خُطاي.
            if settings.deadlineRemindersEnabled, !isDeliveredByReminders(task) {
                for reminder in task.reminders {
                    guard let alertDate = self.fireDate(for: reminder, of: task) else { continue }
                    items.append(
                        PlannedNotification(
                            id: "deadline-\(task.id.uuidString)-\(reminder.id.uuidString)",
                            title: "تذكير: \(task.title)",
                            body: "\(reminder.label) · الموعد النهائي \(deadlineText)",
                            fireDate: alertDate,
                            isMorningSummary: false
                        )
                    )
                }
            }
        }
        service.replaceAll(with: items)
        hasScheduledNotifications = true
    }

    /// وقت تنبيه تذكير مطلوب في التفاصيل: وقت محدد، أو قبل الموعد النهائي
    /// محسوبًا من «وقت التذكيرات اليومية» في يوم الموعد.
    private func fireDate(for reminder: TaskReminder, of task: PlannerTask) -> Date? {
        if let text = reminder.dateTime {
            return Self.reminderDate(from: text)
        }
        guard let minutes = reminder.minutesBeforeDeadline else { return nil }
        let calendar = PlannerCalendar.current
        guard let base = calendar.date(
            byAdding: .minute,
            value: settings.reminderTimeMinutes,
            to: calendar.startOfDay(for: task.deadline)
        ) else { return nil }
        return base.addingTimeInterval(TimeInterval(-minutes * 60))
    }

    /// تنبيهات التذكير المطلوبة للمهمة في «التذكيرات» (القادمة فقط).
    /// nil = المهمة بلا تذكيرات من التفاصيل، فلا نمس تنبيهات وضعتها المستخدمة بنفسها هناك.
    private func reminderAlarmDates(for task: PlannerTask) -> [Date]? {
        guard !task.reminders.isEmpty else { return nil }
        guard settings.notificationsEnabled, settings.deadlineRemindersEnabled, !task.isDone else { return [] }
        let now = Date()
        return task.reminders.compactMap { fireDate(for: $0, of: task) }.filter { $0 > now }.sorted()
    }

    private func isDeliveredByReminders(_ task: PlannerTask) -> Bool {
        settings.remindersSyncEnabled
            && calendarService.remindersAuthorized
            && !(task.reminderItemID ?? "").isEmpty
    }

    /// نص ملخص الصباح ليوم معيّن.
    func morningSummary(for day: Date) -> String {
        let calendar = PlannerCalendar.current
        let dayKey = PlannerStorage.dateKey(for: day)
        var parts: [String] = []

        let dayAppointments = appointments(on: day)
        if !dayAppointments.isEmpty {
            parts.append(dayAppointments.count == 1 ? "موعد واحد" : "\(dayAppointments.count) مواعيد")
        }
        let due = pendingTasks.filter { calendar.isDate($0.deadline, inSameDayAs: day) }
        if !due.isEmpty {
            parts.append("تسليم: " + due.prefix(2).map(\.title).joined(separator: "، "))
        }
        let starting = pendingTasks.filter { scheduleInfo[$0.id]?.startDateKey == dayKey }
        if !starting.isEmpty {
            parts.append("البدء في: " + starting.prefix(2).map(\.title).joined(separator: "، "))
        }
        let steps = plannedSteps(on: day).filter { !$0.isDone }
        if !steps.isEmpty {
            parts.append(steps.count == 1 ? "خطوة واحدة مجدولة" : "\(steps.count) خطوات مجدولة")
        }
        if calendar.isDateInToday(day) {
            let overdueCount = overdueStepGroups.reduce(0) { $0 + $1.steps.count }
            if overdueCount > 0 { parts.append("\(overdueCount) خطوات متأخرة") }
            if !atRiskItems.isEmpty { parts.append("\(atRiskItems.count) مهام تحتاج انتباهًا") }
        }
        return parts.isEmpty
            ? "يوم هادئ: لا مواعيد ولا مهام مستحقة."
            : parts.joined(separator: " · ") + ". اضغط للمراجعة."
    }

    private static func reminderDate(from text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = PlannerCalendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)
    }

    // MARK: - مزامنة «التذكيرات»

    private func scheduleReminderSync() {
        guard settings.remindersSyncEnabled else { return }
        reminderSyncTask?.cancel()
        reminderSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.syncReminders()
        }
    }

    /// مزامنة المهام الرئيسية مع قائمة «خُطاي» في «التذكيرات» في الاتجاهين:
    /// الإنجاز يُزامن من الطرفين، والتذكير الجديد في القائمة يصبح مهمة.
    func syncReminders() async {
        guard settings.remindersSyncEnabled, calendarService.remindersAuthorized, !isSyncingReminders else { return }
        isSyncingReminders = true
        defer { isSyncingReminders = false }

        // nil = تعذرت القراءة؛ لا نغيّر شيئًا حتى لا تُفك الروابط خطأً.
        guard let snapshots = await calendarService.fetchKhutaiReminders(),
              settings.remindersSyncEnabled, !Task.isCancelled else { return }
        let byID = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byExternalID = Dictionary(
            snapshots.compactMap { snapshot in snapshot.externalID.map { ($0, snapshot) } },
            uniquingKeysWith: { first, _ in first }
        )
        let calendar = PlannerCalendar.current
        var changed = mergeReminderDuplicates()

        /// التذكير والمهمة يمثّلان الشيء نفسه إن تطابق العنوان ويوم الموعد.
        func isSameItem(_ snapshot: ReminderSnapshot, _ task: PlannerTask) -> Bool {
            guard normalizedTitle(snapshot.title) == normalizedTitle(task.title),
                  let due = snapshot.dueDate else { return false }
            return calendar.isDate(due, inSameDayAs: task.deadline)
        }
        // التذكيرات المرتبطة فعلًا بمعرّفها، فلا تُنسب لمهمة أخرى عند المطابقة بالعنوان.
        var claimedIDs = Set(tasks.compactMap { task in task.reminderItemID.flatMap { byID[$0]?.id } })

        for index in tasks.indices {
            guard let reminderID = tasks[index].reminderItemID, !reminderID.isEmpty else { continue }
            var matched = byID[reminderID]
            // قد يتغير معرّف التذكير بعد رفعه إلى iCloud؛ نعيد الربط بالمعرّف الخارجي،
            // ثم بالعنوان ويوم الموعد، قبل أن نعدّه محذوفًا.
            if matched == nil, let externalID = tasks[index].reminderExternalID {
                matched = byExternalID[externalID]
            }
            if matched == nil {
                matched = snapshots.first { !claimedIDs.contains($0.id) && isSameItem($0, tasks[index]) }
            }
            if let relinked = matched, relinked.id != reminderID {
                tasks[index].reminderItemID = relinked.id
                tasks[index].reminderExternalID = relinked.externalID ?? tasks[index].reminderExternalID
                claimedIDs.insert(relinked.id)
                changed = true
            }
            guard let snapshot = matched else {
                // حُذف من «التذكيرات»: نُبقي المهمة ونوقف ربطها.
                tasks[index].reminderItemID = ""
                changed = true
                continue
            }
            if let externalID = snapshot.externalID, tasks[index].reminderExternalID != externalID {
                tasks[index].reminderExternalID = externalID
                changed = true
            }
            let lastSynced = tasks[index].reminderLastSyncedDone ?? tasks[index].isDone
            let remoteChanged = snapshot.isCompleted != lastSynced
            let localChanged = tasks[index].isDone != lastSynced
            if remoteChanged && !localChanged {
                setCompletion(at: index, done: snapshot.isCompleted)
                changed = true
            }
            let dueDiffers = snapshot.dueDate.map { !calendar.isDate($0, inSameDayAs: tasks[index].deadline) } ?? true
            let wantedAlarms = reminderAlarmDates(for: tasks[index])
            let currentAlarms = snapshot.alarmDates.filter { $0 > Date() }
            let alarmsDiffer = wantedAlarms.map { wanted in
                Set(wanted.map { Int($0.timeIntervalSince1970 / 60) })
                    != Set(currentAlarms.map { Int($0.timeIntervalSince1970 / 60) })
            } ?? false
            if snapshot.isCompleted != tasks[index].isDone || snapshot.title != tasks[index].title || dueDiffers || alarmsDiffer {
                if let saved = try? calendarService.upsertReminder(for: tasks[index], alarmDates: wantedAlarms) {
                    tasks[index].reminderExternalID = saved.externalID ?? tasks[index].reminderExternalID
                }
            }
            if tasks[index].reminderLastSyncedDone != tasks[index].isDone {
                tasks[index].reminderLastSyncedDone = tasks[index].isDone
                changed = true
            }
        }

        // تذكيرات جديدة أُضيفت إلى القائمة من «التذكيرات» أو من الهاتف.
        let linkedIDs = Set(tasks.compactMap(\.reminderItemID))
        let linkedExternalIDs = Set(tasks.compactMap(\.reminderExternalID))
        for snapshot in snapshots where !snapshot.isCompleted {
            guard !linkedIDs.contains(snapshot.id),
                  !removedReminderIDs.contains(snapshot.id),
                  !settings.ignoredReminderIDs.contains(snapshot.id),
                  !(snapshot.externalID.map { settings.ignoredReminderIDs.contains($0) } ?? false),
                  !(snapshot.externalID.map { linkedExternalIDs.contains($0) } ?? false) else { continue }
            // مهمة موجودة بالعنوان واليوم نفسيهما: نربطها بدل إنشاء نسخة مكررة.
            if let existingIndex = tasks.firstIndex(where: { !$0.isDone && isSameItem(snapshot, $0) && ($0.reminderItemID ?? "").isEmpty }) {
                tasks[existingIndex].reminderItemID = snapshot.id
                tasks[existingIndex].reminderExternalID = snapshot.externalID
                tasks[existingIndex].reminderLastSyncedDone = tasks[existingIndex].isDone
                changed = true
                continue
            }
            if tasks.contains(where: { isSameItem(snapshot, $0) }) { continue }
            let title = snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            var task = PlannerTask(
                title: title,
                deadline: snapshot.dueDate ?? calendar.startOfDay(for: .now),
                category: .personal,
                notes: snapshot.notes
            )
            task.interpretedNotes = task.trimmedNotes
            task.reminderItemID = snapshot.id
            task.reminderExternalID = snapshot.externalID
            task.reminderLastSyncedDone = false
            tasks.append(task)
            changed = true
        }

        // مهام لم تُربط بعد.
        for index in tasks.indices where tasks[index].reminderItemID == nil && !tasks[index].isDone {
            if let saved = try? calendarService.upsertReminder(for: tasks[index], alarmDates: reminderAlarmDates(for: tasks[index])) {
                tasks[index].reminderItemID = saved.id
                tasks[index].reminderExternalID = saved.externalID
                tasks[index].reminderLastSyncedDone = tasks[index].isDone
                changed = true
            }
        }

        if changed { persist(syncReminders: false) }
    }

    /// يعالج نسخًا مكررة نشأت سابقًا: إن فقدت مهمة ربطها بالتذكير ثم استُورد التذكير
    /// نفسه كمهمة جديدة فارغة، ننقل الربط إلى المهمة الأصلية ونحذف النسخة المستوردة فقط
    /// (دون حذف التذكير نفسه).
    private func mergeReminderDuplicates() -> Bool {
        let calendar = PlannerCalendar.current
        var duplicateIDs = Set<UUID>()
        for duplicate in tasks {
            guard let reminderID = duplicate.reminderItemID, !reminderID.isEmpty,
                  !duplicate.isDone,
                  duplicate.subtasks.isEmpty, duplicate.suggestedSubtasks.isEmpty,
                  let originalIndex = tasks.firstIndex(where: { original in
                      original.id != duplicate.id
                          && !original.isDone
                          && !duplicateIDs.contains(original.id)
                          && (original.reminderItemID ?? "").isEmpty
                          && normalizedTitle(original.title) == normalizedTitle(duplicate.title)
                          && calendar.isDate(original.deadline, inSameDayAs: duplicate.deadline)
                          && (original.createdAt ?? .distantPast) <= (duplicate.createdAt ?? .distantFuture)
                  }) else { continue }
            tasks[originalIndex].reminderItemID = reminderID
            tasks[originalIndex].reminderExternalID = duplicate.reminderExternalID
            tasks[originalIndex].reminderLastSyncedDone = duplicate.reminderLastSyncedDone
            duplicateIDs.insert(duplicate.id)
        }
        guard !duplicateIDs.isEmpty else { return false }
        tasks.removeAll { duplicateIDs.contains($0.id) }
        for id in duplicateIDs { removeAchievement(taskID: id.uuidString) }
        return true
    }

    // MARK: - التقويم الشهري والسجل

    /// المهام الرئيسية التي يحل موعدها النهائي في هذا اليوم (المنجزة وغير المنجزة).
    func deadlines(on date: Date) -> [PlannerTask] {
        deadlineIndex[PlannerStorage.dateKey(for: date)] ?? []
    }

    func achievements(in month: Date) -> [PlannerAchievement] {
        let calendar = PlannerCalendar.current
        return storedAchievements
            .filter { calendar.isDate($0.completedAt, equalTo: month, toGranularity: .month) }
            .sorted { $0.completedAt < $1.completedAt }
    }

    /// السنوات المتاحة لتصفح السجل: من أقدم مهمة أو إنجاز حتى السنة القادمة.
    var historyYears: [Int] {
        let calendar = PlannerCalendar.current
        let currentYear = calendar.component(.year, from: .now)
        let knownDates = storedAchievements.map(\.completedAt)
            + tasks.map(\.deadline)
            + tasks.compactMap(\.createdAt)
        let earliestYear = knownDates.map { calendar.component(.year, from: $0) }.min() ?? currentYear
        return Array(min(earliestYear, currentYear)...(currentYear + 1))
    }

    // MARK: - المساعد الذكي

    /// المهام التي تحتوي تفاصيل لم تُقرأ بعد. المهمة بلا تفاصيل لا تُرسل
    /// للنموذج أبدًا وتبقى في القائمة كما هي دون تقسيم.
    var tasksNeedingInterpretation: [PlannerTask] {
        pendingTasks.filter(\.needsInterpretation)
    }

    /// ملخص اليوم والتشجيع يظهران فقط إن كانا من تخطيط اليوم نفسه.
    var todaysPlan: DailyPlan? {
        guard let dailyPlan, PlannerCalendar.current.isDateInToday(dailyPlan.generatedAt) else { return nil }
        return dailyPlan
    }

    /// يقرأ تفاصيل المهام الجديدة أو المعدّلة فقط. لا يولّد خطوات من عنده.
    func refreshPlan() async {
        let targets = tasksNeedingInterpretation
        guard !targets.isEmpty else {
            connectionMessage = "لا توجد تفاصيل جديدة تحتاج تنظيمًا."
            return
        }
        await runAssistant(for: targets, mode: .interpretNotes)
    }

    /// يطلب اقتراح خطوات لمهمة واحدة. الاقتراحات لا تُضاف إلا بالموافقة.
    func suggestSteps(for task: PlannerTask) async {
        guard let currentTask = self.task(withID: task.id), !currentTask.isDone else { return }
        await runAssistant(for: [currentTask], mode: .suggestSteps)
    }

    /// عند الفتح: تُقرأ فقط تفاصيل المهام التي لم تُقرأ بعد، حتى لا يُستهلك اشتراكك دون حاجة.
    func refreshPlanIfNeeded() async {
        guard isConnected, !tasksNeedingInterpretation.isEmpty else { return }
        await refreshPlan()
    }

    func acceptSuggestion(_ suggestionID: UUID, in taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }),
              let suggestion = tasks[index].suggestedSubtasks.first(where: { $0.id == suggestionID }) else { return }
        tasks[index].suggestedSubtasks.removeAll { $0.id == suggestionID }
        tasks[index].subtasks.append(suggestion)
        persist()
    }

    func acceptAllSuggestions(in taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].subtasks.append(contentsOf: tasks[index].suggestedSubtasks)
        tasks[index].suggestedSubtasks = []
        persist()
    }

    func dismissSuggestion(_ suggestionID: UUID, in taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].suggestedSubtasks.removeAll { $0.id == suggestionID }
        persist()
    }

    func dismissAllSuggestions(in taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].suggestedSubtasks = []
        persist()
    }

    private func runAssistant(for targets: [PlannerTask], mode: PlannerAIMode) async {
        guard isConnected else {
            connectionMessage = PlannerAssistantError.unavailable(settings.provider).errorDescription
            return
        }
        guard !targets.isEmpty, !isPlanning else { return }

        isPlanning = true
        connectionMessage = nil
        let succeeded = await performAssistantRun(for: targets, mode: mode)
        isPlanning = false

        // مهام أُضيفت أو عُدّلت تفاصيلها أثناء الانتظار: جولة واحدة إضافية.
        let pendingAfterRun = tasksNeedingInterpretation
        if succeeded, !pendingAfterRun.isEmpty {
            isPlanning = true
            await performAssistantRun(for: pendingAfterRun, mode: .interpretNotes)
            isPlanning = false
        }
    }

    @discardableResult
    private func performAssistantRun(for targets: [PlannerTask], mode: PlannerAIMode) async -> Bool {
        let targetIDs = Set(targets.map(\.id))
        // نص التفاصيل المُرسل لكل مهمة، لنعرف لاحقًا إن تغيّر أثناء الانتظار.
        let sentNotes = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0.trimmedNotes) })
        do {
            let provider = settings.provider
            let result = try await PlannerAssistant(provider: provider, model: settings.model(for: provider)).interpret(
                tasks: targets,
                mode: mode,
                date: .now
            )
            for interpretation in result.tasks {
                guard let taskID = UUID(uuidString: interpretation.taskID),
                      targetIDs.contains(taskID),
                      let index = tasks.firstIndex(where: { $0.id == taskID }),
                      !tasks[index].isDone else { continue }
                apply(interpretation, to: index, mode: mode, sentNotes: sentNotes[taskID] ?? "")
            }
            // مهمة أغفلها النموذج: نعدّها مقروءة حتى لا تُرسل في كل مرة.
            if mode == .interpretNotes {
                for (taskID, notes) in sentNotes {
                    guard let index = tasks.firstIndex(where: { $0.id == taskID }),
                          tasks[index].trimmedNotes == notes,
                          tasks[index].interpretedNotes != notes else { continue }
                    tasks[index].interpretedNotes = notes
                }
            }
            let summaryPlan = DailyPlan(
                date: result.date,
                overview: cleanedAssistantText(result.overview),
                // نُبقي أي خطوات قديمة لم يُعثر على مهمتها الأم كسجل، دون عرضها.
                schedule: dailyPlan?.schedule ?? [],
                encouragement: cleanedAssistantText(result.encouragement),
                generatedAt: result.generatedAt
            )
            dailyPlan = summaryPlan
            PlannerStorage.saveDailyPlan(summaryPlan)
            persist()
            connectionMessage = mode == .suggestSteps
                ? "جهّزت اقتراحات تظهر تحت المهمة بانتظار موافقتك."
                : "نُظّمت التفاصيل كما طُلب."
            return true
        } catch {
            connectionMessage = error.localizedDescription
            return false
        }
    }

    private func apply(_ interpretation: TaskInterpretation, to index: Int, mode: PlannerAIMode, sentNotes: String) {
        // التاريخ يُقبل كما ورد في التعليمات إن كانت صيغته صحيحة، دون تعديل.
        func validDate(_ key: String?) -> String? {
            guard let key, PlannerStorage.date(fromKey: key) != nil else { return nil }
            return key
        }
        func makeSubtask(_ step: AIStep) -> PlannerSubtask {
            PlannerSubtask(
                title: cleanedAssistantText(step.title),
                note: cleanedAssistantText(step.note),
                estimatedMinutes: step.estimatedMinutes,
                scheduledDate: validDate(step.scheduledDate)
            )
        }

        if mode == .interpretNotes {
            // التفاصيل هي المرجع: نستبدل الخطوات المستخرجة سابقًا ولم تُنجز بعد،
            // ونُبقي المنجزة واليدوية والمقبولة من الاقتراحات.
            tasks[index].subtasks.removeAll { $0.fromNotes && !$0.isDone }
        }

        // لا نكرر خطوة موجودة (بالعنوان) سواء كانت خطوة أو اقتراحًا.
        var knownTitles = Set((tasks[index].subtasks + tasks[index].suggestedSubtasks).map { normalizedTitle($0.title) })

        if mode == .interpretNotes {
            for step in interpretation.subtasks {
                var subtask = makeSubtask(step)
                subtask.fromNotes = true
                guard !subtask.title.isEmpty, knownTitles.insert(normalizedTitle(subtask.title)).inserted else { continue }
                tasks[index].subtasks.append(subtask)
            }
            let planning = TaskPlanningPreferences(
                effortMinutes: interpretation.planning.effortMinutes,
                minSessionMinutes: interpretation.planning.minSessionMinutes,
                spreadOverDays: interpretation.planning.spreadOverDays,
                earliestStart: validDate(interpretation.planning.earliestStart)
            )
            if tasks[index].planning != (planning.isEmpty ? nil : planning) {
                tasks[index].startReminderDateKey = nil
            }
            tasks[index].planning = planning.isEmpty ? nil : planning
            if let priority = interpretation.planning.priority.flatMap(TaskPriority.init(rawValue:)) {
                tasks[index].priority = priority
            }
            if let recurrence = interpretation.planning.recurrence.flatMap(TaskRecurrence.init(rawValue:)) {
                tasks[index].recurrence = recurrence
            }
            tasks[index].reminders = interpretation.reminders.map {
                TaskReminder(
                    label: cleanedAssistantText($0.label),
                    minutesBeforeDeadline: $0.minutesBeforeDeadline,
                    dateTime: $0.dateTime.flatMap { self.validReminderDateTime($0) }
                )
            }
            // إن عُدّلت التفاصيل أثناء الانتظار تبقى بحاجة لقراءة جديدة.
            tasks[index].interpretedNotes = sentNotes
        }

        // عند إعادة قراءة تفاصيل مُعدّلة لا نُعيد اقتراحات سبق تجاهلها؛
        // الاقتراحات الجديدة تأتي بطلب «اقتراح خطوات».
        // الاقتراحات لا تُقبل إلا بطلب «اقتراح خطوات».
        guard mode == .suggestSteps else { return }
        for step in interpretation.suggestions {
            // الاقتراحات بلا يوم ولا مدة؛ تُضاف كما هي فقط بعد الموافقة.
            var suggestion = makeSubtask(step)
            suggestion.scheduledDate = nil
            suggestion.estimatedMinutes = nil
            guard !suggestion.title.isEmpty, knownTitles.insert(normalizedTitle(suggestion.title)).inserted else { continue }
            tasks[index].suggestedSubtasks.append(suggestion)
        }
    }

    /// نص المساعد بلا شرطات طويلة (لا تُستخدم في العربية).
    private func cleanedAssistantText(_ text: String) -> String {
        text.replacingOccurrences(of: " — ", with: "، ")
            .replacingOccurrences(of: " – ", with: "، ")
            .replacingOccurrences(of: "—", with: "، ")
            .replacingOccurrences(of: "–", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedTitle(_ title: String) -> String {
        title.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// يقبل فقط الصيغة yyyy-MM-dd HH:mm للتذكير بوقت محدد.
    private func validReminderDateTime(_ text: String) -> String? {
        let formatter = DateFormatter()
        formatter.calendar = PlannerCalendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.isLenient = false
        return formatter.date(from: text) == nil ? nil : text
    }

    /// المهام التي قُسّمت قبل هذا التحديث تُعدّ مقروءة، فلا تُعالج من جديد.
    private func markExistingBreakdownsAsInterpreted() {
        var changed = false
        for index in tasks.indices where tasks[index].interpretedNotes == nil && !tasks[index].subtasks.isEmpty {
            tasks[index].interpretedNotes = tasks[index].trimmedNotes
            changed = true
        }
        if changed { PlannerStorage.saveTasks(tasks) }
    }

    // MARK: - الحفظ والتوافق

    private func persist(syncReminders: Bool = true) {
        PlannerStorage.saveTasks(tasks)
        recompute()
        if syncReminders { scheduleReminderSync() }
    }

    /// ترحيل الخطوات القديمة: كانت محفوظة في خطة واحدة مشتركة ومربوطة
    /// بمهامها بنص فقط. ننقل كل خطوة إلى داخل مهمتها الأم مع حالة تأشيرها،
    /// بعد نسخة احتياطية من الملفات القديمة.
    ///
    /// الترحيل آمن عند التكرار: لا تُضاف خطوة موجودة مسبقًا (اليوم والعنوان نفسهما).
    /// والخطوات التي لم يعد لمهمتها الأم وجود تبقى في ملف الخطة كما هي ولا تُحذف.
    private func migrateLegacyPlanIntoSubtasks() {
        guard let legacyPlan = dailyPlan, !legacyPlan.schedule.isEmpty else { return }
        PlannerStorage.backupBeforeSubtaskMigration()
        let completedSteps = PlannerStorage.loadCompletedSteps()

        var seenStepIDs = Set<String>()
        var unmatchedSteps: [PlannedTask] = []
        var migratedCount = 0
        for step in legacyPlan.schedule.sorted(by: { $0.scheduledDate < $1.scheduledDate }) {
            guard seenStepIDs.insert(step.id).inserted else { continue }
            guard let index = tasks.firstIndex(where: { $0.id.uuidString == step.taskID }) else {
                unmatchedSteps.append(step)
                continue
            }
            let alreadyMigrated = tasks[index].subtasks.contains {
                $0.scheduledDate == step.scheduledDate && $0.title == step.title
            }
            guard !alreadyMigrated else { continue }
            migratedCount += 1
            let completedAt = completedSteps[step.id]
            tasks[index].subtasks.append(
                PlannerSubtask(
                    title: step.title,
                    note: step.note,
                    estimatedMinutes: step.estimatedMinutes,
                    scheduledDate: step.scheduledDate,
                    isDone: completedAt != nil,
                    completedAt: completedAt
                )
            )
        }

        // لا نفرّغ الخطة القديمة إلا بعد التأكد من حفظ المهام بنجاح.
        if migratedCount > 0 {
            guard PlannerStorage.saveTasks(tasks) else { return }
        }
        guard unmatchedSteps.count != legacyPlan.schedule.count else { return }
        let migratedPlan = DailyPlan(
            date: legacyPlan.date,
            overview: legacyPlan.overview,
            schedule: unmatchedSteps,
            encouragement: legacyPlan.encouragement,
            generatedAt: legacyPlan.generatedAt
        )
        dailyPlan = migratedPlan
        PlannerStorage.saveDailyPlan(migratedPlan)
    }

    private func restoreStoredAchievements() {
        for task in tasks { syncAchievement(for: task) }
    }

    private func syncAchievement(for task: PlannerTask) {
        let taskID = task.id.uuidString
        let existingAchievement = storedAchievements.first { $0.taskID == taskID }
        let currentAchievement = task.isDone ? task.completedAt.map {
            PlannerAchievement(taskID: taskID, title: task.title, completedAt: $0)
        } : nil
        guard existingAchievement != currentAchievement else { return }

        storedAchievements.removeAll { $0.taskID == taskID }
        if task.isDone, let currentAchievement { storedAchievements.append(currentAchievement) }
        PlannerStorage.saveAchievements(storedAchievements)
    }

    private func removeAchievement(taskID: String) {
        let previousCount = storedAchievements.count
        storedAchievements.removeAll { $0.taskID == taskID }
        if storedAchievements.count != previousCount {
            PlannerStorage.saveAchievements(storedAchievements)
        }
    }

    private func restoreMissingCompletionDates() {
        var changed = false
        for index in tasks.indices where tasks[index].isDone && tasks[index].completedAt == nil {
            tasks[index].completedAt = tasks[index].subtasks.compactMap(\.completedAt).max() ?? .now
            changed = true
        }
        if changed { persist() }
    }
}
