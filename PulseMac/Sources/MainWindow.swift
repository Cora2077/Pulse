import AppKit
import Combine
import SwiftUI
import PulseCore

@MainActor
enum MainWindow {
    static let id = "pulse.main"
    static let visibilityKey = "pulse.mainWindowVisible.v1"
    private static let frameAutosaveName = "PulseMainWindowFrame"

    static var preferenceDefaults: UserDefaults {
        #if DEBUG
        if CommandLine.arguments.contains("--main-window-demo"),
           let defaults = UserDefaults(suiteName: "app.pulse.mac.main-window-demo") {
            return defaults
        }
        #endif
        return .standard
    }

    static func activate() {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(id) == true }?.makeKeyAndOrderFront(nil)
        }
    }

    static func configure(_ window: NSWindow) {
        window.level = .normal
        window.isRestorable = true
        #if DEBUG
        let autosaveName = CommandLine.arguments.contains("--main-window-demo")
            ? "\(frameAutosaveName).demo"
            : frameAutosaveName
        #else
        let autosaveName = frameAutosaveName
        #endif
        window.setFrameAutosaveName(autosaveName)
    }
}

struct MainWindowHost<Content: View>: View {
    @Environment(AppState.self) private var appState
    @ViewBuilder var content: Content
    @AppStorage(MainWindow.visibilityKey) private var isVisible = true
    @State private var window: NSWindow?

    var body: some View {
        hostContent
    }

    private var hostContent: some View {
        content
            .background(windowReader)
            .onAppear(perform: windowDidAppear)
            .onDisappear(perform: windowDidDisappear)
            .onReceive(visibilityEvents, perform: handleVisibilityEvent)
    }

    private var windowReader: some View {
        HostWindowReader { resolved in
            window = resolved
            if let resolved { MainWindow.configure(resolved) }
            updateVisibility()
        }
    }

    private var visibilityEvents: AnyPublisher<Notification, Never> {
        NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification))
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification))
            .eraseToAnyPublisher()
    }

    private func windowDidAppear() {
        isVisible = true
        if let window { MainWindow.configure(window) }
        updateVisibility()
        if appState.onboarding.welcomeSessionActive {
            appState.onboarding.markSeen(.welcomeWindow)
            appState.onboarding.welcomeSessionActive = false
        }
    }

    private func windowDidDisappear() {
        guard !AppDelegate.isTerminating else { return }
        isVisible = false
        appState.setHostVisible(.mainWindow, false)
    }

    private func handleVisibilityEvent(_ note: Notification) {
        guard (note.object as? NSWindow) === window else { return }
        updateVisibility()
    }

    private func updateVisibility() {
        guard let window else { return }
        let visible = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        appState.setHostVisible(.mainWindow, visible)
    }
}
