import SwiftUI

@main
struct LotusPlannerApp: App {
    @StateObject private var store = PlannerStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environment(\.layoutDirection, .rightToLeft)
                .frame(minWidth: 520, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 620, height: 760)
    }
}
