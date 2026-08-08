import Combine
import Foundation
import WidgetKit

@MainActor
final class PlannerStore: ObservableObject {
    @Published private(set) var tasks: [PlannerTask] = []
    @Published private(set) var dailyPlan: DailyPlan?
    @Published private(set) var completedSteps: [String: Date] = [:]
    @Published private(set) var isPlanning = false
    @Published private(set) var connectionMessage: String?
    @Published private(set) var theme: PlannerTheme = .lotus

    init() {
        theme = PlannerStorage.loadTheme()
        tasks = PlannerStorage.loadTasks()
        dailyPlan = PlannerStorage.loadDailyPlan()
        completedSteps = PlannerStorage.loadCompletedSteps()
        restoreMissingCompletionDates()
        purgeExpiredTasks()
        WidgetCenter.shared.reloadAllTimelines()
    }

    var isConnected: Bool { CodexPlanner.isAvailable }

    /// يبدّل سمة الألوان ويحفظها، ثم يُحدّث الودجت ليطابق التطبيق.
    func toggleTheme() {
        theme = theme.next
        PlannerStorage.saveTheme(theme)
        WidgetCenter.shared.reloadAllTimelines()
    }

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

    func visibleTasks(at date: Date) -> [PlannerTask] {
        tasks
            .filter { $0.isVisible(at: date) }
            .sorted { $0.deadline < $1.deadline }
    }

    func add(title: String, notes: String, deadline: Date, category: TaskCategory) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }

        tasks.append(
            PlannerTask(
                title: cleanTitle,
                deadline: deadline,
                category: category,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        persist()
    }

    func toggle(_ task: PlannerTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].isDone.toggle()
        tasks[index].completedAt = tasks[index].isDone ? .now : nil
        persist()
    }

    func update(_ updatedTask: PlannerTask) {
        guard let index = tasks.firstIndex(where: { $0.id == updatedTask.id }) else { return }
        tasks[index] = updatedTask
        persist()
    }

    func delete(_ task: PlannerTask) {
        tasks.removeAll { $0.id == task.id }
        removePlannedSteps(for: task)
        persist()
    }

    func plannedSteps(on date: Date) -> [PlannedTask] {
        let dateKey = PlannerStorage.dateKey(for: date)
        return dailyPlan?.schedule.filter { $0.scheduledDate == dateKey } ?? []
    }

    func togglePlannedStep(_ step: PlannedTask) {
        PlannerStorage.toggleCompletedStep(step.id)
        completedSteps = PlannerStorage.loadCompletedSteps()
        reconcileParentCompletion()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func reloadCompletedSteps() {
        completedSteps = PlannerStorage.loadCompletedSteps()
        reconcileParentCompletion()
        purgeExpiredTasks()
    }

    func achievements(in month: Date) -> [PlannedTask] {
        guard let schedule = dailyPlan?.schedule else { return [] }
        let calendar = PlannerCalendar.current
        let completedInMonth = Set(completedSteps.compactMap { stepID, completedAt in
            calendar.isDate(completedAt, equalTo: month, toGranularity: .month) ? stepID : nil
        })
        return schedule.filter { completedInMonth.contains($0.id) }
    }

    func refreshPlan() async {
        guard isConnected else {
            connectionMessage = "يلزم فتح Codex وتسجيل الدخول بحساب ChatGPT أولًا."
            return
        }
        guard !pendingTasks.isEmpty else {
            connectionMessage = "لا توجد مهام بعد — التخطيط يبدأ بعد إضافة أول مهمة."
            return
        }

        isPlanning = true
        connectionMessage = nil
        defer { isPlanning = false }
        do {
            let generatedPlan = try await CodexPlanner().createPlan(tasks: pendingTasks, date: .now)
            let mergedPlan = mergeWithPlanHistory(generatedPlan)
            dailyPlan = mergedPlan
            PlannerStorage.saveDailyPlan(mergedPlan)
            WidgetCenter.shared.reloadAllTimelines()
            connectionMessage = "رتّبت يومك، وخطتك جاهزة."
        } catch {
            connectionMessage = error.localizedDescription
        }
    }

    func refreshPlanIfNeeded() async {
        guard isConnected else { return }
        let needsPlan = dailyPlan.map { !PlannerCalendar.current.isDateInToday($0.generatedAt) } ?? true
        if needsPlan { await refreshPlan() }
    }

    private func persist() {
        PlannerStorage.saveTasks(tasks)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func mergeWithPlanHistory(_ generatedPlan: DailyPlan) -> DailyPlan {
        let todayKey = PlannerStorage.dateKey(for: .now)
        let preservedSteps = dailyPlan?.schedule.filter {
            $0.scheduledDate < todayKey || completedSteps[$0.id] != nil
        } ?? []
        let preservedIDs = Set(preservedSteps.map(\.id))
        let newSteps = generatedPlan.schedule.filter { !preservedIDs.contains($0.id) }
        // قد يُنتج النموذج خطوتين متطابقتين في اليوم نفسه، فيتكرر المعرّف
        // ويضطرب عرض ForEach في SwiftUI. نُبقي أول ظهور فقط.
        var seenIDs = Set<String>()
        let mergedSchedule = (preservedSteps + newSteps)
            .filter { seenIDs.insert($0.id).inserted }
            .sorted { ($0.scheduledDate, $0.title) < ($1.scheduledDate, $1.title) }
        return DailyPlan(
            date: generatedPlan.date,
            overview: generatedPlan.overview,
            schedule: mergedSchedule,
            encouragement: generatedPlan.encouragement,
            generatedAt: generatedPlan.generatedAt
        )
    }

    private func removePlannedSteps(for task: PlannerTask) {
        guard let existingPlan = dailyPlan else { return }
        let removedSteps = existingPlan.schedule.filter { $0.taskID == task.id.uuidString }
        let remainingSteps = existingPlan.schedule.filter { $0.taskID != task.id.uuidString }
        let updatedPlan = plan(existingPlan, replacing: remainingSteps)
        dailyPlan = updatedPlan
        for step in removedSteps { completedSteps.removeValue(forKey: step.id) }
        PlannerStorage.saveDailyPlan(updatedPlan)
        PlannerStorage.saveCompletedSteps(completedSteps)
    }

    private func plan(_ existingPlan: DailyPlan, replacing schedule: [PlannedTask]) -> DailyPlan {
        DailyPlan(
            date: existingPlan.date,
            overview: existingPlan.overview,
            schedule: schedule,
            encouragement: existingPlan.encouragement,
            generatedAt: existingPlan.generatedAt
        )
    }

    /// تحذف المهام المنجزة نهائيًا بعد مرور يوم كامل على إنجازها.
    ///
    /// المهمة تبقى ظاهرة ٢٤ ساعة بعد التشييك (انظر `PlannerTask.isVisible(at:)`)،
    /// ثم تُحذف هنا. نحذفها من `tasks` فقط، ونُبقي عمدًا على `completedSteps`
    /// وعلى الخطوات المنجزة داخل الخطة، لأن صفحة «إنجازات الشهر» تُبنى منها —
    /// ولو حذفناها لاختفت إنجازات الشهر مع المهمة.
    private func purgeExpiredTasks(at date: Date = .now) {
        let expiredIDs = Set(
            tasks.filter { !$0.isVisible(at: date) }.map { $0.id.uuidString }
        )
        guard !expiredIDs.isEmpty else { return }

        tasks.removeAll { expiredIDs.contains($0.id.uuidString) }

        // نُزيل الخطوات غير المنجزة للمهام المحذوفة حتى لا تظهر خطوات معلّقة
        // لمهمة لم تعد موجودة، مع الإبقاء على الخطوات المنجزة كسجل إنجاز.
        if let existingPlan = dailyPlan {
            let remainingSteps = existingPlan.schedule.filter {
                !expiredIDs.contains($0.taskID) || completedSteps[$0.id] != nil
            }
            if remainingSteps.count != existingPlan.schedule.count {
                let updatedPlan = plan(existingPlan, replacing: remainingSteps)
                dailyPlan = updatedPlan
                PlannerStorage.saveDailyPlan(updatedPlan)
            }
        }

        persist()
    }

    private func restoreMissingCompletionDates() {
        var changed = false
        for index in tasks.indices where tasks[index].isDone && tasks[index].completedAt == nil {
            tasks[index].completedAt = completionDate(for: tasks[index]) ?? .now
            changed = true
        }
        if changed { persist() }
    }

    private func completionDate(for task: PlannerTask) -> Date? {
        let stepIDs = dailyPlan?.schedule
            .filter { $0.taskID == task.id.uuidString }
            .map(\.id) ?? []
        return stepIDs.compactMap { completedSteps[$0] }.max()
    }

    /// تُكمل المهمة الأم تلقائيًا متى اكتملت كل خطواتها المخططة.
    ///
    /// مهم: هذه الدالة لا تُلغي إنجازًا أبدًا. سابقًا كانت تُزامن الاتجاهين، فإذا أنجزت
    /// المستخدمة المهمة يدويًا بينما بقيت خطوة غير مؤشّرة، كانت الدالة تعيد `isDone`
    /// إلى `false` وتمسح `completedAt` عند عودة التطبيق للنشاط — فيختفي التشييك.
    /// إلغاء الإنجاز الآن بيد المستخدمة وحدها عبر `toggle(_:)`.
    private func reconcileParentCompletion() {
        guard let schedule = dailyPlan?.schedule else { return }
        var changed = false
        for taskIndex in tasks.indices where !tasks[taskIndex].isDone {
            let taskID = tasks[taskIndex].id.uuidString
            let plannedSteps = schedule.filter { $0.taskID == taskID }
            guard !plannedSteps.isEmpty,
                  plannedSteps.allSatisfy({ completedSteps[$0.id] != nil }) else { continue }
            tasks[taskIndex].isDone = true
            tasks[taskIndex].completedAt = plannedSteps.compactMap { completedSteps[$0.id] }.max() ?? .now
            changed = true
        }
        if changed { persist() }
    }
}
