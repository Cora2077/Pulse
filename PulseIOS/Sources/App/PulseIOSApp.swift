import SwiftUI

@main
struct PulseIOSApp: App {
    @State private var state = IPhoneAppState()
    private var acceptanceLargeDark: Bool {
        state.isDemo && CommandLine.arguments.contains("--acceptance-large-dark")
    }
    var body: some Scene {
        WindowGroup {
            WorkbenchRootView()
                .environment(state)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
                .tint(.blue)
                .preferredColorScheme(acceptanceLargeDark ? .dark : nil)
                .transformEnvironment(\.dynamicTypeSize) { if acceptanceLargeDark { $0 = .accessibility1 } }
        }
    }
}
