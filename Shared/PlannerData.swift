import Darwin
import Foundation
import OSLog
import SwiftUI

/// سمة الألوان. تُحفظ في التخزين المشترك ليقرأها التطبيق والودجت معًا.
enum PlannerTheme: String, Codable, CaseIterable, Identifiable {
    case lotus
    case stars

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lotus: "لوتس"
        case .stars: "نجوم"
        }
    }

    var symbol: String {
        switch self {
        case .lotus: "🪷"
        case .stars: "🌟"
        }
    }

    /// اللون الأساسي للنصوص والعناصر البارزة.
    var accent: Color {
        switch self {
        case .lotus: Color(red: 0.42, green: 0.11, blue: 0.24)
        case .stars: Color(red: 0.13, green: 0.24, blue: 0.45)
        }
    }

    /// الخلفية الفاتحة للبطاقات.
    var soft: Color {
        switch self {
        case .lotus: Color(red: 0.97, green: 0.90, blue: 0.92)
        case .stars: Color(red: 0.89, green: 0.93, blue: 0.98)
        }
    }

    var next: PlannerTheme {
        self == .lotus ? .stars : .lotus
    }
}

enum TaskCategory: String, Codable, CaseIterable, Identifiable {
    case work
    case personal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .work: "الدوام"
        case .personal: "خارج الدوام"
        }
    }
}

struct PlannerTask: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var deadline: Date
    var durationMinutes: Int
    var category: TaskCategory
    var isDone: Bool
    var notes: String?
    var createdAt: Date?
    var completedAt: Date?
    /// الخطوات الفرعية مملوكة للمهمة الأم نفسها بمعرّفات ثابتة، فلا تختلط
    /// بخطوات مهمة أخرى ولا يضيع تأشيرها عند إعادة التخطيط.
    var subtasks: [PlannerSubtask]
    /// خطوات يقترحها المساعد ولا تُضاف إلا بموافقة المستخدمة.
    var suggestedSubtasks: [PlannerSubtask]
    /// طلبات التخطيط المستخرجة من التفاصيل (المدة، طول الجلسة، التوزيع…).
    var planning: TaskPlanningPreferences?
    /// طلبات التذكير المستخرجة من التفاصيل.
    var reminders: [TaskReminder]
    /// نص التفاصيل الذي فُهم آخر مرة؛ إن تغيّرت التفاصيل تُفهم من جديد.
    var interpretedNotes: String?
    var priority: TaskPriority
    var recurrence: TaskRecurrence
    /// معرّف التذكير المقابل في تطبيق «التذكيرات». nil = لم يُربط بعد،
    /// و"" = حُذف من «التذكيرات» فلا يُعاد إنشاؤه.
    var reminderItemID: String?
    /// آخر حالة إنجاز تمت مزامنتها مع «التذكيرات»، لمعرفة أي طرف تغيّر.
    var reminderLastSyncedDone: Bool?
    /// المعرّف الخارجي الثابت للتذكير (لا يتغير بعد مزامنة iCloud الكاملة).
    var reminderExternalID: String?
    /// للمهام المتكررة: معرّف المهمة التالية التي أُنشئت عند الإنجاز.
    var nextOccurrenceID: UUID?
    /// أول يوم بدء مقترح سُجّل للمهمة، حتى لا يتكرر تذكير البدء كل يوم.
    var startReminderDateKey: String?

    init(
        id: UUID = UUID(),
        title: String,
        deadline: Date,
        durationMinutes: Int = 0,
        category: TaskCategory,
        isDone: Bool = false,
        notes: String? = nil,
        createdAt: Date? = .now,
        subtasks: [PlannerSubtask] = [],
        suggestedSubtasks: [PlannerSubtask] = [],
        planning: TaskPlanningPreferences? = nil,
        reminders: [TaskReminder] = [],
        interpretedNotes: String? = nil,
        priority: TaskPriority = .normal,
        recurrence: TaskRecurrence = .none
    ) {
        self.id = id
        self.title = title
        self.deadline = deadline
        self.durationMinutes = durationMinutes
        self.category = category
        self.isDone = isDone
        self.notes = notes
        self.createdAt = createdAt
        self.completedAt = nil
        self.subtasks = subtasks
        self.suggestedSubtasks = suggestedSubtasks
        self.planning = planning
        self.reminders = reminders
        self.interpretedNotes = interpretedNotes
        self.priority = priority
        self.recurrence = recurrence
        self.reminderItemID = nil
        self.reminderLastSyncedDone = nil
        self.reminderExternalID = nil
        self.nextOccurrenceID = nil
        self.startReminderDateKey = nil
    }

    var trimmedNotes: String {
        (notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// تحتاج التفاصيل إلى فهم إن وُجدت ولم تُفهم بنصها الحالي بعد.
    var needsInterpretation: Bool {
        !isDone && !trimmedNotes.isEmpty && interpretedNotes != trimmedNotes
    }

    /// المهمة المنجزة تبقى في القائمة النشطة يومًا واحدًا ثم تنتقل إلى
    /// السجل (إنجازات الشهر). لا تُحذف من التخزين أبدًا.
    func isVisible(at date: Date) -> Bool {
        guard isDone, let completedAt else { return true }
        return date < completedAt.addingTimeInterval(86_400)
    }

    var completedSubtaskCount: Int {
        subtasks.filter(\.isDone).count
    }

    /// الخطوات مرتبة بحسب يومها، والخطوات بلا يوم في آخر القائمة.
    var orderedSubtasks: [PlannerSubtask] {
        subtasks.enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element.scheduledDate ?? "9999-99-99"
                let right = rhs.element.scheduledDate ?? "9999-99-99"
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
    }
}

extension PlannerTask {
    /// فك ترميز متوافق مع الملفات القديمة التي لا تحتوي `subtasks`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        deadline = try container.decode(Date.self, forKey: .deadline)
        durationMinutes = try container.decodeIfPresent(Int.self, forKey: .durationMinutes) ?? 0
        category = try container.decode(TaskCategory.self, forKey: .category)
        isDone = try container.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        subtasks = try container.decodeIfPresent([PlannerSubtask].self, forKey: .subtasks) ?? []
        suggestedSubtasks = try container.decodeIfPresent([PlannerSubtask].self, forKey: .suggestedSubtasks) ?? []
        planning = try container.decodeIfPresent(TaskPlanningPreferences.self, forKey: .planning)
        reminders = try container.decodeIfPresent([TaskReminder].self, forKey: .reminders) ?? []
        interpretedNotes = try container.decodeIfPresent(String.self, forKey: .interpretedNotes)
        priority = try container.decodeIfPresent(TaskPriority.self, forKey: .priority) ?? .normal
        recurrence = try container.decodeIfPresent(TaskRecurrence.self, forKey: .recurrence) ?? .none
        reminderItemID = try container.decodeIfPresent(String.self, forKey: .reminderItemID)
        reminderLastSyncedDone = try container.decodeIfPresent(Bool.self, forKey: .reminderLastSyncedDone)
        reminderExternalID = try container.decodeIfPresent(String.self, forKey: .reminderExternalID)
        nextOccurrenceID = try container.decodeIfPresent(UUID.self, forKey: .nextOccurrenceID)
        startReminderDateKey = try container.decodeIfPresent(String.self, forKey: .startReminderDateKey)
    }
}

enum TaskPriority: String, Codable, CaseIterable, Identifiable {
    case high
    case normal
    case low

    var id: String { rawValue }

    var title: String {
        switch self {
        case .high: "عالية"
        case .normal: "متوسطة"
        case .low: "منخفضة"
        }
    }

    var rank: Int {
        switch self {
        case .high: 2
        case .normal: 1
        case .low: 0
        }
    }
}

enum TaskRecurrence: String, Codable, CaseIterable, Identifiable {
    case none
    case weekly
    case monthly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "بلا تكرار"
        case .weekly: "أسبوعيًا"
        case .monthly: "شهريًا"
        }
    }
}

/// مزوّد الذكاء الاصطناعي المحلي.
enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: "Codex (ChatGPT)"
        case .claude: "Claude"
        }
    }

    var defaultModel: String {
        switch self {
        case .codex: "gpt-5.6-luna"
        case .claude: "sonnet"
        }
    }

    var suggestedModels: [String] {
        switch self {
        case .codex: ["gpt-5.6-luna"]
        case .claude: ["sonnet", "opus", "haiku"]
        }
    }
}

/// إعدادات التطبيق. كل حقل له قيمة افتراضية، فالملف القديم أو الناقص يُقرأ بأمان.
struct PlannerSettings: Codable, Equatable {
    var provider: AIProvider = .codex
    var codexModel: String = AIProvider.codex.defaultModel
    var claudeModel: String = AIProvider.claude.defaultModel

    var notificationsEnabled = true
    var dailySummaryEnabled = true
    /// وقت ملخص الصباح بالدقائق من منتصف الليل.
    var dailySummaryMinutes = 8 * 60
    var appointmentRemindersEnabled = true
    var appointmentLeadMinutes = 15
    var startRemindersEnabled = true
    var deadlineRemindersEnabled = true
    /// الوقت الافتراضي لتذكيرات البدء والمواعيد النهائية.
    var reminderTimeMinutes = 9 * 60

    /// أقصى وقت عمل مقترح يوميًا لكل قسم بالدقائق.
    var workCapacityMinutes = 5 * 60
    var personalCapacityMinutes = 2 * 60

    var calendarSyncEnabled = false
    /// التقاويم المعروضة؛ القائمة الفارغة تعني كل التقاويم.
    var selectedCalendarIDs: [String] = []
    var remindersSyncEnabled = false
    /// تذكيرات لا تُستورد كمهام (مثل تذكيرات المهام الممسوحة عند «البدء من جديد»).
    var ignoredReminderIDs: [String] = []

    init() {}

    func model(for provider: AIProvider) -> String {
        let model = (provider == .codex ? codexModel : claudeModel)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? provider.defaultModel : model
    }

    func capacity(for category: TaskCategory) -> Int {
        category == .work ? workCapacityMinutes : personalCapacityMinutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PlannerSettings()
        provider = (try? container.decodeIfPresent(AIProvider.self, forKey: .provider)) ?? defaults.provider
        codexModel = (try? container.decodeIfPresent(String.self, forKey: .codexModel)) ?? defaults.codexModel
        claudeModel = (try? container.decodeIfPresent(String.self, forKey: .claudeModel)) ?? defaults.claudeModel
        notificationsEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled)) ?? defaults.notificationsEnabled
        dailySummaryEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .dailySummaryEnabled)) ?? defaults.dailySummaryEnabled
        dailySummaryMinutes = (try? container.decodeIfPresent(Int.self, forKey: .dailySummaryMinutes)) ?? defaults.dailySummaryMinutes
        appointmentRemindersEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .appointmentRemindersEnabled)) ?? defaults.appointmentRemindersEnabled
        appointmentLeadMinutes = (try? container.decodeIfPresent(Int.self, forKey: .appointmentLeadMinutes)) ?? defaults.appointmentLeadMinutes
        startRemindersEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .startRemindersEnabled)) ?? defaults.startRemindersEnabled
        deadlineRemindersEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .deadlineRemindersEnabled)) ?? defaults.deadlineRemindersEnabled
        reminderTimeMinutes = (try? container.decodeIfPresent(Int.self, forKey: .reminderTimeMinutes)) ?? defaults.reminderTimeMinutes
        workCapacityMinutes = (try? container.decodeIfPresent(Int.self, forKey: .workCapacityMinutes)) ?? defaults.workCapacityMinutes
        personalCapacityMinutes = (try? container.decodeIfPresent(Int.self, forKey: .personalCapacityMinutes)) ?? defaults.personalCapacityMinutes
        calendarSyncEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .calendarSyncEnabled)) ?? defaults.calendarSyncEnabled
        selectedCalendarIDs = (try? container.decodeIfPresent([String].self, forKey: .selectedCalendarIDs)) ?? defaults.selectedCalendarIDs
        remindersSyncEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .remindersSyncEnabled)) ?? defaults.remindersSyncEnabled
        ignoredReminderIDs = (try? container.decodeIfPresent([String].self, forKey: .ignoredReminderIDs)) ?? defaults.ignoredReminderIDs
    }
}

/// ما يعرضه الودجت من خارج ملف المهام (الموعد القادم ومهمة اليوم).
struct WidgetSnapshot: Codable {
    var nextAppointmentTitle: String?
    var nextAppointmentStart: Date?
    var focusTaskTitle: String?
}

/// ما طلبته المستخدمة صراحةً في التفاصيل بشأن تخطيط المهمة.
/// تُحفظ الآن وتستخدمها جدولة المرحلة الثانية.
struct TaskPlanningPreferences: Codable, Hashable {
    var effortMinutes: Int?
    var minSessionMinutes: Int?
    var spreadOverDays: Int?
    /// أول يوم يمكن البدء فيه بصيغة yyyy-MM-dd.
    var earliestStart: String?

    var isEmpty: Bool {
        effortMinutes == nil && minSessionMinutes == nil && spreadOverDays == nil && earliestStart == nil
    }

    /// وصف عربي قصير يظهر على بطاقة المهمة.
    var summary: String {
        var parts: [String] = []
        if let effortMinutes { parts.append("الجهد \(Self.durationText(effortMinutes))") }
        if let minSessionMinutes { parts.append("جلسات من \(Self.durationText(minSessionMinutes))") }
        if let spreadOverDays { parts.append("على \(spreadOverDays) أيام") }
        if let earliestStart, let date = PlannerStorage.date(fromKey: earliestStart) {
            parts.append("البدء من \(PlannerCalendar.text(for: date, format: "d MMM"))")
        }
        return parts.joined(separator: " · ")
    }

    static func durationText(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) دقيقة" }
        let hours = Double(minutes) / 60
        return hours == hours.rounded()
            ? "\(Int(hours)) ساعة"
            : String(format: "%.1f ساعة", hours)
    }
}

/// تذكير طلبته المستخدمة في التفاصيل. يُعرض على البطاقة الآن،
/// ويتحول إلى إشعار فعلي في مرحلة الإشعارات.
struct TaskReminder: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    /// وصف التذكير كما فُهم، مثل «قبل الموعد بيوم».
    var label: String
    /// كم دقيقة قبل الموعد النهائي (إن كان التذكير نسبيًا).
    var minutesBeforeDeadline: Int?
    /// وقت محدد بصيغة yyyy-MM-dd HH:mm (إن كان التذكير بتاريخ معيّن).
    var dateTime: String?
}

/// خطوة فرعية تابعة لمهمة رئيسية واحدة.
struct PlannerSubtask: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var note: String
    var estimatedMinutes: Int?
    /// اليوم المخطط بصيغة yyyy-MM-dd، أو nil إن لم يُحدد لها يوم بعد.
    var scheduledDate: String?
    var isDone: Bool
    var completedAt: Date?
    /// هل استُخرجت الخطوة من التفاصيل؟ عند تعديل التفاصيل تُستبدل هذه الخطوات
    /// (غير المنجزة) فقط، وتبقى الخطوات اليدوية والمقبولة من الاقتراحات كما هي.
    var fromNotes: Bool

    init(
        id: UUID = UUID(),
        title: String,
        note: String = "",
        estimatedMinutes: Int? = nil,
        scheduledDate: String? = nil,
        isDone: Bool = false,
        completedAt: Date? = nil,
        fromNotes: Bool = false
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.estimatedMinutes = estimatedMinutes
        self.scheduledDate = scheduledDate
        self.isDone = isDone
        self.completedAt = completedAt
        self.fromNotes = fromNotes
    }
}

extension PlannerSubtask {
    /// فك ترميز متوافق مع الخطوات المحفوظة قبل إضافة `fromNotes`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        estimatedMinutes = try container.decodeIfPresent(Int.self, forKey: .estimatedMinutes)
        scheduledDate = try container.decodeIfPresent(String.self, forKey: .scheduledDate)
        isDone = try container.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        fromNotes = try container.decodeIfPresent(Bool.self, forKey: .fromNotes) ?? false
    }
}

struct PlannedTask: Codable, Identifiable, Hashable {
    let taskID: String
    let title: String
    let scheduledDate: String
    let category: String
    let note: String
    let estimatedMinutes: Int?

    var id: String { "\(taskID)-\(scheduledDate)-\(title)" }
}

struct PlannerAchievement: Codable, Identifiable, Hashable {
    let taskID: String
    let title: String
    let completedAt: Date

    var id: String { taskID }
}

enum PlannerCalendar {
    static var current: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ar_SA@calendar=gregorian")
        calendar.timeZone = .current
        calendar.firstWeekday = 1
        return calendar
    }

    static var locale: Locale {
        Locale(identifier: "ar_SA@calendar=gregorian")
    }

    static func text(for date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = current
        formatter.locale = locale
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

struct DailyPlan: Codable, Hashable {
    let date: String
    let overview: String
    let schedule: [PlannedTask]
    let encouragement: String
    let generatedAt: Date
}

enum PlannerStorage {
    static let suiteName = "group.com.shatha.lotusplanner"
    private static let tasksKey = "planner.tasks.v1"
    private static let dailyPlanKey = "planner.daily-plan.v1"
    private static let completedStepsKey = "planner.completed-steps.v1"
    private static let themeKey = "planner.theme.v1"
    private static let logger = Logger(subsystem: "com.shatha.lotusplanner", category: "storage")

    private static let accountHomeURL: URL = {
        guard let account = getpwuid(getuid()) else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: account.pointee.pw_dir), isDirectory: true)
    }()

    private static let storageDirectoryURL = accountHomeURL
        .appendingPathComponent("Library/Application Support/KhutayPlanner", isDirectory: true)
    private static let tasksURL = storageDirectoryURL.appendingPathComponent("tasks.json")
    private static let dailyPlanURL = storageDirectoryURL.appendingPathComponent("daily-plan.json")
    private static let completedStepsURL = storageDirectoryURL.appendingPathComponent("completed-steps.json")
    private static let themeURL = storageDirectoryURL.appendingPathComponent("theme.json")
    private static let achievementsURL = storageDirectoryURL.appendingPathComponent("achievements.json")
    private static let widgetTaskPageURL = storageDirectoryURL.appendingPathComponent("widget-task-page.json")
    private static let settingsURL = storageDirectoryURL.appendingPathComponent("settings.json")
    private static let widgetSnapshotURL = storageDirectoryURL.appendingPathComponent("widget-snapshot.json")

    static let wisdoms: [(text: String, source: String)] = [
        ("لَيَغْلِبَنَّ لُطْفُهُ خَوْفِي", "تذكير للقلب"),
        ("إِنَّ مَعَ الْعُسْرِ يُسْرًا", "سورة الشرح · ٦"),
        ("ما فاتك لم يُخلق لك، وما خُلق لك لن يفوتك", "تذكير بالطمأنينة"),
        ("يُدَبِّرُ الْأَمْرَ مِنَ السَّمَاءِ إِلَى الْأَرْضِ", "سورة السجدة · ٥"),
        ("اللهم بارك لنا في الخطوة والقرار، وفي الطريق والرفيق", "دعاء"),
        ("فَإِنَّكَ بِأَعْيُنِنَا", "سورة الطور · ٤٨"),
        ("وَجَعَلَنِي مُبَارَكًا أَيْنَ مَا كُنْتُ", "سورة مريم · ٣١"),
        ("قَدْ جَعَلَهَا رَبِّي حَقًّا", "سورة يوسف · ١٠٠"),
        ("وتشاءُ أنتَ من الأماني نجمةً، ويشاءُ ربُّكَ أن يُناولكَ القمر", "عبارة ملهمة"),
        ("إِذا غامَرتَ في شَرَفٍ مَرومٍ، فَلا تَقنَعْ بما دونَ النُّجومِ", "أبو الطيب المتنبي")
    ]

    private static var legacyDefaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func loadTasks() -> [PlannerTask] {
        if let tasks: [PlannerTask] = migratedValue(from: tasksURL, legacyKey: tasksKey) {
            return tasks
        }
        // الملف موجود لكن تعذرت قراءته: نحفظ نسخة منه قبل أي كتابة جديدة حتى لا يضيع.
        if FileManager.default.fileExists(atPath: tasksURL.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            let backupURL = storageDirectoryURL.appendingPathComponent("tasks.unreadable-\(stamp).json")
            try? FileManager.default.copyItem(at: tasksURL, to: backupURL)
            logger.error("تعذرت قراءة ملف المهام؛ حُفظت نسخة منه باسم \(backupURL.lastPathComponent, privacy: .public)")
        }
        return []
    }

    @discardableResult
    static func saveTasks(_ tasks: [PlannerTask]) -> Bool {
        write(tasks, to: tasksURL)
    }

    static func loadDailyPlan() -> DailyPlan? {
        migratedValue(from: dailyPlanURL, legacyKey: dailyPlanKey)
    }

    static func saveDailyPlan(_ plan: DailyPlan) {
        write(plan, to: dailyPlanURL)
    }

    /// نسخة احتياطية لمرة واحدة من ملفات الخطة والمهام قبل ترحيلها إلى
    /// نموذج الخطوات الفرعية، حتى يمكن الرجوع إليها إن احتجنا.
    static func backupBeforeSubtaskMigration() {
        let fileManager = FileManager.default
        for sourceURL in [dailyPlanURL, tasksURL, completedStepsURL] {
            let backupURL = sourceURL.deletingPathExtension()
                .appendingPathExtension("before-subtasks.json")
            guard fileManager.fileExists(atPath: sourceURL.path),
                  !fileManager.fileExists(atPath: backupURL.path) else { continue }
            do {
                try fileManager.copyItem(at: sourceURL, to: backupURL)
            } catch {
                logger.error("تعذر إنشاء نسخة احتياطية: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func loadCompletedSteps() -> [String: Date] {
        migratedValue(from: completedStepsURL, legacyKey: completedStepsKey) ?? [:]
    }

    static func saveCompletedSteps(_ completedSteps: [String: Date]) {
        write(completedSteps, to: completedStepsURL)
    }

    static func loadAchievements() -> [PlannerAchievement] {
        read(from: achievementsURL) ?? []
    }

    static func saveAchievements(_ achievements: [PlannerAchievement]) {
        write(achievements, to: achievementsURL)
    }

    private struct StoredWidgetTaskPage: Codable {
        let page: Int
    }

    static func loadWidgetTaskPage() -> Int {
        let storedPage: StoredWidgetTaskPage? = read(from: widgetTaskPageURL)
        return max(0, storedPage?.page ?? 0)
    }

    static func saveWidgetTaskPage(_ page: Int) {
        write(StoredWidgetTaskPage(page: max(0, page)), to: widgetTaskPageURL)
    }

    /// نغلّف السمة داخل كائن بدلًا من حفظها كقيمة مفردة، لأن الترميز المباشر
    /// لقيمة واحدة في أعلى ملف JSON قد يفشل بصمت فلا تُحفظ السمة أبدًا.
    private struct StoredTheme: Codable {
        let theme: PlannerTheme
    }

    static func loadTheme() -> PlannerTheme {
        let stored: StoredTheme? = migratedValue(from: themeURL, legacyKey: themeKey)
        return stored?.theme ?? .lotus
    }

    static func saveTheme(_ theme: PlannerTheme) {
        write(StoredTheme(theme: theme), to: themeURL)
    }

    static func loadSettings() -> PlannerSettings {
        read(from: settingsURL) ?? PlannerSettings()
    }

    static func saveSettings(_ settings: PlannerSettings) {
        write(settings, to: settingsURL)
    }

    static func loadWidgetSnapshot() -> WidgetSnapshot {
        read(from: widgetSnapshotURL) ?? WidgetSnapshot()
    }

    static func saveWidgetSnapshot(_ snapshot: WidgetSnapshot) {
        write(snapshot, to: widgetSnapshotURL)
    }

    /// البدء من جديد: يمسح المهام والخطوات والخطط والإنجازات والنسخ القديمة منها،
    /// ويُبقي السمة والإعدادات. لا يحدث إلا بطلب صريح من الإعدادات.
    static func resetAllTaskData() {
        let fileManager = FileManager.default
        for key in [tasksKey, dailyPlanKey, completedStepsKey] {
            legacyDefaults.removeObject(forKey: key)
        }
        // ملف مهام فارغ (بدل حذفه) حتى لا يُعاد تحميل أي نسخة قديمة.
        write([PlannerTask](), to: tasksURL)
        let keep: Set<String> = [tasksURL.lastPathComponent, themeURL.lastPathComponent, settingsURL.lastPathComponent]
        let files = (try? fileManager.contentsOfDirectory(at: storageDirectoryURL, includingPropertiesForKeys: nil)) ?? []
        for file in files where !keep.contains(file.lastPathComponent) {
            try? fileManager.removeItem(at: file)
        }
    }

    static func toggleCompletedStep(_ stepID: String) {
        var completedSteps = loadCompletedSteps()
        if completedSteps[stepID] == nil {
            completedSteps[stepID] = .now
        } else {
            completedSteps.removeValue(forKey: stepID)
        }
        write(completedSteps, to: completedStepsURL)
    }

    private static func migratedValue<Value: Codable>(from fileURL: URL, legacyKey: String) -> Value? {
        if let storedValue: Value = read(from: fileURL) {
            // بعد نقل البيانات إلى الملفات لم يعد للنسخة القديمة داخل
            // UserDefaults حاجة؛ نزيلها حتى لا تعود بيانات قديمة لاحقًا.
            if legacyDefaults.object(forKey: legacyKey) != nil {
                legacyDefaults.removeObject(forKey: legacyKey)
            }
            return storedValue
        }
        guard let legacyData = legacyDefaults.data(forKey: legacyKey),
              let legacyValue = try? JSONDecoder().decode(Value.self, from: legacyData) else { return nil }
        write(legacyValue, to: fileURL)
        return legacyValue
    }

    private static func read<Value: Decodable>(from fileURL: URL) -> Value? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            return try JSONDecoder().decode(Value.self, from: Data(contentsOf: fileURL))
        } catch {
            logger.error("تعذر قراءة التخزين المحلي: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    @discardableResult
    private static func write<Value: Encodable>(_ storedValue: Value, to fileURL: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: storageDirectoryURL, withIntermediateDirectories: true)
            try JSONEncoder().encode(storedValue).write(to: fileURL, options: .atomic)
            return true
        } catch {
            logger.error("تعذر حفظ التخزين المحلي: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// منسّق مفاتيح الأيام يُنشأ مرة واحدة (يُستدعى كثيرًا عند رسم التقويم).
    /// DateFormatter آمن للاستخدام من عدة خيوط في أنظمة Apple الحديثة.
    nonisolated(unsafe) private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()

    static func dateKey(for date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    /// عكس `dateKey`: يحوّل yyyy-MM-dd إلى تاريخ، أو nil إن كانت الصيغة غير صالحة.
    static func date(fromKey key: String) -> Date? {
        dayKeyFormatter.date(from: key)
    }

    static func wisdom(for date: Date) -> (text: String, source: String) {
        let hour = Int(date.timeIntervalSince1970 / 3_600)
        return wisdoms[abs(hour) % wisdoms.count]
    }
}
