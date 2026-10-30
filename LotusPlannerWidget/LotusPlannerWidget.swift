import AppIntents
import SwiftUI
import WidgetKit

struct SetWidgetTaskPageIntent: AppIntent {
    static let title: LocalizedStringResource = "تمرير المهام"
    static let openAppWhenRun = false

    @Parameter(title: "رقم الصفحة")
    var page: Int

    init() {}

    init(page: Int) {
        self.page = page
    }

    func perform() async throws -> some IntentResult {
        PlannerStorage.saveWidgetTaskPage(page)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct LotusEntry: TimelineEntry {
    let date: Date
    let tasks: [PlannerTask]
    let widgetTaskPage: Int
    let wisdom: (text: String, source: String)
    let theme: PlannerTheme
    var snapshot = WidgetSnapshot()
}

struct LotusProvider: TimelineProvider {
    func placeholder(in context: Context) -> LotusEntry {
        LotusEntry(
            date: .now,
            tasks: [
                PlannerTask(title: "مهمتك التالية", deadline: .now.addingTimeInterval(3_600), category: .work)
            ],
            widgetTaskPage: 0,
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
            widgetTaskPage: PlannerStorage.loadWidgetTaskPage(),
            wisdom: PlannerStorage.wisdom(for: date),
            theme: PlannerStorage.loadTheme(),
            snapshot: PlannerStorage.loadWidgetSnapshot()
        )
    }
}

struct LotusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LotusEntry

    private var accent: Color { entry.theme.accent }
    private var soft: Color { entry.theme.soft }

    private var hasUpcomingAppointment: Bool {
        guard entry.snapshot.nextAppointmentTitle != nil,
              let start = entry.snapshot.nextAppointmentStart else { return false }
        return start > entry.date
    }

    /// عدد المهام الظاهرة في نافذة التمرير بحسب حجم الودجت.
    private var visibleCount: Int {
        switch family {
        case .systemSmall: hasUpcomingAppointment ? 1 : 2
        case .systemLarge: hasUpcomingAppointment ? 8 : 9
        default: hasUpcomingAppointment ? 1 : 2
        }
    }

    /// أول مهمة ظاهرة. الودجت لا يدعم التمرير الحر في macOS، فالسهمان يمرّران مهمةً مهمة
    /// بينما يبقى العنوان والعبارة ثابتين في الأعلى.
    private var scrollOffset: Int {
        min(max(0, entry.widgetTaskPage), max(0, entry.tasks.count - visibleCount))
    }

    private var canScrollUp: Bool { scrollOffset > 0 }
    private var canScrollDown: Bool { scrollOffset + visibleCount < entry.tasks.count }

    private var visibleTasks: [PlannerTask] {
        Array(entry.tasks.dropFirst(scrollOffset).prefix(visibleCount))
    }

    private var mainTaskCountTitle: String {
        switch entry.tasks.count {
        case 1: "مهمة رئيسية واحدة"
        case 2: "مهمتان رئيسيتان"
        default: "\(entry.tasks.count) مهام رئيسية"
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
        VStack(alignment: .leading, spacing: 0) {
            // ١) أعلى ثابت: العنوان والعبارة.
            fixedHeader
                .layoutPriority(2)
                .padding(.bottom, 6)

            // ٢) الوسط وحده يتغير: المهام تُمرَّر بالسهمين داخل مساحتها.
            taskArea
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()

            // ٣) أسفل ثابت: العبارة المتجددة.
            if family != .systemSmall {
                fixedFooter
                    .layoutPriority(2)
                    .padding(.top, 4)
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        // الوضع الفاتح دائمًا مثل التطبيق.
        .environment(\.colorScheme, .light)
        .widgetURL(URL(string: "khutaiapp://open"))
        .containerBackground(soft.gradient, for: .widget)
    }

    @ViewBuilder
    private var taskArea: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 4 : 5) {
            nextAppointmentLine
            if entry.tasks.isEmpty {
                Text("يومك هادئ الآن، في انتظار أول مهمة")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else {
                mainTaskSummary
                ForEach(visibleTasks) { task in
                    mainTaskLine(task)
                }
            }
        }
    }

    private var fixedFooter: some View {
        VStack(alignment: .leading, spacing: 1) {
            Divider()
                .padding(.bottom, 3)
            Text(entry.wisdom.text)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(accent)
            if family == .systemLarge {
                Text(entry.wisdom.source)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var fixedHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(entry.theme.symbol)
                Text("خُطاي")
                    .font(.headline.weight(.semibold))
                Spacer(minLength: 0)
            }
            Text("If you aim, aim at the stars. So, if you miss, you land on the moon.")
                .font(.system(size: family == .systemSmall ? 9 : 10, weight: .semibold))
                .foregroundStyle(accent)
                .lineLimit(family == .systemSmall ? 2 : 1)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.leading)
                .environment(\.layoutDirection, .leftToRight)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// الموعد القادم من التقويم (إن وُجد ولم يبدأ بعد).
    @ViewBuilder
    private var nextAppointmentLine: some View {
        if let title = entry.snapshot.nextAppointmentTitle,
           let start = entry.snapshot.nextAppointmentStart,
           start > entry.date {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .foregroundStyle(accent)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(PlannerCalendar.current.isDateInToday(start)
                     ? PlannerCalendar.text(for: start, format: "h:mm a")
                     : PlannerCalendar.text(for: start, format: "EEE h:mm a"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var mainTaskSummary: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet.rectangle")
            Text(mainTaskCountTitle)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            if canScrollUp || canScrollDown { scrollControls }
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }

    /// سهما التمرير: مهمة للأعلى أو للأسفل.
    private var scrollControls: some View {
        HStack(spacing: 6) {
            Button(intent: SetWidgetTaskPageIntent(page: max(0, scrollOffset - 1))) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(!canScrollUp)
            .opacity(canScrollUp ? 1 : 0.3)
            .accessibilityLabel("تمرير للأعلى")

            Text("\(scrollOffset + 1) إلى \(min(scrollOffset + visibleCount, entry.tasks.count))")
                .font(.caption2.monospacedDigit())

            Button(intent: SetWidgetTaskPageIntent(page: scrollOffset + 1)) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(!canScrollDown)
            .opacity(canScrollDown ? 1 : 0.3)
            .accessibilityLabel("تمرير للأسفل")
        }
    }

    /// سطر مهمة واحد مضغوط: نقطة والعنوان، ثم موعدها.
    private func mainTaskLine(_ task: PlannerTask) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(accent)
                .frame(width: 5, height: 5)
            Text(task.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(deadlineText(for: task.deadline))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
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
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct LotusPlannerWidgetBundle: WidgetBundle {
    var body: some Widget {
        LotusPlannerWidget()
    }
}
