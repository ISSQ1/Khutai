import SwiftUI

private enum PlannerViewMode: String, CaseIterable, Identifiable {
    case today = "اليوم"
    case month = "الشهر"

    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var title = ""
    @State private var notes = ""
    @State private var deadline = Date()
    @State private var category = TaskCategory.work
    @State private var viewMode = PlannerViewMode.today
    @State private var selectedDate = Date()
    @State private var taskBeingEdited: PlannerTask?
    @State private var taskPendingDeletion: PlannerTask?

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
                    planViewSwitcher
                    if viewMode == .today {
                        dayPlanCard(for: .now)
                    } else {
                        monthCalendar
                    }
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        taskSections(at: context.date)
                    }
                    wisdomCard
                }
                .padding(24)
            }
        }
        .tint(accent)
        .environment(\.calendar, PlannerCalendar.current)
        .environment(\.locale, PlannerCalendar.locale)
        .task {
            await store.refreshPlanIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.reloadCompletedSteps() }
        }
        .sheet(item: $taskBeingEdited) { task in
            TaskEditorSheet(task: task)
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
            Text("سيتم حذف «\(task.title)» من مهامك وخطتك.")
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
            themeToggle.padding(12)
        }
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
            let completedCount = todaySteps.filter { store.completedSteps[$0.id] != nil }.count

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("إنجاز اليوم", systemImage: "checkmark.circle")
                    Spacer()
                    Text(todaySteps.isEmpty ? "يومك يبدأ من أول خطوة" : "\(completedCount) من \(todaySteps.count)")
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: Double(completedCount), total: Double(max(todaySteps.count, 1)))
                    .tint(accent)
            }
        }
        .font(.subheadline)
    }

    private var taskComposer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("إضافة مهمة جديدة")
                .font(.title3.weight(.semibold))
            TextField("مثال: تجهيز ملخص الاجتماع", text: $title)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $notes)
                .font(.body)
                .frame(minHeight: 72)
                .padding(8)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                .overlay(alignment: .topLeading) {
                    if notes.isEmpty {
                        Text("التفاصيل والخطوات المطلوبة… مثال: تشغيل المشروع، إلغاء مادة الاختبار، تجربة مودل ميتا")
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

            Label("سأقدّر مدة المهمة وأقسّمها أثناء التخطيط", systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(accent)

            if PlannerCalendar.current.isDateInToday(deadline) {
                Text("مهمة مفاجئة لليوم — سأضعها في أقرب وقت مناسب")
                    .font(.caption)
                    .foregroundStyle(accent)
            }

            Button {
                store.add(
                    title: title,
                    notes: notes,
                    deadline: deadline,
                    category: category
                )
                title = ""
                notes = ""
                Task { await store.refreshPlan() }
            } label: {
                HStack {
                    if store.isPlanning { ProgressView().controlSize(.small) }
                    Text(store.isPlanning ? "أرتّب يومك الآن…" : "إضافة وتخطيط الآن \(store.theme.symbol)")
                }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isPlanning)
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.secondary.opacity(0.16))
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(
                    store.isConnected ? "متصل باشتراكك في ChatGPT" : "يلزم فتح Codex لتفعيل التخطيط",
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

            Text("يستخدم المخطّط تسجيل Codex الموجود على جهازك وحدود استخدام اشتراكك؛ لا يحتاج مفتاح API منفصلًا.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let message = store.connectionMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(accent)
            }
        }
        .padding(18)
        .background(soft.opacity(0.65), in: RoundedRectangle(cornerRadius: 18))
    }

    private var planViewSwitcher: some View {
        Picker("طريقة العرض", selection: $viewMode) {
            ForEach(PlannerViewMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 240)
        .frame(maxWidth: .infinity)
    }

    private func dayPlanCard(for date: Date) -> some View {
        let steps = store.plannedSteps(on: date)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(PlannerCalendar.current.isDateInToday(date) ? "خطة اليوم" : PlannerCalendar.text(for: date, format: "d MMMM yyyy"))
                    .font(.title3.weight(.semibold))
                Spacer()
                if PlannerCalendar.current.isDateInToday(date) {
                    Button {
                        Task { await store.refreshPlan() }
                    } label: {
                        Label("إعادة التخطيط", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isPlanning)
                }
            }

            if let overview = store.dailyPlan?.overview, PlannerCalendar.current.isDateInToday(date) {
                Text(overview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if steps.isEmpty {
                Text("لا توجد خطوات مخططة لهذا اليوم.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                ForEach(steps) { plannedTask in
                    plannedStepRow(plannedTask)
                }
            }

            if let encouragement = store.dailyPlan?.encouragement,
               PlannerCalendar.current.isDateInToday(date) {
                Text(encouragement)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(accent)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
            }
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(accent.opacity(0.22))
        }
    }

    private func plannedStepRow(_ plannedTask: PlannedTask) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                store.togglePlannedStep(plannedTask)
            } label: {
                Image(systemName: store.completedSteps[plannedTask.id] == nil ? "circle" : "checkmark.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(plannedTask.title)
                    .font(.body.weight(.medium))
                    .strikethrough(store.completedSteps[plannedTask.id] != nil)
                Text(plannedTask.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let estimatedMinutes = plannedTask.estimatedMinutes {
                    Label("حوالي \(estimatedMinutes) دقيقة", systemImage: "clock")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(accent)
                }
            }
            Spacer()
        }
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
                    Text(PlannerCalendar.text(for: selectedDate, format: "MMMM yyyy"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
        let hasPlan = !store.plannedSteps(on: date).isEmpty

        return Button { selectedDate = date } label: {
            VStack(spacing: 2) {
                Text(PlannerCalendar.text(for: date, format: "d"))
                    .font(.callout.weight(isSelected ? .bold : .medium))
                Circle()
                    .fill(isSelected ? Color.white : accent)
                    .frame(width: 4, height: 4)
                    .opacity(hasPlan ? 1 : 0)
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
                Text("كل علامة صح تضيف إنجازًا هنا—خطواتك الصغيرة تصنع شهرًا كبيرًا.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(achievements) { achievement in
                    Label(achievement.title, systemImage: "checkmark.circle.fill")
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
        HStack(alignment: .top, spacing: 12) {
            Button {
                store.toggle(task)
            } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.body.weight(.medium))
                    .strikethrough(task.isDone)
                Text("الموعد \(PlannerCalendar.text(for: task.deadline, format: "d MMM yyyy"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let completedAt = task.completedAt {
                    Text("مكتملة · تظهر حتى \(PlannerCalendar.text(for: completedAt.addingTimeInterval(86_400), format: "d MMM، h:mm a"))")
                        .font(.caption2)
                        .foregroundStyle(accent)
                }
            }
            Spacer()
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

    private let task: PlannerTask
    private var accent: Color { store.theme.accent }

    init(task: PlannerTask) {
        self.task = task
        _title = State(initialValue: task.title)
        _notes = State(initialValue: task.notes ?? "")
        _deadline = State(initialValue: task.deadline)
        _category = State(initialValue: task.category)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("تعديل المهمة")
                .font(.title2.weight(.semibold))
            TextField("اسم المهمة", text: $title)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $notes)
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

            HStack {
                Button("إلغاء") { dismiss() }
                Spacer()
                Button("حفظ التعديل والتخطيط") { saveChanges() }
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
        store.update(updatedTask)
        dismiss()
        Task { await store.refreshPlan() }
    }
}
