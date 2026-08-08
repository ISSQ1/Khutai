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

    init(
        id: UUID = UUID(),
        title: String,
        deadline: Date,
        durationMinutes: Int = 0,
        category: TaskCategory,
        isDone: Bool = false,
        notes: String? = nil,
        createdAt: Date? = .now
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
    }

    func isVisible(at date: Date) -> Bool {
        guard isDone, let completedAt else { return true }
        return date < completedAt.addingTimeInterval(86_400)
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
        migratedValue(from: tasksURL, legacyKey: tasksKey) ?? []
    }

    static func saveTasks(_ tasks: [PlannerTask]) {
        write(tasks, to: tasksURL)
    }

    static func loadDailyPlan() -> DailyPlan? {
        migratedValue(from: dailyPlanURL, legacyKey: dailyPlanKey)
    }

    static func saveDailyPlan(_ plan: DailyPlan) {
        write(plan, to: dailyPlanURL)
    }

    static func loadCompletedSteps() -> [String: Date] {
        migratedValue(from: completedStepsURL, legacyKey: completedStepsKey) ?? [:]
    }

    static func saveCompletedSteps(_ completedSteps: [String: Date]) {
        write(completedSteps, to: completedStepsURL)
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
        if let storedValue: Value = read(from: fileURL) { return storedValue }
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

    private static func write<Value: Encodable>(_ storedValue: Value, to fileURL: URL) {
        do {
            try FileManager.default.createDirectory(at: storageDirectoryURL, withIntermediateDirectories: true)
            try JSONEncoder().encode(storedValue).write(to: fileURL, options: .atomic)
        } catch {
            logger.error("تعذر حفظ التخزين المحلي: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func dateKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = PlannerCalendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func wisdom(for date: Date) -> (text: String, source: String) {
        let hour = Int(date.timeIntervalSince1970 / 3_600)
        return wisdoms[abs(hour) % wisdoms.count]
    }
}
