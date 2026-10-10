#if DEBUG
import AppKit
import SwiftUI
import PulseCore

/// Real root and native grip, with fictional offline plans and disposable defaults.
/// Run: FFF --main-window-demo --popover-resize-selftest --export-render-base64
@MainActor
enum PopoverResizeSelfTest {
    private static var failures: [String] = []

    static func run() -> Bool {
        failures = []
        checkSizing()
        checkPersistence()
        let appState = AppState()
        seedPlans(appState)
        let baseline = appState.watchlist.syncSnapshot()
        for scheme in [ColorScheme.light, .dark] {
            checkNativeRoot(appState, scheme: scheme)
        }
        expect(appState.watchlist.syncSnapshot() == baseline, "resizing must not change any holdings, plans or accounts")
        for failure in failures { print("PULSE_POPOVER_RESIZE_SELFTEST failure: \(failure)") }
        print("PULSE_POPOVER_RESIZE_SELFTEST \(failures.isEmpty ? "passed" : "failed")")
        return failures.isEmpty
    }

    private static func checkSizing() {
        func resolve(_ preferred: CGFloat?, _ automatic: CGFloat = 478, _ minimum: CGFloat = 300, _ maximum: CGFloat = 900) -> CGFloat {
            PopoverPanelSizing.resolveHeight(preferred: preferred, automatic: automatic, minimum: minimum, maximum: maximum)
        }
        expect(resolve(nil) == 478, "missing preference keeps automatic height")
        expect(resolve(700) == 700, "manual height may exceed the old 600pt ceiling")
        expect(resolve(100) == 300, "scrolling panel respects minimum height")
        expect(resolve(1_500, 478, 300, 720) == 720, "screen space caps manual height")
        expect(resolve(700, 478, 400, 250) == 250, "small screen wins over page minimum")
        expect(resolve(.nan) == 478 && resolve(.infinity) == 478 && resolve(-50) == 478,
               "invalid preferred height falls back to automatic sizing")
        let invalidAuto = resolve(nil, .nan)
        expect(invalidAuto.isFinite && invalidAuto >= 300 && invalidAuto <= 900,
               "invalid automatic height cannot produce an invalid frame")
    }

    private static func checkPersistence() {
        let suite = "app.pulse.mac.popover-resize-selftest.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            expect(false, "disposable settings suite must open"); return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        expect(settings.menuBarPanelHeight == nil, "fresh settings have no manual override")
        settings.redUp = false
        settings.setMenuBarPanelHeight(710)
        let restored = AppSettings(defaults: defaults)
        expect(restored.menuBarPanelHeight == 710 && !restored.redUp,
               "height survives a settings reload without losing other settings")
        restored.setMenuBarPanelHeight(nil)
        expect(AppSettings(defaults: defaults).menuBarPanelHeight == nil, "reset removes persistent override")
        // A pre-feature snapshot is still readable, and does not gain an override.
        if let data = defaults.data(forKey: "pulse.settings.v1"),
           var payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            payload.removeValue(forKey: "menuBarPanelHeight")
            if let legacy = try? JSONSerialization.data(withJSONObject: payload) {
                defaults.set(legacy, forKey: "pulse.settings.v1")
                let reloaded = AppSettings(defaults: defaults)
                expect(reloaded.menuBarPanelHeight == nil && !reloaded.redUp, "legacy settings preserve automatic sizing")
            }
            payload["menuBarPanelHeight"] = -40
            if let invalid = try? JSONSerialization.data(withJSONObject: payload) {
                defaults.set(invalid, forKey: "pulse.settings.v1")
                let reloaded = AppSettings(defaults: defaults)
                expect(reloaded.menuBarPanelHeight == nil && !reloaded.redUp, "invalid stored height is discarded, not other settings")
            }
        } else { expect(false, "settings snapshot must be persisted") }
    }

    private static func seedPlans(_ state: AppState) {
        let store = state.watchlist
        for item in store.allItems {
            for plan in item.plans { store.deleteTradePlan(plan.id, for: item.symbol) }
        }
        let symbol = SymbolID(market: .us, code: "RESIZEQA")
        store.add(SymbolInfo(symbol: symbol, name: "虚构高度调整验证", type: .equity))
        for index in 0..<10 {
            expect(store.setTradePlan(TradePlan(kind: index % 3 == 0 ? .sell : .buy,
                price: 100 + Double(index) * 5, quantity: 100), for: symbol), "fictional plan must save")
        }
        state.market.apply(quotes: [Quote(symbol: symbol, price: 105, previousClose: 100, timestamp: .now)])
    }

    private static func checkNativeRoot(_ state: AppState, scheme: ColorScheme) {
        state.settings.setMenuBarPanelHeight(nil)
        let suffix = scheme == .dark ? "dark" : "light"
        let (window, hosting) = makeRoot(state, scheme: scheme, host: .menuBar, height: 478)
        defer { window.orderOut(nil) }
        settle(hosting)
        guard let grip = descendant(PopoverResizeGripView.self, in: hosting) else {
            expect(false, "real menu-bar root must contain a native resize grip"); return
        }
        // NSView.hitTest takes its superview's coordinates. The hosting view
        // and the panel frame have different flippedness even at the same origin.
        let hitPoint = grip.convert(NSPoint(x: grip.bounds.midX, y: grip.bounds.midY), to: hosting.superview)
        let hit = hosting.hitTest(hitPoint)
        expect(hit === grip, "visible footer is the actual mouse hit target (\(String(describing: hit)))")
        let originalHeight = window.contentLayoutRect.height
        let originalWidth = window.frame.width
        let originalTop = window.frame.maxY
        capture(hosting, name: "popover-plans-before-\(suffix).png")
        let start = pointerPosition(grip)
        let upperLimit = PopoverPanelSizing.maximumHeight(for: window)
        let target = min(originalHeight + 180, upperLimit)
        send(grip, type: .leftMouseDown, point: start)
        send(grip, type: .leftMouseDragged, point: NSPoint(x: start.x, y: start.y - 90))
        settle(hosting)
        send(grip, type: .leftMouseDragged, point: NSPoint(x: start.x, y: start.y - 180))
        settle(hosting)
        expect(abs(window.contentLayoutRect.height - target) < 2,
               "drag follows absolute screen delta, without compounding movement")
        expect(abs(window.frame.width - originalWidth) < 1 && abs(window.frame.maxY - originalTop) < 1,
               "vertical drag preserves width and top anchor")
        expect(state.settings.menuBarPanelHeight == nil, "drag does not persist on every mouse event")
        send(grip, type: .leftMouseUp, point: NSPoint(x: start.x, y: start.y - 180))
        settle(hosting)
        expect(abs((state.settings.menuBarPanelHeight ?? 0) - target) < 2, "mouse-up commits the selected height")
        capture(hosting, name: "popover-plans-taller-\(suffix).png")
        print("POPOVER_NATIVE_HEIGHTS \(suffix) before=\(originalHeight) after=\(window.contentLayoutRect.height) topDelta=\(window.frame.maxY - originalTop)")

        // A fresh root uses the same stored preference. The test host applies the
        // root's fitting size just as MenuBarExtra's content-size host does.
        let (reopened, reopenedHost) = makeRoot(state, scheme: scheme, host: .menuBar, height: target)
        settle(reopenedHost)
        expect(abs(reopenedHost.fittingSize.height - target) < 2, "reopened root retains the selected height")
        reopened.orderOut(nil)

        let shortStart = pointerPosition(grip)
        send(grip, type: .leftMouseDown, point: shortStart)
        let shortEnd = NSPoint(x: shortStart.x, y: shortStart.y + 10_000)
        send(grip, type: .leftMouseDragged, point: shortEnd)
        send(grip, type: .leftMouseUp, point: shortEnd)
        settle(hosting)
        expect(abs(window.contentLayoutRect.height - min(300, upperLimit)) < 2,
               "upward drag stops at the safe minimum")
        expect(window.contentLayoutRect.height > PopoverPanelSizing.gripHeight,
               "grip remains reachable at minimum height")
        capture(hosting, name: "popover-plans-shorter-\(suffix).png")
        // A second drag has a fresh origin, and must not retain the first delta.
        let nextStart = pointerPosition(grip)
        send(grip, type: .leftMouseDown, point: nextStart)
        let nextEnd = NSPoint(x: nextStart.x, y: nextStart.y - 70)
        send(grip, type: .leftMouseDragged, point: nextEnd)
        send(grip, type: .leftMouseUp, point: nextEnd)
        settle(hosting)
        expect(abs(window.contentLayoutRect.height - min(370, upperLimit)) < 2,
               "subsequent drag starts from current height")
        let accessibleBefore = state.settings.menuBarPanelHeight ?? 0
        expect(grip.accessibilityPerformIncrement(), "grip supports accessibility height adjustment")
        settle(hosting)
        expect((state.settings.menuBarPanelHeight ?? 0) > accessibleBefore,
               "accessibility adjustment persists a height change")
        send(grip, type: .leftMouseDown, point: pointerPosition(grip), clicks: 2)
        settle(hosting)
        expect(state.settings.menuBarPanelHeight == nil, "double-click restores automatic mode")
        expect(abs(window.contentLayoutRect.height - originalHeight) < 2, "reset restores automatic native height")
        capture(hosting, name: "popover-plans-reset-\(suffix).png")
        state.settings.setMenuBarPanelHeight(20_000)
        settle(hosting)
        expect(window.contentLayoutRect.height <= upperLimit + 2 && state.settings.menuBarPanelHeight == 20_000,
               "screen clamping fits the real window without overwriting the preference")
        send(grip, type: .leftMouseDown, point: pointerPosition(grip), clicks: 2)
        settle(hosting)

        // The preference does not change the floating pinned window's layout.
        state.settings.setMenuBarPanelHeight(710)
        let (pinned, pinnedHost) = makeRoot(state, scheme: scheme, host: .pinnedWindow, height: 520, width: 520)
        settle(pinnedHost)
        expect(descendant(PopoverResizeGripView.self, in: pinnedHost) == nil,
               "pinned window does not acquire the menu-bar grip")
        expect(abs(pinnedHost.fittingSize.height - 520) < 2 && state.settings.menuBarPanelHeight == 710,
               "pinned route size and menu preference stay independent")
        pinned.orderOut(nil)
        state.settings.setMenuBarPanelHeight(nil)
    }

    private static func makeRoot(_ state: AppState, scheme: ColorScheme, host: PulseHost, height: CGFloat,
                                 width: CGFloat = 340) -> (NSPanel, NSHostingView<AnyView>) {
        let root = AnyView(PopoverRootView(initialRoute: .planList)
            .environment(state).environment(\.pulseHost, host).environment(\.colorScheme, scheme)
            .background(Color(nsColor: .windowBackgroundColor)))
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.autoresizingMask = [.width, .height]
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        hosting.appearance = window.appearance
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        return (window, hosting)
    }

    private static func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = descendant(type, in: child) { return match }
        }
        return nil
    }

    private static func pointerPosition(_ view: NSView) -> NSPoint {
        let local = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        return view.window?.convertPoint(toScreen: view.convert(local, to: nil)) ?? .zero
    }

    private static func send(_ view: PopoverResizeGripView, type: NSEvent.EventType, point: NSPoint, clicks: Int = 1) {
        guard let window = view.window,
              let event = NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1) else {
            expect(false, "native drag event must be constructed"); return
        }
        // Route through the real window's hit testing and drag recipient,
        // rather than bypassing AppKit by calling the view's handlers directly.
        window.sendEvent(event)
    }

    private static func settle(_ view: NSView) {
        for _ in 0..<8 {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    private static func capture(_ view: NSView, name: String) {
        do {
            let directory = URL(fileURLWithPath: "build/artifacts/popover-resize", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                expect(false, "native render bitmap must allocate"); return
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                expect(false, "native render must encode"); return
            }
            try data.write(to: directory.appendingPathComponent(name))
            if CommandLine.arguments.contains("--export-render-base64") {
                print("PULSE_RENDER_BASE64 \(name) \(data.base64EncodedString())")
            }
        } catch { expect(false, "native render failed: \(error)") }
    }

    private static func expect(_ value: Bool, _ message: String) {
        if !value { failures.append(message) }
    }
}
#endif
