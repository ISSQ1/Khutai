import AppKit
import SwiftUI

@main
struct LotusPlannerApp: App {
    @StateObject private var calendarService: CalendarService
    @StateObject private var store: PlannerStore

    init() {
        // إن أغلقت أداة المساعد اتصالها مبكرًا لا ينهار التطبيق عند الكتابة إليها.
        signal(SIGPIPE, SIG_IGN)
        let calendarService = CalendarService()
        _calendarService = StateObject(wrappedValue: calendarService)
        _store = StateObject(wrappedValue: PlannerStore(calendarService: calendarService))
        NotificationService.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(calendarService)
                .environmentObject(NotificationService.shared)
                .environment(\.layoutDirection, .rightToLeft)
                // الوضع الفاتح دائمًا، مهما كان مظهر النظام.
                .preferredColorScheme(.light)
                .frame(minWidth: 520, minHeight: 620)
                .onAppear {
                    NSApp.appearance = NSAppearance(named: .aqua)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 620, height: 760)
    }
}
