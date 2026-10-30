import AppKit
import Foundation
import UserNotifications

/// إشعار مجهّز للجدولة (قيم بسيطة).
struct PlannedNotification {
    let id: String
    let title: String
    let body: String
    let fireDate: Date
    let isMorningSummary: Bool
}

/// الإشعارات المحلية: ملخص الصباح، المواعيد، بدء المهام، والمواعيد النهائية.
@MainActor
final class NotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()
    nonisolated static let morningCategory = "KHUTAI_MORNING"

    /// يصبح true عند الضغط على إشعار ملخص الصباح، فتفتح مراجعة الصباح.
    @Published var isMorningCheckInRequested = false
    @Published private(set) var isAuthorized = false
    /// معرّفات ما جدولناه آخر مرة، فنستبدلها وحدها (ولا نمس إشعار التجربة).
    private var scheduledIDs: Set<String> = []
    private var hasClearedOldRequests = false

    private override init() {
        super.init()
    }

    /// يُستدعى مرة عند تشغيل التطبيق.
    func activate() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { @Sendable (granted, _) in
            Task { @MainActor in
                NotificationService.shared.isAuthorized = granted
            }
        }
    }

    /// يستبدل كل الإشعارات المجدولة بالقائمة الجديدة (بحد أقصى ٦٠ إشعارًا، الأقرب أولًا).
    func replaceAll(with notifications: [PlannedNotification], playsSound: Bool) {
        let center = UNUserNotificationCenter.current()
        if hasClearedOldRequests {
            center.removePendingNotificationRequests(withIdentifiers: Array(scheduledIDs))
        } else {
            // أول جدولة بعد التشغيل: نزيل ما بقي من تشغيل سابق.
            center.removeAllPendingNotificationRequests()
            hasClearedOldRequests = true
        }
        scheduledIDs = []
        let now = Date()
        let upcoming = notifications
            .filter { $0.fireDate > now.addingTimeInterval(5) }
            .sorted { $0.fireDate < $1.fireDate }
            .prefix(60)
        let calendar = Calendar.current
        for item in upcoming {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.body
            content.sound = playsSound ? .default : nil
            if item.isMorningSummary {
                content.categoryIdentifier = Self.morningCategory
            }
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: item.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: item.id, content: content, trigger: trigger)
            center.add(request, withCompletionHandler: nil)
            scheduledIDs.insert(item.id)
        }
    }

    /// إشعار تجريبي بعد خمس ثوانٍ (يمكن إغلاق النافذة لرؤيته كما سيظهر فعلًا).
    func sendTest(playsSound: Bool, symbol: String) {
        let content = UNMutableNotificationContent()
        content.title = "\(symbol) تجربة تنبيه خُطاي"
        content.body = playsSound ? "هكذا ستصلك التنبيهات، مع الصوت." : "هكذا ستصلك التنبيهات (الصوت مطفأ من الإعدادات)."
        content.sound = playsSound ? .default : nil
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        let request = UNNotificationRequest(identifier: "khutai-test-\(UUID().uuidString)", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    func removeAll() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        scheduledIDs = []
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let isMorning = response.notification.request.content.categoryIdentifier == NotificationService.morningCategory
        Task { @MainActor in
            NSApp.activate()
            if isMorning {
                NotificationService.shared.isMorningCheckInRequested = true
            }
        }
        completionHandler()
    }
}
