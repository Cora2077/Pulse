import AppKit
import SwiftUI

/// Spatially limits chart shortcuts to the chart area and leaves native text
/// editing shortcuts alone when an editor or field editor owns the keyboard.
struct MainChartKeyboardMonitor: NSViewRepresentable {
    var isEnabled: Bool
    var allowsChartFocus: Bool
    var onEscape: () -> Bool
    var onDelete: () -> Bool
    var onUndo: () -> Bool
    var onRedo: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        context.coordinator.view = view
        context.coordinator.update(
            isEnabled: isEnabled,
            allowsChartFocus: allowsChartFocus,
            onEscape: onEscape,
            onDelete: onDelete,
            onUndo: onUndo,
            onRedo: onRedo
        )
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.update(
            isEnabled: isEnabled,
            allowsChartFocus: allowsChartFocus,
            onEscape: onEscape,
            onDelete: onDelete,
            onUndo: onUndo,
            onRedo: onRedo
        )
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class MonitorView: NSView {
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
    }

    @MainActor
    final class Coordinator {
        weak var view: MonitorView?
        private var monitors: [Any] = []
        private var isEnabled = false
        private var allowsChartFocus = false
        private var onEscape: () -> Bool = { false }
        private var onDelete: () -> Bool = { false }
        private var onUndo: () -> Bool = { false }
        private var onRedo: () -> Bool = { false }

        func update(
            isEnabled: Bool,
            allowsChartFocus: Bool,
            onEscape: @escaping () -> Bool,
            onDelete: @escaping () -> Bool,
            onUndo: @escaping () -> Bool,
            onRedo: @escaping () -> Bool
        ) {
            self.isEnabled = isEnabled
            self.allowsChartFocus = allowsChartFocus
            self.onEscape = onEscape
            self.onDelete = onDelete
            self.onUndo = onUndo
            self.onRedo = onRedo
            guard monitors.isEmpty else { return }
            let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
            let mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.handleMouseDown(event) ?? event
            }
            if let keyMonitor { monitors.append(keyMonitor) }
            if let mouseMonitor { monitors.append(mouseMonitor) }
        }

        func removeMonitor() {
            for monitor in monitors { NSEvent.removeMonitor(monitor) }
            monitors.removeAll()
        }

        private func handleMouseDown(_ event: NSEvent) -> NSEvent? {
            guard isEnabled,
                  allowsChartFocus,
                  let view,
                  let window = view.window,
                  window.isKeyWindow,
                  event.window === window else { return event }

            let windowRect = view.convert(view.bounds, to: nil)
            let screenRect = window.convertToScreen(windowRect)
            let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
            guard screenRect.contains(screenPoint) else { return event }
            _ = window.makeFirstResponder(view)
            return event
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard isEnabled,
                  let view,
                  let window = view.window,
                  window.isKeyWindow,
                  event.window === window else { return event }

            let chartHasFocus = window.firstResponder === view
            if isEditingText(in: window), !chartHasFocus { return event }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let commandOnly = modifiers.contains(.command) && !modifiers.contains(.option) && !modifiers.contains(.control)
            if event.keyCode == 53 {
                return onEscape() ? nil : event
            }
            guard chartHasFocus || isMouseOverChart(view, window: window) else { return event }
            if !modifiers.contains(.command), event.keyCode == 51 || event.keyCode == 117 {
                return onDelete() ? nil : event
            }
            guard commandOnly, event.charactersIgnoringModifiers?.lowercased() == "z" else { return event }
            if modifiers.contains(.shift) {
                return onRedo() ? nil : event
            }
            return onUndo() ? nil : event
        }

        private func isMouseOverChart(_ view: NSView, window: NSWindow) -> Bool {
            let windowRect = view.convert(view.bounds, to: nil)
            let screenRect = window.convertToScreen(windowRect)
            return screenRect.contains(NSEvent.mouseLocation)
        }

        private func isEditingText(in window: NSWindow) -> Bool {
            guard let responder = window.firstResponder else { return false }
            if responder is NSTextView || responder is NSTextField || responder is NSSearchField { return true }
            return false
        }
    }
}
