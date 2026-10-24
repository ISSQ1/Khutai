import Foundation

/// نتيجة الجدولة لمهمة رئيسية واحدة. هي اقتراح يُعرض فقط، ولا تغيّر
/// بيانات المهمة ولا تضع أيامًا لخطواتها.
struct TaskScheduleInfo: Equatable {
    let taskID: UUID
    /// اليوم المقترح لبدء العمل (yyyy-MM-dd)، أو nil إن لم تكفِ المعلومات للاقتراح.
    let startDateKey: String?
    /// الجهد المتبقي المقدّر بالدقائق، إن أمكن تقديره من التفاصيل أو الخطوات.
    let remainingMinutes: Int?
    /// ما يمكن توفيره من دقائق قبل الموعد النهائي.
    let availableMinutes: Int?
    /// الدقائق المقترحة للعمل على المهمة اليوم.
    let todayMinutes: Int
    /// الوقت المتاح قبل الموعد لا يكفي، أو الموعد فات.
    let isAtRisk: Bool
    let isOverdue: Bool
}

struct SchedulerInput {
    var tasks: [PlannerTask]
    /// دقائق المواعيد المسجّلة في كل يوم (yyyy-MM-dd).
    var busyMinutesByDay: [String: Int]
    var workCapacity: Int
    var personalCapacity: Int
    var today: Date
}

/// جدولة محلية ثابتة النتائج: تُحسب في كل مرة من البيانات نفسها،
/// فلا تنقل شيئًا من مكانه دون علم المستخدمة.
enum TaskScheduler {
    static func plan(_ input: SchedulerInput) -> [UUID: TaskScheduleInfo] {
        let calendar = PlannerCalendar.current
        let todayStart = calendar.startOfDay(for: input.today)
        let todayKey = PlannerStorage.dateKey(for: todayStart)
        let dayBudget = max(0, input.workCapacity) + max(0, input.personalCapacity)

        var allocated: [String: [TaskCategory: Int]] = [:]
        var result: [UUID: TaskScheduleInfo] = [:]

        // الأقرب موعدًا أولًا، ثم الأعلى أولوية، ثم الأقدم إنشاءً.
        let pending = input.tasks.filter { !$0.isDone }.sorted { lhs, rhs in
            let left = calendar.startOfDay(for: lhs.deadline)
            let right = calendar.startOfDay(for: rhs.deadline)
            if left != right { return left < right }
            if lhs.priority.rank != rhs.priority.rank { return lhs.priority.rank > rhs.priority.rank }
            return (lhs.createdAt ?? .distantPast) < (rhs.createdAt ?? .distantPast)
        }

        // الخطوات التي حددت المستخدمة أيامها تُحجز في أيامها أولًا ولا يُعاد توزيعها.
        for task in pending {
            for step in task.subtasks where !step.isDone {
                guard let key = step.scheduledDate, key >= todayKey,
                      let minutes = step.estimatedMinutes, minutes > 0 else { continue }
                allocated[key, default: [:]][task.category, default: 0] += minutes
            }
        }

        for task in pending {
            let deadlineDay = calendar.startOfDay(for: task.deadline)
            let isOverdue = deadlineDay < todayStart
            let earliest = earliestStartDay(for: task, todayStart: todayStart)

            guard let remaining = remainingEffort(of: task, todayKey: todayKey), remaining > 0 else {
                // لا يوجد تقدير للجهد: نقترح يوم البدء فقط إن طُلب توزيع أو يوم بدء.
                var startKey: String?
                // الخطوات المحجوزة بأيام حددتها المستخدمة: أقربها هو يوم البدء.
                let bookedDays = task.subtasks
                    .filter { !$0.isDone }
                    .compactMap(\.scheduledDate)
                    .filter { $0 >= todayKey }
                let deadlineKey = PlannerStorage.dateKey(for: deadlineDay)
                let hasBookingAfterDeadline = bookedDays.contains { $0 > deadlineKey }
                if isOverdue {
                    startKey = todayKey
                } else if let firstBooked = bookedDays.min() {
                    startKey = firstBooked
                } else if let spread = task.planning?.spreadOverDays, spread > 0,
                          let start = calendar.date(byAdding: .day, value: -(spread - 1), to: deadlineDay) {
                    startKey = PlannerStorage.dateKey(for: max(start, earliest))
                } else if task.planning?.earliestStart != nil {
                    startKey = PlannerStorage.dateKey(for: earliest)
                }
                result[task.id] = TaskScheduleInfo(
                    taskID: task.id,
                    startDateKey: startKey,
                    remainingMinutes: nil,
                    availableMinutes: nil,
                    todayMinutes: 0,
                    isAtRisk: isOverdue || hasBookingAfterDeadline,
                    isOverdue: isOverdue
                )
                continue
            }

            // نوزّع الجهد رجوعًا من قبل الموعد النهائي بهامش بحسب الأولوية
            // حتى أول يوم متاح، ولا نلجأ لأيام الهامش ويوم التسليم إلا إن لم يكفِ ما قبلها.
            var lastDay = isOverdue ? todayStart : deadlineDay
            if !isOverdue {
                // هامش قبل الموعد: يومان للعالية، يوم للمتوسطة، ولا هامش للمنخفضة.
                let bufferDays = task.priority == .high ? 2 : (task.priority == .normal ? 1 : 0)
                for _ in 0..<bufferDays {
                    guard lastDay > earliest,
                          let previous = calendar.date(byAdding: .day, value: -1, to: lastDay) else { break }
                    lastDay = previous
                }
            }
            var candidateDays: [Date] = []
            var day = lastDay
            while day >= earliest, candidateDays.count < 730 {
                candidateDays.append(day)
                guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
                day = previous
            }
            var fallbackDay = calendar.date(byAdding: .day, value: 1, to: lastDay)
            while let current = fallbackDay, current <= deadlineDay, !isOverdue {
                candidateDays.append(current)
                fallbackDay = calendar.date(byAdding: .day, value: 1, to: current)
            }

            let minSession = max(0, task.planning?.minSessionMinutes ?? 0)
            let spread = max(1, task.planning?.spreadOverDays ?? 1)
            let perDayLimit = max(Int((Double(remaining) / Double(spread)).rounded(.up)), minSession)
            let capacity = task.category == .work ? input.workCapacity : input.personalCapacity

            var left = remaining
            var usedDays: [String: Int] = [:]
            for candidate in candidateDays where left > 0 {
                let key = PlannerStorage.dateKey(for: candidate)
                let busy = input.busyMinutesByDay[key] ?? 0
                let categoryUsed = allocated[key]?[task.category] ?? 0
                let totalUsed = allocated[key]?.values.reduce(0, +) ?? 0
                let free = max(0, min(capacity - categoryUsed, dayBudget - busy - totalUsed))
                var amount = min(free, left, perDayLimit)
                if amount < min(minSession, left) { amount = 0 } // لا يتسع اليوم لجلسة كاملة
                if amount > 0 {
                    usedDays[key] = amount
                    left -= amount
                    allocated[key, default: [:]][task.category, default: 0] += amount
                }
            }

            let isAtRisk = left > 0 || isOverdue
            let startKey = left > 0
                ? PlannerStorage.dateKey(for: earliest)
                : (usedDays.keys.min() ?? PlannerStorage.dateKey(for: earliest))
            result[task.id] = TaskScheduleInfo(
                taskID: task.id,
                startDateKey: startKey,
                remainingMinutes: remaining,
                availableMinutes: remaining - left,
                todayMinutes: usedDays[todayKey] ?? 0,
                isAtRisk: isAtRisk,
                isOverdue: isOverdue
            )
        }
        return result
    }

    /// الجهد المتبقي الذي يحتاج توزيعًا: من الجهد المطلوب في التفاصيل (بنسبة الخطوات
    /// المتبقية)، أو من مدد الخطوات غير المنجزة، بعد طرح الخطوات المحجوزة في أيامها.
    static func remainingEffort(of task: PlannerTask, todayKey: String) -> Int? {
        let total = task.subtasks.count
        let undone = task.subtasks.filter { !$0.isDone }
        let isBooked: (PlannerSubtask) -> Bool = { ($0.scheduledDate ?? "") >= todayKey }
        let bookedMinutes = undone.filter(isBooked).compactMap(\.estimatedMinutes).reduce(0, +)
        if let effort = task.planning?.effortMinutes, effort > 0 {
            let share = total > 0
                ? Int((Double(effort) * Double(undone.count) / Double(total)).rounded(.up))
                : effort
            return max(0, share - bookedMinutes)
        }
        let estimates = undone.filter { !isBooked($0) }.compactMap(\.estimatedMinutes)
        return estimates.isEmpty ? nil : estimates.reduce(0, +)
    }

    private static func earliestStartDay(for task: PlannerTask, todayStart: Date) -> Date {
        guard let key = task.planning?.earliestStart,
              let date = PlannerStorage.date(fromKey: key) else { return todayStart }
        return max(todayStart, PlannerCalendar.current.startOfDay(for: date))
    }
}
