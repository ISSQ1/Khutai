import SwiftUI

/// الإعدادات: المساعد الذكي، الإشعارات، التقويم والتذكيرات، وسعة اليوم.
struct SettingsSheet: View {
    @EnvironmentObject private var store: PlannerStore
    @EnvironmentObject private var calendarService: CalendarService
    @Environment(\.dismiss) private var dismiss
    @State private var calendars: [CalendarChoice] = []
    /// اسم النموذج أثناء الكتابة؛ يُحفظ عند الضغط على Return أو عند الإغلاق.
    @State private var modelText = ""
    @State private var isResetConfirmationPresented = false

    init() {}

    private var accent: Color { store.theme.accent }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("الإعدادات", systemImage: "gearshape.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(accent)
                Spacer()
                Button("تم") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Form {
                assistantSection
                notificationsSection
                calendarSection
                capacitySection
                resetSection
            }
            .formStyle(.grouped)
        }
        .frame(width: 560, height: 680)
        .tint(accent)
        .environment(\.layoutDirection, .rightToLeft)
        .environment(\.calendar, PlannerCalendar.current)
        .environment(\.locale, PlannerCalendar.locale)
        .onAppear {
            calendars = calendarService.availableCalendars()
            modelText = currentModel
        }
        .onDisappear { commitModel() }
        .onChange(of: store.settings.provider) { oldProvider, _ in
            // نحفظ ما كُتب للمزوّد السابق قبل عرض نموذج المزوّد الجديد.
            let typed = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty {
                var settings = store.settings
                if oldProvider == .codex { settings.codexModel = typed } else { settings.claudeModel = typed }
                store.updateSettings(settings)
            }
            modelText = currentModel
        }
    }

    // MARK: - الأقسام

    private var assistantSection: some View {
        Section {
            Picker("المزوّد", selection: binding(\.provider)) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                TextField("النموذج", text: $modelText)
                    .textFieldStyle(.roundedBorder)
                    .environment(\.layoutDirection, .leftToRight)
                    .onSubmit { commitModel() }
                Menu("اختيار") {
                    ForEach(store.settings.provider.suggestedModels, id: \.self) { model in
                        Button(model) {
                            modelText = model
                            commitModel()
                        }
                    }
                }
                .fixedSize()
            }

            Label(
                store.isConnected
                    ? "الأداة مثبتة على الجهاز"
                    : "الأداة غير موجودة، ويلزم تثبيتها وتسجيل الدخول",
                systemImage: store.isConnected ? "checkmark.circle.fill" : "exclamationmark.circle"
            )
            .font(.caption)
            .foregroundStyle(store.isConnected ? Color.green : Color.orange)
        } header: {
            Text("المساعد الذكي")
        } footer: {
            Text(store.settings.provider == .codex
                 ? "يعمل عبر تطبيق ChatGPT أو أداة codex المثبتة، وبحدود اشتراكك."
                 : "يعمل عبر أداة Claude Code (الأمر claude) المثبتة، وبحدود اشتراكك. النموذج «sonnet» يعني أحدث Claude Sonnet.")
                .font(.caption)
        }
    }

    private var notificationsSection: some View {
        Section("الإشعارات") {
            Toggle("تفعيل الإشعارات", isOn: binding(\.notificationsEnabled))
            if store.settings.notificationsEnabled {
                HStack {
                    Toggle("ملخص الصباح", isOn: binding(\.dailySummaryEnabled))
                    Spacer()
                    DatePicker("", selection: timeBinding(\.dailySummaryMinutes), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .disabled(!store.settings.dailySummaryEnabled)
                }
                HStack {
                    Toggle("تذكير المواعيد", isOn: binding(\.appointmentRemindersEnabled))
                    Spacer()
                    Stepper(
                        "قبلها بـ \(store.settings.appointmentLeadMinutes) دقيقة",
                        value: binding(\.appointmentLeadMinutes),
                        in: 0...120,
                        step: 5
                    )
                    .fixedSize()
                    .disabled(!store.settings.appointmentRemindersEnabled)
                }
                Toggle("تذكير بدء العمل على المهام", isOn: binding(\.startRemindersEnabled))
                Toggle("تنبيهات المهام والخطوات", isOn: binding(\.deadlineRemindersEnabled))
                DatePicker("وقت التذكيرات اليومية", selection: timeBinding(\.reminderTimeMinutes), displayedComponents: .hourAndMinute)
                Toggle("صوت التنبيهات", isOn: binding(\.notificationSound))
                Button {
                    store.sendTestNotification()
                } label: {
                    Label("تجربة التنبيه (يصل بعد ٥ ثوانٍ)", systemImage: "bell.badge")
                }
            }
        }
    }

    private var calendarSection: some View {
        Section {
            if !calendarService.eventsAuthorized || !store.settings.calendarSyncEnabled {
                Button {
                    Task {
                        await store.enableCalendar()
                        calendars = calendarService.availableCalendars()
                    }
                } label: {
                    Label("ربط «التقويم» لعرض المواعيد", systemImage: "calendar.badge.plus")
                }
            } else {
                Toggle("عرض مواعيد التقويم", isOn: binding(\.calendarSyncEnabled))
                Toggle("كل التقاويم", isOn: allCalendarsBinding)
                if !store.settings.selectedCalendarIDs.isEmpty {
                    ForEach(calendars) { calendar in
                        Toggle(isOn: calendarBinding(calendar.id)) {
                            HStack(spacing: 6) {
                                Circle().fill(calendar.color).frame(width: 8, height: 8)
                                Text(calendar.title)
                            }
                        }
                    }
                }
            }

            if !calendarService.remindersAuthorized || !store.settings.remindersSyncEnabled {
                Button {
                    Task { await store.enableReminders() }
                } label: {
                    Label("مزامنة المهام مع «التذكيرات»", systemImage: "checklist")
                }
            } else {
                Toggle("مزامنة المهام مع قائمة «خُطاي» في «التذكيرات»", isOn: binding(\.remindersSyncEnabled))
                Toggle("إرسال تنبيهات المهام إلى الآيفون عبر «التذكيرات»", isOn: binding(\.remindersOnIPhone))
                if store.settings.remindersOnIPhone {
                    Text("إن وصلك التنبيه مرتين على الماك، أطفئ إشعارات تطبيق «التذكيرات» على الماك من إعدادات النظام ← الإشعارات.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let message = store.calendarMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("التقويم والتذكيرات")
        } footer: {
            Text("المواعيد التي تُضاف من خُطاي تُحفظ في تقويم «خُطاي»، والمهام الرئيسية تظهر في قائمة «خُطاي» في «التذكيرات»؛ الإنجاز يُزامن في الاتجاهين.")
                .font(.caption)
        }
    }

    private var capacitySection: some View {
        Section {
            Stepper(
                "الدوام: حتى \(TaskPlanningPreferences.durationText(store.settings.workCapacityMinutes)) يوميًا",
                value: binding(\.workCapacityMinutes),
                in: 30...720,
                step: 30
            )
            Stepper(
                "خارج الدوام: حتى \(TaskPlanningPreferences.durationText(store.settings.personalCapacityMinutes)) يوميًا",
                value: binding(\.personalCapacityMinutes),
                in: 0...480,
                step: 30
            )
        } header: {
            Text("سعة اليوم")
        } footer: {
            Text("تُستخدم لاقتراح يوم البدء لكل مهمة والتنبيه حين يزدحم اليوم.")
                .font(.caption)
        }
    }

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                isResetConfirmationPresented = true
            } label: {
                Label("البدء من جديد: مسح كل المهام والسجل", systemImage: "trash")
            }
            .alert("مسح كل البيانات؟", isPresented: $isResetConfirmationPresented) {
                Button("مسح والبدء من جديد", role: .destructive) { store.resetAllData() }
                Button("إلغاء", role: .cancel) {}
            } message: {
                Text("تُحذف كل المهام والخطوات والخطط والإنجازات نهائيًا، وتتوقف مزامنة «التذكيرات» (يمكن تفعيلها لاحقًا). السمة وبقية الإعدادات تبقى، ومواعيد «التقويم» لا تُمس.")
            }
        } footer: {
            Text("لا يمكن التراجع عن هذه الخطوة.")
                .font(.caption)
        }
    }

    // MARK: - الربط بالإعدادات

    private func binding<Value>(_ keyPath: WritableKeyPath<PlannerSettings, Value>) -> Binding<Value> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { newValue in
                var settings = store.settings
                settings[keyPath: keyPath] = newValue
                store.updateSettings(settings)
            }
        )
    }

    private var currentModel: String {
        store.settings.provider == .codex ? store.settings.codexModel : store.settings.claudeModel
    }

    private func commitModel() {
        let cleaned = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != currentModel else { return }
        var settings = store.settings
        if settings.provider == .codex {
            settings.codexModel = cleaned
        } else {
            settings.claudeModel = cleaned
        }
        store.updateSettings(settings)
    }

    /// يحوّل الدقائق من منتصف الليل إلى تاريخ لمنتقي الوقت والعكس.
    private func timeBinding(_ keyPath: WritableKeyPath<PlannerSettings, Int>) -> Binding<Date> {
        let calendar = PlannerCalendar.current
        return Binding(
            get: {
                calendar.date(byAdding: .minute, value: store.settings[keyPath: keyPath], to: calendar.startOfDay(for: .now)) ?? .now
            },
            set: { newDate in
                let components = calendar.dateComponents([.hour, .minute], from: newDate)
                var settings = store.settings
                settings[keyPath: keyPath] = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                store.updateSettings(settings)
            }
        )
    }

    private var allCalendarsBinding: Binding<Bool> {
        Binding(
            get: { store.settings.selectedCalendarIDs.isEmpty },
            set: { showAll in
                var settings = store.settings
                settings.selectedCalendarIDs = showAll ? [] : calendars.map(\.id)
                store.updateSettings(settings)
            }
        )
    }

    private func calendarBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { store.settings.selectedCalendarIDs.contains(id) },
            set: { isOn in
                var settings = store.settings
                if isOn {
                    if !settings.selectedCalendarIDs.contains(id) { settings.selectedCalendarIDs.append(id) }
                } else {
                    settings.selectedCalendarIDs.removeAll { $0 == id }
                    // لا نترك القائمة فارغة لأن الفارغة تعني «كل التقاويم».
                    if settings.selectedCalendarIDs.isEmpty { return }
                }
                store.updateSettings(settings)
            }
        )
    }
}

/// مراجعة الصباح: تُفتح عند الضغط على إشعار ملخص الصباح فقط.
struct MorningCheckInSheet: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    /// لفتح محرر مهمة (مثلًا لتعديل موعد مهمة متأخرة).
    let onEditTask: (PlannerTask) -> Void

    init(onEditTask: @escaping (PlannerTask) -> Void) {
        self.onEditTask = onEditTask
    }

    private var accent: Color { store.theme.accent }
    private var soft: Color { store.theme.soft }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(store.theme.symbol) مراجعة الصباح")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(accent)
                    Text(PlannerCalendar.text(for: .now, format: "EEEE، d MMMM"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isQuietDay {
                        Text("يوم هادئ: لا مواعيد ولا خطوات ولا مهام تحتاج انتباهًا.")
                            .foregroundStyle(.secondary)
                    }
                    if store.isTodayOverloaded {
                        Label(
                            "اليوم مزدحم: \(TaskPlanningPreferences.durationText(store.todayLoadMinutes)) من \(TaskPlanningPreferences.durationText(store.todayCapacityMinutes)). يمكن تأجيل بعض الخطوات إلى الغد.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(.orange)
                    }

                    section("مواعيد اليوم", icon: "calendar", isEmpty: store.appointments(on: .now).isEmpty) {
                        ForEach(store.appointments(on: .now)) { appointment in
                            HStack {
                                Text(appointment.isAllDay ? "طوال اليوم" : PlannerCalendar.text(for: appointment.start, format: "h:mm a"))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 80, alignment: .leading)
                                Text(appointment.title)
                            }
                        }
                    }

                    section("للعمل عليه اليوم", icon: "sun.max", isEmpty: store.focusItems.isEmpty) {
                        ForEach(store.focusItems) { item in
                            HStack {
                                Text(item.task.title)
                                Spacer()
                                if item.info.todayMinutes > 0 {
                                    Text("حوالي \(TaskPlanningPreferences.durationText(item.info.todayMinutes))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    let todaySteps = store.dayGroups(on: .now).filter { group in group.steps.contains { !$0.isDone } }
                    section("خطوات اليوم", icon: "checklist", isEmpty: todaySteps.isEmpty) {
                        ForEach(todaySteps) { group in
                            ForEach(group.steps.filter { !$0.isDone }) { step in
                                HStack {
                                    Text("\(group.task.title) ‹ \(step.title)")
                                    Spacer()
                                    Button("تم") { store.toggleSubtask(step.id, in: group.task.id) }
                                        .buttonStyle(.borderless)
                                    Button("غدًا") {
                                        store.reschedule(
                                            stepID: step.id,
                                            in: group.task.id,
                                            to: PlannerCalendar.current.date(byAdding: .day, value: 1, to: .now)
                                        )
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    section("خطوات متأخرة", icon: "clock.arrow.circlepath", isEmpty: store.overdueStepGroups.isEmpty) {
                        ForEach(store.overdueStepGroups) { group in
                            ForEach(group.steps) { step in
                                HStack {
                                    Text("\(group.task.title) ‹ \(step.title)")
                                    Spacer()
                                    Button("إلى اليوم") { store.reschedule(stepID: step.id, in: group.task.id, to: .now) }
                                        .buttonStyle(.borderless)
                                    Button("بلا يوم") { store.reschedule(stepID: step.id, in: group.task.id, to: nil) }
                                        .buttonStyle(.borderless)
                                        .foregroundStyle(.secondary)
                                    Button("تم") { store.toggleSubtask(step.id, in: group.task.id) }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                    }

                    section("تحتاج انتباهًا", icon: "exclamationmark.triangle", isEmpty: store.atRiskItems.isEmpty) {
                        ForEach(store.atRiskItems) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.task.title)
                                    Text(item.info.isOverdue
                                         ? "فات الموعد النهائي"
                                         : "الوقت المتاح قبل \(PlannerCalendar.text(for: item.task.deadline, format: "d MMMM")) لا يكفي")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                                Spacer()
                                Button("تعديل الموعد") { onEditTask(item.task) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }

            Button {
                dismiss()
            } label: {
                Text("ابدأ يومك \(store.theme.symbol)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 520, height: 620)
        .tint(accent)
        .environment(\.layoutDirection, .rightToLeft)
    }

    private var isQuietDay: Bool {
        store.appointments(on: .now).isEmpty
            && store.focusItems.isEmpty
            && store.dayGroups(on: .now).isEmpty
            && store.overdueStepGroups.isEmpty
            && store.atRiskItems.isEmpty
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        icon: String,
        isEmpty: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if !isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: icon)
                    .font(.headline)
                    .foregroundStyle(accent)
                content()
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(soft.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
