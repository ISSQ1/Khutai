import AppKit
import EventKit
import SwiftUI

private enum ComposerMode: String, CaseIterable, Identifiable {
    case task = "مهمة"
    case appointment = "موعد"

    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject private var store: PlannerStore
    @EnvironmentObject private var calendarService: CalendarService
    @EnvironmentObject private var notifications: NotificationService
    @State private var composerMode = ComposerMode.task
    @State private var appointmentStart = PlannerCalendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now
    @State private var appointmentDuration = 60
    @State private var appointmentRecurrence = TaskRecurrence.none
    @State private var isSettingsPresented = false
    @State private var isCheckInPresented = false
    /// مهمة يُفتح محررها بعد إغلاق مراجعة الصباح.
    @State private var taskToEditAfterCheckIn: PlannerTask?
    @State private var title = ""
    @State private var notes = ""
    @State private var deadline = Date()
    @State private var category = TaskCategory.work
    @State private var priority = TaskPriority.normal
    @State private var selectedDate = Date()
    @State private var taskBeingEdited: PlannerTask?
    @State private var taskPendingDeletion: PlannerTask?
    @State private var expandedTaskIDs: Set<UUID> = []
    @State private var newSubtaskTitles: [UUID: String] = [:]
    @State private var newSubtaskDates: [UUID: Date] = [:]
    /// المهام التي اختير لخطوتها الجديدة يوم محدد. بدون ذلك تُضاف الخطوة بلا يوم.
    @State private var datedNewSubtaskTaskIDs: Set<UUID> = []
    @State private var subtaskBeingEdited: SubtaskEditTarget?
    @State private var remindersBeingEdited: ReminderEditTarget?
    @State private var isMonthPickerPresented = false

    private var accent: Color { store.theme.accent }
    private var soft: Color { store.theme.soft }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    header
                    workdayCapacity
                    connectionCard
                    taskComposer
                    monthCalendar
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        taskSections(at: context.date)
                    }
                    wisdomCard
                }
                .padding(24)
            }
        }
        .tint(accent)
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged).receive(on: RunLoop.main)) { _ in
            store.calendarStoreDidChange()
        }
        // تغيّر اليوم أو عودة التطبيق للواجهة: تُحدَّث الجدولة والإشعارات.
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
            store.refreshOnActivate()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshOnActivate()
        }
        // بعد منح إذن الإشعارات أول مرة نعيد جدولتها (ما جُدول قبل الإذن قد يُرفض).
        .onChange(of: notifications.isAuthorized) { _, granted in
            if granted { store.recompute() }
        }
        .onReceive(notifications.$isMorningCheckInRequested) { requested in
            guard requested else { return }
            notifications.isMorningCheckInRequested = false
            isCheckInPresented = true
        }
        .onChange(of: selectedDate) { _, newDate in
            store.focusAppointments(onMonthOf: newDate)
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsSheet()
                .environmentObject(store)
                .environmentObject(calendarService)
        }
        .sheet(isPresented: $isCheckInPresented, onDismiss: {
            if let task = taskToEditAfterCheckIn {
                taskToEditAfterCheckIn = nil
                taskBeingEdited = task
            }
        }) {
            MorningCheckInSheet { task in
                taskToEditAfterCheckIn = task
                isCheckInPresented = false
            }
            .environmentObject(store)
        }
        .environment(\.calendar, PlannerCalendar.current)
        .environment(\.locale, PlannerCalendar.locale)
        .task {
            await store.refreshPlanIfNeeded()
        }
        .sheet(item: $taskBeingEdited) { task in
            TaskEditorSheet(task: task)
                .environmentObject(store)
        }
        .sheet(item: $subtaskBeingEdited) { target in
            SubtaskEditorSheet(target: target)
                .environmentObject(store)
        }
        .sheet(item: $remindersBeingEdited) { target in
            ReminderEditorSheet(target: target)
                .environmentObject(store)
        }
        .alert(
            "حذف المهمة؟",
            isPresented: deleteConfirmationIsPresented,
            presenting: taskPendingDeletion
        ) { task in
            Button("حذف", role: .destructive) { store.delete(task) }
            Button("إلغاء", role: .cancel) {}
        } message: { task in
            Text("سيتم حذف «\(task.title)» وكل خطواتها من مهامك وسجلّك نهائيًا.")
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text(store.theme.symbol)
                .font(.largeTitle)
            Text("If you aim, aim at the stars. So, if you miss, you land on the moon.")
                .font(.headline.weight(.semibold))
                .multilineTextAlignment(.center)
                .environment(\.layoutDirection, .leftToRight)
                .foregroundStyle(accent)
            Text(PlannerCalendar.text(for: .now, format: "EEEE، d MMMM yyyy"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(soft, in: RoundedRectangle(cornerRadius: 20))
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                themeToggle
                settingsButton
            }
            .padding(12)
        }
    }

    private var settingsButton: some View {
        Button {
            isSettingsPresented = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .padding(7)
                .background(.white.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
        .help("الإعدادات")
    }


    /// زر صغير يبدّل سمة الألوان بين «لوتس» و«نجوم».
    private var themeToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                store.toggleTheme()
            }
        } label: {
            Image(systemName: "paintpalette.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .padding(7)
                .background(.white.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
        .help("سمة \(store.theme.next.title)")
    }

    private var workdayCapacity: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let todaySteps = store.plannedSteps(on: context.date)
            let completedCount = todaySteps.filter(\.isDone).count

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("إنجاز اليوم", systemImage: "checkmark.circle")
                    Spacer()
                    Text(todaySteps.isEmpty ? "يومك يبدأ من أول خطوة" : "\(completedCount) من \(todaySteps.count)")
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: Double(completedCount), total: Double(max(todaySteps.count, 1)))
                    .tint(accent)
                if store.todayLoadMinutes > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: store.isTodayOverloaded ? "exclamationmark.triangle.fill" : "hourglass")
                        Text("حمل اليوم المقترح \(TaskPlanningPreferences.durationText(store.todayLoadMinutes)) من \(TaskPlanningPreferences.durationText(store.todayCapacityMinutes))")
                        if store.isTodayOverloaded {
                            Text("· اليوم مزدحم")
                                .fontWeight(.semibold)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(store.isTodayOverloaded ? Color.orange : accent)
                }
            }
            .padding(.horizontal, 4)
        }
        .font(.subheadline)
    }

    private var taskComposer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(composerMode == .task ? "إضافة مهمة جديدة" : "إضافة موعد")
                    .font(.title3.weight(.semibold))
                Spacer()
                Picker("النوع", selection: $composerMode) {
                    ForEach(ComposerMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }
            if composerMode == .task {
                taskComposerFields
            } else {
                appointmentComposerFields
            }
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.secondary.opacity(0.16))
        }
    }

    @ViewBuilder
    private var appointmentComposerFields: some View {
        if !(store.settings.calendarSyncEnabled && calendarService.eventsAuthorized) {
            VStack(alignment: .leading, spacing: 8) {
                Text("تُحفظ المواعيد في تقويم «خُطاي» داخل تطبيق «التقويم»، فتظهر هنا وعلى أجهزتك الأخرى.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await store.enableCalendar() }
                } label: {
                    Label("السماح بالوصول إلى التقويم", systemImage: "calendar.badge.checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            RTLTextField(placeholder: "مثال: اجتماع القسم", text: $title)
            HStack(spacing: 14) {
                DatePicker("البداية", selection: $appointmentStart, displayedComponents: [.date, .hourAndMinute])
                    .fixedSize()
                Picker("المدة", selection: $appointmentDuration) {
                    ForEach([15, 30, 45, 60, 90, 120, 180, 240], id: \.self) { minutes in
                        Text(TaskPlanningPreferences.durationText(minutes)).tag(minutes)
                    }
                }
                .fixedSize()
                Picker("التكرار", selection: $appointmentRecurrence) {
                    ForEach(TaskRecurrence.allCases) { recurrence in
                        Text(recurrence.title).tag(recurrence)
                    }
                }
                .fixedSize()
            }
            RTLTextField(placeholder: "ملاحظة (اختياري)", text: $notes)
            Button {
                store.addAppointment(
                    title: title,
                    start: appointmentStart,
                    durationMinutes: appointmentDuration,
                    notes: notes,
                    recurrence: appointmentRecurrence
                )
                title = ""
                notes = ""
                appointmentRecurrence = .none
            } label: {
                Text("إضافة الموعد إلى التقويم \(store.theme.symbol)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder
    private var taskComposerFields: some View {
            RTLTextField(placeholder: "مثال: تجهيز ملخص الاجتماع", text: $title)

            RTLTextEditor(text: $notes)
                .font(.body)
                .frame(minHeight: 72)
                .padding(8)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                .overlay(alignment: .topLeading) {
                    if notes.isEmpty {
                        Text("التفاصيل والتعليمات (اختياري)… مثال: الخطوات: تشغيل المشروع، تجربة النموذج. تحتاج ساعتين يوميًا، والتذكير قبل الموعد بيوم")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(12)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: 14) {
                DatePicker("الموعد النهائي", selection: $deadline, displayedComponents: .date)
                    .fixedSize()

                Picker("القسم", selection: $category) {
                    ForEach(TaskCategory.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)
            }

            HStack(spacing: 10) {
                Label("الأولوية", systemImage: "flag")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("الأولوية", selection: $priority) {
                    ForEach(TaskPriority.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
            }

            if PlannerCalendar.current.isDateInToday(deadline) {
                Text("موعد هذه المهمة اليوم")
                    .font(.caption)
                    .foregroundStyle(accent)
            }

            Button {
                store.add(
                    title: title,
                    notes: notes,
                    deadline: deadline,
                    category: category,
                    priority: priority
                )
                priority = .normal
                let hasDetails = !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                title = ""
                notes = ""
                // المهمة بلا تفاصيل تُضاف مباشرة دون أي استدعاء للنموذج.
                if hasDetails { Task { await store.refreshPlan() } }
            } label: {
                HStack {
                    if store.isPlanning { ProgressView().controlSize(.small) }
                    Text(
                        store.isPlanning
                            ? "أنظّم التفاصيل الآن…"
                            : notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "إضافة المهمة \(store.theme.symbol)"
                                : "إضافة وتنظيم التفاصيل \(store.theme.symbol)"
                    )
                }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isPlanning)
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(
                    store.isConnected
                        ? "متصل باشتراكك في \(store.settings.provider == .codex ? "ChatGPT" : "Claude")"
                        : "يلزم فتح \(store.providerName) لتفعيل التخطيط",
                    systemImage: store.isConnected ? "sparkles" : "person.crop.circle.badge.exclamationmark"
                )
                .font(.headline)
                Spacer()
                if store.isConnected {
                    Text("متصل")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }

            Text("يستخدم المخطّط تسجيل \(store.providerName) الموجود على جهازك وحدود استخدام اشتراكك؛ لا يحتاج مفتاح API منفصلًا.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let message = store.connectionMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(accent)
            }
            if let message = store.calendarMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(accent)
            }
        }
        .padding(18)
        .background(soft.opacity(0.65), in: RoundedRectangle(cornerRadius: 18))
    }

    private func dayPlanCard(for date: Date) -> some View {
        let groups = store.dayGroups(on: date)
        let dueTasks = store.deadlines(on: date)
        let dayAppointments = store.appointments(on: date)
        let isToday = PlannerCalendar.current.isDateInToday(date)

        return VStack(alignment: .leading, spacing: 12) {
            // تفاصيل اليوم المختار في التقويم: مواعيده وتسليماته وخطواته.
            Text(isToday
                 ? "اليوم، \(PlannerCalendar.text(for: date, format: "d MMMM"))"
                 : PlannerCalendar.text(for: date, format: "EEEE d MMMM yyyy"))
                .font(.title3.weight(.semibold))

            if !dayAppointments.isEmpty {
                appointmentsList(dayAppointments)
            }

            if !dueTasks.isEmpty {
                deadlinesStrip(dueTasks)
            }

            if groups.isEmpty && dayAppointments.isEmpty && dueTasks.isEmpty {
                Text("لا مواعيد ولا تسليمات في هذا اليوم.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if !groups.isEmpty {
                ForEach(groups) { group in
                    dayGroupView(group)
                }
            }
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(accent.opacity(0.22))
        }
    }

    private func appointmentsList(_ appointments: [CalendarAppointment]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("المواعيد", systemImage: "calendar")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accent)
            ForEach(appointments) { appointment in
                HStack(spacing: 8) {
                    Circle()
                        .fill(appointment.color)
                        .frame(width: 7, height: 7)
                    Text(appointment.isAllDay
                         ? "طوال اليوم"
                         : "من \(PlannerCalendar.text(for: appointment.start, format: "h:mm a")) إلى \(PlannerCalendar.text(for: appointment.end, format: "h:mm a"))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 110, alignment: .leading)
                    Text(appointment.title)
                        .font(.callout)
                    Spacer(minLength: 0)
                    if !appointment.calendarTitle.isEmpty && !appointment.isKhutai {
                        Text(appointment.calendarTitle)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contextMenu {
                    if appointment.isKhutai {
                        Button("حذف الموعد", role: .destructive) {
                            store.deleteAppointment(appointment)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    /// المهام الرئيسية التي يحل موعدها في هذا اليوم.
    private func deadlinesStrip(_ dueTasks: [PlannerTask]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(dueTasks) { task in
                Label {
                    Text("موعد تسليم: \(task.title)")
                        .strikethrough(task.isDone)
                } icon: {
                    Image(systemName: task.isDone ? "checkmark.seal.fill" : "flag.fill")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(soft.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
    }

    /// خطوات اليوم تحت عنوان مهمتها الأم، فلا تختلط بخطوات المهام الأخرى.
    private func dayGroupView(_ group: DayTaskGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .frame(width: 6, height: 6)
                Text(group.task.title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Text("\(group.task.completedSubtaskCount)/\(group.task.subtasks.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(accent)

            ForEach(group.steps) { step in
                stepRow(step, taskID: group.task.id, showsDate: false)
            }
            .padding(.leading, 8)
        }
        .padding(12)
        .background(soft.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }

    private func stepRow(_ step: PlannerSubtask, taskID: UUID, showsDate: Bool) -> some View {
        let isOverdue = !step.isDone && (step.scheduledDate ?? "9999-99-99") < PlannerStorage.dateKey(for: .now)

        return HStack(alignment: .top, spacing: 10) {
            Button {
                store.toggleSubtask(step.id, in: taskID)
            } label: {
                Image(systemName: step.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.body.weight(.medium))
                    .strikethrough(step.isDone)
                if !step.note.isEmpty {
                    Text(step.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    if step.scheduledDate != nil, showsDate || step.dueMinutes != nil {
                        Label(stepDueLabel(step, includesDay: showsDate), systemImage: step.dueMinutes == nil ? "calendar" : "calendar.badge.clock")
                            .foregroundStyle(isOverdue ? Color.red.opacity(0.8) : accent)
                    }
                    if !step.reminders.isEmpty {
                        Label(step.reminders.count == 1 ? step.reminders[0].label : "\(step.reminders.count) تنبيهات", systemImage: "bell.fill")
                            .foregroundStyle(accent)
                    }
                    if let estimatedMinutes = step.estimatedMinutes {
                        Label("حوالي \(estimatedMinutes) دقيقة", systemImage: "clock")
                            .foregroundStyle(accent)
                    }
                }
                .font(.caption2.weight(.medium))
            }
            Spacer()
            if !step.isDone {
                Button {
                    remindersBeingEdited = ReminderEditTarget(step: step, taskID: taskID)
                } label: {
                    Image(systemName: step.reminders.isEmpty ? "bell" : "bell.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(step.reminders.isEmpty ? Color.secondary : accent)
                .help("تنبيهات الخطوة")
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("تعديل الخطوة") {
                subtaskBeingEdited = SubtaskEditTarget(taskID: taskID, subtask: step)
            }
            Button("تنبيهات الخطوة") {
                remindersBeingEdited = ReminderEditTarget(step: step, taskID: taskID)
            }
            Button("حذف الخطوة", role: .destructive) {
                store.deleteSubtask(step.id, from: taskID)
            }
        }
    }

    /// يوم تسليم الخطوة ووقته إن حُدد، مثل «التسليم: غدًا، 3:00 م».
    private func stepDueLabel(_ step: PlannerSubtask, includesDay: Bool) -> String {
        var text = includesDay ? stepDateText(step.scheduledDate) : ""
        if let minutes = step.dueMinutes,
           let time = PlannerCalendar.current.date(byAdding: .minute, value: minutes, to: PlannerCalendar.current.startOfDay(for: .now)) {
            let timeText = PlannerCalendar.text(for: time, format: "h:mm a")
            text = text.isEmpty ? timeText : "\(text)، \(timeText)"
        }
        return "التسليم: \(text)"
    }

    private func stepDateText(_ dateKey: String?) -> String {
        guard let dateKey, let date = PlannerStorage.date(fromKey: dateKey) else { return "بدون يوم" }
        let calendar = PlannerCalendar.current
        if calendar.isDateInToday(date) { return "اليوم" }
        if calendar.isDateInTomorrow(date) { return "غدًا" }
        if date < calendar.startOfDay(for: .now) {
            return "متأخرة · \(PlannerCalendar.text(for: date, format: "d MMM"))"
        }
        return PlannerCalendar.text(for: date, format: "EEEE d MMM")
    }

    private var monthCalendar: some View {
        VStack(spacing: 14) {
            calendarCard
            monthlyAchievements
            Divider()
                .overlay(accent.opacity(0.16))
                .padding(.horizontal, 8)
            dayPlanCard(for: selectedDate)
        }
    }

    private var calendarCard: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Label("تقويم الشهر", systemImage: "calendar")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(accent)
                    Button {
                        isMonthPickerPresented = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(PlannerCalendar.text(for: selectedDate, format: "MMMM yyyy"))
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.semibold))
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("اختيار شهر وسنة")
                    .popover(isPresented: $isMonthPickerPresented, arrowEdge: .bottom) {
                        MonthYearPicker(selectedDate: $selectedDate, years: store.historyYears, accent: accent) {
                            isMonthPickerPresented = false
                        }
                    }
                }
                Spacer()
                monthNavigation
            }

            HStack(spacing: 0) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: calendarColumns, spacing: 8) {
                ForEach(Array(monthGridDates.enumerated()), id: \.offset) { _, date in
                    if let date {
                        calendarDay(date)
                    } else {
                        Color.clear.frame(height: 38)
                    }
                }
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [soft.opacity(0.72), Color.white.opacity(0.92)],
                startPoint: .topTrailing,
                endPoint: .bottomLeading
            ),
            in: RoundedRectangle(cornerRadius: 22)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(accent.opacity(0.16))
        }
    }

    private var monthNavigation: some View {
        HStack(spacing: 4) {
            Button { moveSelectedMonth(by: -1) } label: {
                Image(systemName: "chevron.right")
            }
            Button("اليوم") { selectedDate = .now }
                .font(.caption.weight(.semibold))
            Button { moveSelectedMonth(by: 1) } label: {
                Image(systemName: "chevron.left")
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(accent)
        .padding(5)
        .background(.white.opacity(0.72), in: Capsule())
    }

    private var calendarColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)
    }

    private var weekdaySymbols: [String] {
        let calendar = PlannerCalendar.current
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    private var monthGridDates: [Date?] {
        let calendar = PlannerCalendar.current
        guard let monthInterval = calendar.dateInterval(of: .month, for: selectedDate),
              let dayRange = calendar.range(of: .day, in: .month, for: selectedDate) else { return [] }

        let firstDay = monthInterval.start
        let leadingCount = (calendar.component(.weekday, from: firstDay) - calendar.firstWeekday + 7) % 7
        let dates = dayRange.compactMap {
            calendar.date(byAdding: .day, value: $0 - 1, to: firstDay)
        }
        let trailingCount = (7 - (leadingCount + dates.count) % 7) % 7
        return Array(repeating: nil, count: leadingCount)
            + dates.map(Optional.some)
            + Array(repeating: nil, count: trailingCount)
    }

    private func calendarDay(_ date: Date) -> some View {
        let calendar = PlannerCalendar.current
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(date)
        // نعرض المهام الرئيسية فقط (مواعيدها النهائية)، دون الخطوات الفرعية.
        let dueTasks = store.deadlines(on: date)
        let hasDeadline = !dueTasks.isEmpty
        let dayAppointments = store.appointments(on: date)
        let hasAppointments = !dayAppointments.isEmpty

        return Button { selectedDate = date } label: {
            VStack(spacing: 2) {
                Text(PlannerCalendar.text(for: date, format: "d"))
                    .font(.callout.weight(isSelected ? .bold : .medium))
                HStack(spacing: 3) {
                    Circle()
                        .fill(isSelected ? Color.white : accent)
                        .frame(width: 5, height: 5)
                        .opacity(hasDeadline ? 1 : 0)
                    Circle()
                        .fill(isSelected ? Color.white.opacity(0.7) : accent.opacity(0.35))
                        .frame(width: 5, height: 5)
                        .opacity(hasAppointments ? 1 : 0)
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(isSelected ? accent : Color.clear, in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                if isToday && !isSelected {
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(accent.opacity(0.55))
                }
            }
        }
        .buttonStyle(.plain)
        .help(calendarDayHelp(dueTasks: dueTasks, appointments: dayAppointments))
    }

    private func calendarDayHelp(dueTasks: [PlannerTask], appointments: [CalendarAppointment]) -> String {
        let deadlines: [String] = dueTasks.map { "تسليم: \($0.title)" }
        let meetings: [String] = appointments.map(\.title)
        return (deadlines + meetings).joined(separator: "، ")
    }

    private func moveSelectedMonth(by offset: Int) {
        if let newDate = PlannerCalendar.current.date(byAdding: .month, value: offset, to: selectedDate) {
            selectedDate = newDate
        }
    }

    private var monthlyAchievements: some View {
        let achievements = store.achievements(in: selectedDate)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("إنجازات الشهر", systemImage: "trophy.fill")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(achievements.count)")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 34, minHeight: 34)
                    .background(accent, in: Circle())
            }
            .foregroundStyle(accent)
            if achievements.isEmpty {
                Text("لا توجد مهام رئيسية مكتملة في هذا الشهر.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(achievements) { achievement in
                    HStack {
                        Label(achievement.title, systemImage: "checkmark.circle.fill")
                        Spacer()
                        Text(PlannerCalendar.text(for: achievement.completedAt, format: "d MMM"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(soft.opacity(0.78), in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(accent.opacity(0.1))
        }
    }

    private var deleteConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { taskPendingDeletion != nil },
            set: { if !$0 { taskPendingDeletion = nil } }
        )
    }

    private func taskSections(at date: Date) -> some View {
        VStack(spacing: 16) {
            taskSection(for: .work, at: date)
            taskSection(for: .personal, at: date)
        }
    }

    private func taskSection(for category: TaskCategory, at date: Date) -> some View {
        let tasks = store.visibleTasks(at: date).filter { $0.category == category }

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(category.title)
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(tasks.count) مهام")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if tasks.isEmpty {
                Text("لا توجد مهام هنا الآن")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 14)
            } else {
                ForEach(tasks) { task in
                    taskRow(task)
                    if task.id != tasks.last?.id { Divider() }
                }
            }
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.secondary.opacity(0.16))
        }
    }

    private func taskRow(_ task: PlannerTask) -> some View {
        let isExpanded = expandedTaskIDs.contains(task.id)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    store.toggle(task)
                } label: {
                    Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { toggleExpansion(of: task) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(task.title)
                                .font(.body.weight(.medium))
                                .strikethrough(task.isDone)
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text("الموعد \(PlannerCalendar.text(for: task.deadline, format: "d MMM yyyy"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let planning = task.planning, !planning.isEmpty {
                            Label(planning.summary, systemImage: "hourglass")
                                .font(.caption2)
                                .foregroundStyle(accent)
                        }
                        if !task.reminders.isEmpty {
                            Label(task.reminders.map(\.label).joined(separator: "، "), systemImage: "bell")
                                .font(.caption2)
                                .foregroundStyle(accent)
                        }
                        HStack(spacing: 10) {
                            priorityBadge(task.priority)
                            if task.recurrence != .none {
                                Label(task.recurrence.title, systemImage: "repeat")
                                    .font(.caption2)
                                    .foregroundStyle(accent)
                            }
                        }
                        if !task.isDone, let info = store.info(for: task) {
                            scheduleLine(info)
                        }
                        if !task.suggestedSubtasks.isEmpty {
                            Label("\(task.suggestedSubtasks.count) اقتراحات بانتظار موافقتك", systemImage: "lightbulb")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(accent)
                        }
                        if !task.subtasks.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView(
                                    value: Double(task.completedSubtaskCount),
                                    total: Double(task.subtasks.count)
                                )
                                .tint(accent)
                                .frame(maxWidth: 140)
                                Text("\(task.completedSubtaskCount) من \(task.subtasks.count) خطوات")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let completedAt = task.completedAt {
                            Text("مكتملة · تنتقل إلى إنجازات الشهر بعد \(PlannerCalendar.text(for: completedAt.addingTimeInterval(86_400), format: "d MMM، h:mm a"))")
                                .font(.caption2)
                                .foregroundStyle(accent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "إخفاء الخطوات" : "عرض الخطوات")

                Spacer()
                Button {
                    remindersBeingEdited = ReminderEditTarget(task: task)
                } label: {
                    Image(systemName: task.reminders.isEmpty ? "bell" : "bell.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .help(task.reminders.isEmpty ? "إضافة تنبيه للمهمة" : "تنبيهات المهمة (\(task.reminders.count))")

                Button {
                    store.setCategory(task.category == .work ? .personal : .work, for: task.id)
                } label: {
                    Image(systemName: task.category == .work ? "house" : "briefcase")
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .help(task.category == .work ? "نقل إلى «خارج الدوام»" : "نقل إلى «الدوام»")

                Button { taskBeingEdited = task } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .help("تعديل المهمة")

                Button { taskPendingDeletion = task } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red.opacity(0.8))
                .help("حذف المهمة")
            }

            if isExpanded {
                subtaskList(for: task)
                    .padding(.leading, 30)
            }
        }
    }

    /// شارة الأولوية على بطاقة المهمة: العالية بلون السمة الممتلئ، والمنخفضة باهتة.
    private func priorityBadge(_ priority: TaskPriority) -> some View {
        Label("أولوية \(priority.title)", systemImage: priority == .low ? "flag" : "flag.fill")
            .font(.caption2.weight(priority == .high ? .bold : .medium))
            .foregroundStyle(priority == .high ? Color.white : (priority == .low ? Color.secondary : accent))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                priority == .high ? accent : accent.opacity(priority == .low ? 0.06 : 0.12),
                in: Capsule()
            )
    }

    /// سطر الجدولة المقترحة: متى يُستحسن البدء، أو تنبيه إن كان الوقت لا يكفي.
    @ViewBuilder
    private func scheduleLine(_ info: TaskScheduleInfo) -> some View {
        if info.isAtRisk {
            Label(atRiskText(info), systemImage: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.orange)
        } else if let startKey = info.startDateKey, let startDate = PlannerStorage.date(fromKey: startKey) {
            Label(startText(startDate, todayMinutes: info.todayMinutes), systemImage: "play.circle")
                .font(.caption2.weight(.medium))
                .foregroundStyle(accent)
        }
    }

    private func startText(_ date: Date, todayMinutes: Int) -> String {
        let calendar = PlannerCalendar.current
        if date <= calendar.startOfDay(for: .now) {
            return todayMinutes > 0
                ? "يُقترح العمل عليها اليوم (حوالي \(TaskPlanningPreferences.durationText(todayMinutes)))"
                : "حان وقت البدء"
        }
        if calendar.isDateInTomorrow(date) { return "البدء المقترح: غدًا" }
        return "البدء المقترح: \(PlannerCalendar.text(for: date, format: "EEEE d MMMM"))"
    }

    private func atRiskText(_ info: TaskScheduleInfo) -> String {
        if info.isOverdue { return "فات الموعد النهائي، ويمكن تعديله من زر التعديل" }
        if let needed = info.remainingMinutes, let available = info.availableMinutes {
            return "الوقت قبل الموعد لا يكفي: يلزم \(TaskPlanningPreferences.durationText(needed)) والمتاح \(TaskPlanningPreferences.durationText(available))، ويُستحسن البدء اليوم أو تعديل الموعد"
        }
        return "الوقت قبل الموعد ضيق، ويُستحسن البدء اليوم"
    }

    private func toggleExpansion(of task: PlannerTask) {
        if expandedTaskIDs.contains(task.id) {
            expandedTaskIDs.remove(task.id)
        } else {
            expandedTaskIDs.insert(task.id)
        }
    }

    /// خطوات المهمة كاملة تحتها مباشرة، مع إضافة خطوة يدويًا.
    private func subtaskList(for task: PlannerTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if task.subtasks.isEmpty {
                Text("لا توجد خطوات، والمهمة تبقى كما هي. يمكن إضافة خطوة يدويًا أو طلب اقتراحات.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(task.orderedSubtasks) { step in
                    stepRow(step, taskID: task.id, showsDate: true)
                }
            }

            HStack(spacing: 8) {
                RTLTextField(placeholder: "خطوة جديدة", text: newSubtaskTitleBinding(for: task.id)) {
                    addSubtask(to: task)
                }
                if datedNewSubtaskTaskIDs.contains(task.id) {
                    DatePicker("", selection: newSubtaskDateBinding(for: task.id), displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .fixedSize()
                }
                Button {
                    if datedNewSubtaskTaskIDs.contains(task.id) {
                        datedNewSubtaskTaskIDs.remove(task.id)
                    } else {
                        datedNewSubtaskTaskIDs.insert(task.id)
                    }
                } label: {
                    Image(systemName: datedNewSubtaskTaskIDs.contains(task.id) ? "calendar.badge.minus" : "calendar.badge.plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(datedNewSubtaskTaskIDs.contains(task.id) ? accent : Color.secondary)
                .help(datedNewSubtaskTaskIDs.contains(task.id) ? "إضافة الخطوة بلا موعد تسليم" : "تحديد موعد تسليم للخطوة (اختياري)")
                Button {
                    addSubtask(to: task)
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .disabled((newSubtaskTitles[task.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("إضافة الخطوة")
            }
            .font(.callout)

            if !task.suggestedSubtasks.isEmpty {
                suggestionsSection(for: task)
            }

            if !task.isDone {
                Button {
                    Task { await store.suggestSteps(for: task) }
                } label: {
                    Label("اقتراح خطوات", systemImage: "lightbulb")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(accent)
                .disabled(store.isPlanning || !store.isConnected)
                .help("يقترح خطوات تظهر هنا، ولا يُضاف شيء إلا بموافقتك")
            }
        }
        .padding(12)
        .background(soft.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }

    /// خطوات مقترحة لا تُضاف إلا بالموافقة عليها.
    private func suggestionsSection(for task: PlannerTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("اقتراحات", systemImage: "lightbulb")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                Spacer()
                Button("إضافة الكل") { store.acceptAllSuggestions(in: task.id) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                Button("تجاهل الكل") { store.dismissAllSuggestions(in: task.id) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(task.suggestedSubtasks) { suggestion in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggestion.title)
                            .font(.callout)
                        HStack(spacing: 10) {
                            if suggestion.scheduledDate != nil {
                                Label(stepDateText(suggestion.scheduledDate), systemImage: "calendar")
                            }
                            if let minutes = suggestion.estimatedMinutes {
                                Label("حوالي \(minutes) دقيقة", systemImage: "clock")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        store.acceptSuggestion(suggestion.id, in: task.id)
                    } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                    .help("إضافة هذه الخطوة")
                    Button {
                        store.dismissSuggestion(suggestion.id, in: task.id)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("تجاهل الاقتراح")
                }
            }
        }
        .padding(10)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(accent.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }

    private func newSubtaskTitleBinding(for taskID: UUID) -> Binding<String> {
        Binding(
            get: { newSubtaskTitles[taskID] ?? "" },
            set: { newSubtaskTitles[taskID] = $0 }
        )
    }

    private func newSubtaskDateBinding(for taskID: UUID) -> Binding<Date> {
        Binding(
            get: { newSubtaskDates[taskID] ?? Self.nextWholeHour() },
            set: { newSubtaskDates[taskID] = $0 }
        )
    }

    private func addSubtask(to task: PlannerTask) {
        let title = newSubtaskTitles[task.id] ?? ""
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let due = datedNewSubtaskTaskIDs.contains(task.id) ? (newSubtaskDates[task.id] ?? Self.nextWholeHour()) : nil
        store.addSubtask(to: task.id, title: title, scheduledDate: due, dueMinutes: due.map(Self.minutesSinceMidnight))
        newSubtaskTitles[task.id] = ""
    }

    /// الساعة الكاملة التالية، قيمة أولية معقولة لموعد تسليم جديد.
    nonisolated static func nextWholeHour(after date: Date = .now) -> Date {
        let calendar = PlannerCalendar.current
        let hourStart = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        return calendar.date(byAdding: .hour, value: 1, to: hourStart) ?? date
    }

    nonisolated static func minutesSinceMidnight(_ date: Date) -> Int {
        let parts = PlannerCalendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private var wisdomCard: some View {
        let wisdom = PlannerStorage.wisdom(for: .now)

        return VStack(spacing: 5) {
            Text(wisdom.text)
                .font(.headline.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(accent)
            Text(wisdom.source)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(soft, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct TaskEditorSheet: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var notes: String
    @State private var deadline: Date
    @State private var category: TaskCategory
    @State private var priority: TaskPriority
    @State private var recurrence: TaskRecurrence

    private let task: PlannerTask
    private var accent: Color { store.theme.accent }

    init(task: PlannerTask) {
        self.task = task
        _title = State(initialValue: task.title)
        _notes = State(initialValue: task.notes ?? "")
        _deadline = State(initialValue: task.deadline)
        _category = State(initialValue: task.category)
        _priority = State(initialValue: task.priority)
        _recurrence = State(initialValue: task.recurrence)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("تعديل المهمة")
                .font(.title2.weight(.semibold))
            RTLTextField(placeholder: "اسم المهمة", text: $title)
            RTLTextEditor(text: $notes)
                .frame(minHeight: 90)
                .padding(8)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            DatePicker("الموعد النهائي", selection: $deadline, displayedComponents: .date)
            Picker("القسم", selection: $category) {
                ForEach(TaskCategory.allCases) { category in
                    Text(category.title).tag(category)
                }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 16) {
                Picker("الأولوية", selection: $priority) {
                    ForEach(TaskPriority.allCases) { priority in
                        Text(priority.title).tag(priority)
                    }
                }
                .fixedSize()
                Picker("التكرار", selection: $recurrence) {
                    ForEach(TaskRecurrence.allCases) { recurrence in
                        Text(recurrence.title).tag(recurrence)
                    }
                }
                .fixedSize()
            }

            HStack {
                Button("إلغاء") { dismiss() }
                Spacer()
                Button("حفظ التعديل") { saveChanges() }
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .tint(accent)
        .environment(\.calendar, PlannerCalendar.current)
        .environment(\.locale, PlannerCalendar.locale)
    }

    private func saveChanges() {
        var updatedTask = task
        updatedTask.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedTask.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedTask.deadline = deadline
        updatedTask.category = category
        updatedTask.priority = priority
        updatedTask.recurrence = recurrence
        // إن تغيّرت التفاصيل يقرؤها المساعد من جديد لهذه المهمة وحدها.
        store.update(updatedTask)
        dismiss()
    }
}

/// الخطوة المراد تعديلها مع معرّف مهمتها الأم.
struct SubtaskEditTarget: Identifiable {
    let taskID: UUID
    let subtask: PlannerSubtask

    var id: UUID { subtask.id }
}

private struct SubtaskEditorSheet: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var note: String
    @State private var hasDate: Bool
    @State private var hasTime: Bool
    @State private var date: Date
    @State private var minutes: Int

    private let target: SubtaskEditTarget
    private var accent: Color { store.theme.accent }

    init(target: SubtaskEditTarget) {
        self.target = target
        let subtask = target.subtask
        _title = State(initialValue: subtask.title)
        _note = State(initialValue: subtask.note)
        let scheduledDate = subtask.scheduledDate.flatMap(PlannerStorage.date(fromKey:))
        _hasDate = State(initialValue: scheduledDate != nil)
        _hasTime = State(initialValue: scheduledDate != nil && subtask.dueMinutes != nil)
        let initialDate: Date
        if let scheduledDate {
            initialDate = PlannerCalendar.current.date(byAdding: .minute, value: subtask.dueMinutes ?? 9 * 60, to: scheduledDate) ?? scheduledDate
        } else {
            initialDate = ContentView.nextWholeHour()
        }
        _date = State(initialValue: initialDate)
        _minutes = State(initialValue: subtask.estimatedMinutes ?? 30)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("تعديل الخطوة")
                .font(.title2.weight(.semibold))
            if let parent = store.task(withID: target.taskID) {
                Label(parent.title, systemImage: "list.bullet.indent")
                    .font(.subheadline)
                    .foregroundStyle(accent)
            }
            RTLTextField(placeholder: "اسم الخطوة", text: $title)
            RTLTextField(placeholder: "ملاحظة", text: $note)
            Toggle("موعد تسليم للخطوة", isOn: $hasDate)
            if hasDate {
                DatePicker("يوم التسليم", selection: $date, displayedComponents: .date)
                Toggle("وقت تسليم محدد", isOn: $hasTime)
                if hasTime {
                    DatePicker("الساعة", selection: $date, displayedComponents: .hourAndMinute)
                }
            }
            Stepper("المدة التقديرية: \(minutes) دقيقة", value: $minutes, in: 5...300, step: 5)

            HStack {
                Button("إلغاء") { dismiss() }
                Spacer()
                Button("حفظ") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .tint(accent)
        .environment(\.calendar, PlannerCalendar.current)
        .environment(\.locale, PlannerCalendar.locale)
    }

    private func save() {
        var updated = target.subtask
        updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.scheduledDate = hasDate ? PlannerStorage.dateKey(for: date) : nil
        updated.dueMinutes = hasDate && hasTime ? ContentView.minutesSinceMidnight(date) : nil
        // لا نخترع تقديرًا لخطوة بلا مدة إن لم تُغيَّر القيمة الافتراضية.
        if target.subtask.estimatedMinutes != nil || minutes != 30 {
            updated.estimatedMinutes = minutes
        }
        store.updateSubtask(updated, in: target.taskID)
        dismiss()
    }
}

/// ما يُعدَّل في نافذة التنبيهات: مهمة رئيسية أو خطوة داخلها.
struct ReminderEditTarget: Identifiable {
    let taskID: UUID
    let stepID: UUID?
    let title: String
    let reminders: [TaskReminder]
    /// موعد التسليم الذي تُحسب منه التنبيهات النسبية (nil إن لم يُحدد للخطوة موعد).
    let dueDescription: String?

    var id: UUID { stepID ?? taskID }

    init(task: PlannerTask) {
        taskID = task.id
        stepID = nil
        title = task.title
        reminders = task.reminders
        dueDescription = "الموعد النهائي: \(PlannerCalendar.text(for: task.deadline, format: "EEEE d MMMM"))"
    }

    init(step: PlannerSubtask, taskID: UUID) {
        self.taskID = taskID
        stepID = step.id
        title = step.title
        reminders = step.reminders
        if let key = step.scheduledDate, let day = PlannerStorage.date(fromKey: key) {
            var text = PlannerCalendar.text(for: day, format: "EEEE d MMMM")
            if let minutes = step.dueMinutes,
               let time = PlannerCalendar.current.date(byAdding: .minute, value: minutes, to: day) {
                text += "، \(PlannerCalendar.text(for: time, format: "h:mm a"))"
            }
            dueDescription = "موعد التسليم: \(text)"
        } else {
            dueDescription = nil
        }
    }
}

private enum ReminderKind: String, CaseIterable, Identifiable {
    case relative = "قبل الموعد"
    case exact = "في وقت محدد"

    var id: String { rawValue }
}

private enum ReminderUnit: String, CaseIterable, Identifiable {
    case minutes = "دقيقة"
    case hours = "ساعة"
    case days = "يوم"

    var id: String { rawValue }

    var minutes: Int {
        switch self {
        case .minutes: return 1
        case .hours: return 60
        case .days: return 1440
        }
    }
}

/// تنبيهات مهمة أو خطوة: عرضها وحذفها وإضافة تنبيه قبل الموعد أو في وقت محدد.
private struct ReminderEditorSheet: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    @State private var reminders: [TaskReminder]
    @State private var kind: ReminderKind
    @State private var amount = 1
    @State private var unit = ReminderUnit.days
    @State private var exactDate = ContentView.nextWholeHour()

    private let target: ReminderEditTarget
    private var accent: Color { store.theme.accent }
    private var canUseRelative: Bool { target.dueDescription != nil }

    init(target: ReminderEditTarget) {
        self.target = target
        _reminders = State(initialValue: target.reminders)
        _kind = State(initialValue: target.dueDescription == nil ? .exact : .relative)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(target.stepID == nil ? "تنبيهات المهمة" : "تنبيهات الخطوة")
                .font(.title2.weight(.semibold))
            Label(target.title, systemImage: target.stepID == nil ? "flag" : "list.bullet.indent")
                .font(.subheadline)
                .foregroundStyle(accent)
            if let due = target.dueDescription {
                Text(due)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("لم يُحدد لهذه الخطوة موعد تسليم، فيمكن التنبيه في وقت محدد فقط. ولتنبيه «قبل الموعد» حدّد موعدها من «تعديل الخطوة».")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if reminders.isEmpty {
                Text("لا تنبيهات بعد.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(reminders) { reminder in
                        HStack(spacing: 8) {
                            Image(systemName: "bell.fill")
                                .font(.caption)
                                .foregroundStyle(accent)
                            Text(reminder.label)
                                .font(.callout)
                            Spacer(minLength: 0)
                            Button {
                                reminders.removeAll { $0.id == reminder.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red.opacity(0.8))
                            .help("حذف التنبيه")
                        }
                    }
                }
                .padding(10)
                .background(store.theme.soft.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("إضافة تنبيه")
                    .font(.headline)
                Picker("", selection: $kind) {
                    ForEach(ReminderKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!canUseRelative)

                if kind == .relative {
                    HStack(spacing: 8) {
                        Stepper("قبل الموعد بـ \(amount)", value: $amount, in: 0...90)
                        Picker("", selection: $unit) {
                            ForEach(ReminderUnit.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                } else {
                    DatePicker("الوقت", selection: $exactDate, displayedComponents: [.date, .hourAndMinute])
                }

                Button {
                    addReminder()
                } label: {
                    Label("إضافة التنبيه", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(accent)
            }

            if !store.settings.notificationsEnabled || !store.settings.deadlineRemindersEnabled {
                Label("تنبيهات التذكير مطفأة من الإعدادات، فلن تصل حتى تُفعَّل.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("إلغاء") { dismiss() }
                Spacer()
                Button("حفظ") { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 440)
        .tint(accent)
        .environment(\.calendar, PlannerCalendar.current)
        .environment(\.locale, PlannerCalendar.locale)
    }

    private func addReminder() {
        let reminder: TaskReminder
        if kind == .relative && canUseRelative {
            let minutes = amount * unit.minutes
            reminder = TaskReminder(
                label: TaskReminder.relativeLabel(minutes: minutes),
                minutesBeforeDeadline: minutes,
                dateTime: nil,
                fromNotes: false
            )
        } else {
            let formatter = DateFormatter()
            formatter.calendar = PlannerCalendar.current
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            reminder = TaskReminder(
                label: PlannerCalendar.text(for: exactDate, format: "EEEE d MMMM، h:mm a"),
                minutesBeforeDeadline: nil,
                dateTime: formatter.string(from: exactDate),
                fromNotes: false
            )
        }
        // لا نكرر تنبيهًا مطابقًا.
        guard !reminders.contains(where: {
            $0.minutesBeforeDeadline == reminder.minutesBeforeDeadline && $0.dateTime == reminder.dateTime
        }) else { return }
        reminders.append(reminder)
    }

    private func save() {
        if let stepID = target.stepID {
            store.setReminders(reminders, forStep: stepID, in: target.taskID)
        } else {
            store.setReminders(reminders, for: target.taskID)
        }
        dismiss()
    }
}

/// اختيار سريع لأي شهر وسنة لتصفح التقويم والإنجازات السابقة.
private struct MonthYearPicker: View {
    @Binding var selectedDate: Date
    let years: [Int]
    let accent: Color
    let onDone: () -> Void

    @State private var year: Int

    init(selectedDate: Binding<Date>, years: [Int], accent: Color, onDone: @escaping () -> Void) {
        _selectedDate = selectedDate
        self.years = years
        self.accent = accent
        self.onDone = onDone
        _year = State(initialValue: PlannerCalendar.current.component(.year, from: selectedDate.wrappedValue))
    }

    private var monthNames: [String] {
        PlannerCalendar.current.standaloneMonthSymbols
    }

    private var selectedMonth: Int {
        PlannerCalendar.current.component(.month, from: selectedDate)
    }

    private var selectedYear: Int {
        PlannerCalendar.current.component(.year, from: selectedDate)
    }

    var body: some View {
        VStack(spacing: 12) {
            Picker("السنة", selection: $year) {
                ForEach(years, id: \.self) { optionYear in
                    Text(String(optionYear)).tag(optionYear)
                }
            }
            .labelsHidden()
            .frame(width: 140)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(Array(monthNames.enumerated()), id: \.offset) { index, name in
                    let month = index + 1
                    let isSelected = month == selectedMonth && year == selectedYear
                    Button {
                        select(month: month)
                    } label: {
                        Text(name)
                            .font(.callout.weight(isSelected ? .bold : .regular))
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .background(isSelected ? accent : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(width: 300)
        .environment(\.layoutDirection, .rightToLeft)
    }

    private func select(month: Int) {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        if let date = PlannerCalendar.current.date(from: components) {
            selectedDate = date
        }
        onDone()
    }
}

// MARK: - حقول نصية من اليمين لليسار

/// حقل نص بسطر واحد يبدأ من اليمين دائمًا (النص والعبارة الإرشادية)، مهما كانت لغة النظام.
struct RTLTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var onSubmit: (() -> Void)?

    init(placeholder: String, text: Binding<String>, onSubmit: (() -> Void)? = nil) {
        self.placeholder = placeholder
        _text = text
        self.onSubmit = onSubmit
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.alignment = .right
        field.baseWritingDirection = .rightToLeft
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.stringValue = text
        field.placeholderAttributedString = Self.placeholderText(placeholder)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        if field.placeholderAttributedString?.string != placeholder {
            field.placeholderAttributedString = Self.placeholderText(placeholder)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private static func placeholderText(_ text: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.baseWritingDirection = .rightToLeft
        return NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.placeholderTextColor,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .paragraphStyle: style
        ])
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RTLTextField

        init(parent: RTLTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)), let onSubmit = parent.onSubmit else {
                return false
            }
            onSubmit()
            return true
        }
    }
}

/// محرر نص متعدد الأسطر يبدأ من اليمين دائمًا.
struct RTLTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 0, height: 2)
        let style = Self.paragraphStyle()
        textView.defaultParagraphStyle = style
        textView.typingAttributes[.paragraphStyle] = style
        textView.baseWritingDirection = .rightToLeft
        textView.string = text
        Self.applyRightAlignment(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
        Self.applyRightAlignment(to: textView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private static func paragraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.baseWritingDirection = .rightToLeft
        return style
    }

    private static func applyRightAlignment(to textView: NSTextView) {
        textView.alignment = .right
        textView.baseWritingDirection = .rightToLeft
        let range = NSRange(location: 0, length: (textView.string as NSString).length)
        textView.textStorage?.addAttribute(.paragraphStyle, value: paragraphStyle(), range: range)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RTLTextEditor

        init(parent: RTLTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
