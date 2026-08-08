import AppIntents
import SwiftUI
import WidgetKit

struct TogglePlannedStepIntent: AppIntent {
    static let title: LocalizedStringResource = "تحديث إنجاز المهمة"
    static let openAppWhenRun = false

    @Parameter(title: "معرّف الخطوة")
    var stepID: String

    init() {}

    init(stepID: String) {
        self.stepID = stepID
    }

    func perform() async throws -> some IntentResult {
        PlannerStorage.toggleCompletedStep(stepID)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct LotusEntry: TimelineEntry {
    let date: Date
    let tasks: [PlannerTask]
    let plan: DailyPlan?
    let completedSteps: [String: Date]
    let wisdom: (text: String, source: String)
    let theme: PlannerTheme
}

struct LotusProvider: TimelineProvider {
    func placeholder(in context: Context) -> LotusEntry {
        LotusEntry(
            date: .now,
            tasks: [
                PlannerTask(title: "مهمتك التالية", deadline: .now.addingTimeInterval(3_600), category: .work)
            ],
            plan: nil,
            completedSteps: [:],
            wisdom: PlannerStorage.wisdom(for: .now),
            theme: PlannerStorage.loadTheme()
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (LotusEntry) -> Void) {
        completion(entry(for: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LotusEntry>) -> Void) {
        let now = Date.now
        let entry = entry(for: now)
        let nextHour = PlannerCalendar.current.nextDate(
            after: now,
            matching: DateComponents(minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(3_600)
        completion(Timeline(entries: [entry], policy: .after(nextHour)))
    }

    private func entry(for date: Date) -> LotusEntry {
        // نستبعد المنجزة حتى يعكس الودجت المتبقّي فعلًا. سابقًا كان يكتفي بـ
        // `isVisible` التي تُبقي المهمة المنجزة ظاهرة ٢٤ ساعة، فكان العدّاد
        // يحسبها ضمن المتبقّي ولا ينقص أبدًا. التطبيق يستبعدها عبر `pendingTasks`،
        // وهذا يوحّد سلوك الاثنين.
        let upcoming = PlannerStorage.loadTasks()
            .filter { !$0.isDone && $0.isVisible(at: date) }
            .sorted { $0.deadline < $1.deadline }

        return LotusEntry(
            date: date,
            tasks: upcoming,
            plan: PlannerStorage.loadDailyPlan(),
            completedSteps: PlannerStorage.loadCompletedSteps(),
            wisdom: PlannerStorage.wisdom(for: date),
            theme: PlannerStorage.loadTheme()
        )
    }
}

struct LotusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LotusEntry

    private var accent: Color { entry.theme.accent }
    private var soft: Color { entry.theme.soft }

    private var todaySteps: [PlannedTask] {
        let todayKey = PlannerStorage.dateKey(for: .now)
        return entry.plan?.schedule.filter { $0.scheduledDate == todayKey } ?? []
    }

    /// عدد خطوات اليوم غير المؤشّرة. يُستعمل فقط حين توجد خطة لليوم.
    private var remainingTodayCount: Int {
        todaySteps.filter { entry.completedSteps[$0.id] == nil }.count
    }

    private var taskCountTitle: String {
        switch remainingTodayCount {
        case 0: "اكتملت خطوات اليوم ✨"
        case 1: "بقيت خطوة واحدة اليوم"
        case 2: "بقيت خطوتان اليوم"
        default: "بقيت \(remainingTodayCount) خطوات اليوم"
        }
    }

    /// ملخص المهام القادمة حين لا توجد خطة لليوم.
    private var upcomingTitle: String {
        switch entry.tasks.count {
        case 1: "مهمة واحدة قادمة"
        case 2: "مهمتان قادمتان"
        default: "\(entry.tasks.count) مهام قادمة"
        }
    }

    private func deadlineText(for date: Date) -> String {
        let calendar = PlannerCalendar.current
        if calendar.isDateInToday(date) { return "اليوم" }
        if calendar.isDateInTomorrow(date) { return "غدًا" }
        if date < entry.date { return "متأخرة" }
        let days = calendar.dateComponents([.day], from: entry.date, to: date).day ?? 0
        return days <= 6
            ? PlannerCalendar.text(for: date, format: "EEEE")
            : PlannerCalendar.text(for: date, format: "d MMM")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 7 : 9) {
                HStack {
                    Text(entry.theme.symbol)
                    Text("خُطاي")
                        .font(.headline.weight(.semibold))
                    Spacer()
                }

                if !todaySteps.isEmpty {
                    taskSummary
                    ForEach(Array(todaySteps.prefix(family == .systemSmall ? 2 : 3))) { plannedTask in
                        planLine(plannedTask)
                    }
                    Spacer(minLength: 0)
                } else if entry.tasks.isEmpty {
                    Spacer()
                    Text("يومك هادئ الآن")
                        .font(.subheadline.weight(.medium))
                    Text("في انتظار أول مهمة")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    upcomingSummary
                    Spacer(minLength: 0)
                }

                Divider()
                Text(entry.wisdom.text)
                    .font(.caption.weight(.semibold))
                    .lineLimit(family == .systemSmall ? 2 : 1)
                    .foregroundStyle(accent)
                Text(entry.wisdom.source)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(2)
            .environment(\.layoutDirection, .rightToLeft)
        .widgetURL(URL(string: "lotusplanner://open"))
        .containerBackground(soft.gradient, for: .widget)
    }

    private var taskSummary: some View {
        HStack(spacing: 6) {
            Image(systemName: remainingTodayCount == 0 ? "checkmark.circle.fill" : "sparkles")
            Text(taskCountTitle)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    /// يُعرض حين لا توجد خطة لليوم.
    ///
    /// سابقًا كان الودجت يسرد المهام هنا بلا مربع تشييك ولا خط شطب وتحت عنوان
    /// «مهام اليوم»، فتبدو جامدة ومضلِّلة لأنها قد تكون لمواعيد بعيدة. صار
    /// يعرض بدلها معلومة صادقة: كم مهمة قادمة، ومتى أقرب موعد.
    private var upcomingSummary: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                Text(upcomingTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            // سطر واحد مضغوط: عنوان أقرب مهمة وموعدها. أي أسطر إضافية هنا
            // تتجاوز ارتفاع الودجت فتدفع الهيدر خارج الإطار.
            if let nearest = entry.tasks.first {
                HStack(spacing: 6) {
                    Circle()
                        .fill(accent)
                        .frame(width: 5, height: 5)
                    Text(nearest.title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text("· \(deadlineText(for: nearest.deadline))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func planLine(_ task: PlannedTask) -> some View {
        HStack(spacing: 7) {
            Button(intent: TogglePlannedStepIntent(stepID: task.id)) {
                Image(systemName: entry.completedSteps[task.id] == nil ? "circle" : "checkmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(accent)
            Text(task.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

struct LotusPlannerWidget: Widget {
    let kind = "DreamDateWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LotusProvider()) { entry in
            LotusWidgetView(entry: entry)
        }
        .configurationDisplayName("خُطاي")
        .description("مهامك اليومية مرتبة مع عبارة تتجدد كل ساعة.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct LotusPlannerWidgetBundle: WidgetBundle {
    var body: some Widget {
        LotusPlannerWidget()
    }
}
