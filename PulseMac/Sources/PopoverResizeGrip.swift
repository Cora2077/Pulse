import AppKit
import SwiftUI
import PulseCore

/// Heights are total content points, including the always-visible grip strip.
enum PopoverPanelSizing {
    static let gripHeight: CGFloat = 18
    static let minimumHeight: CGFloat = 300
    static let bottomMargin: CGFloat = 12
    static let accessibilityStep: CGFloat = 24

    static func resolveHeight(preferred: CGFloat?, automatic: CGFloat,
                              minimum: CGFloat = minimumHeight, maximum: CGFloat) -> CGFloat {
        let floor = minimum.isFinite && minimum > 0 ? minimum : minimumHeight
        let fallback = automatic.isFinite && automatic > 0 ? automatic : floor
        let ceiling = maximum.isFinite && maximum > 0 ? maximum : fallback
        let candidate = preferred.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? fallback
        return min(max(candidate, min(floor, ceiling)), ceiling)
    }

    static func maximumHeight(for window: NSWindow?) -> CGFloat {
        guard let screen = window?.screen ?? NSScreen.main else { return 900 }
        let visible = screen.visibleFrame
        let overhead = window.map { max(0, $0.frame.height - $0.contentLayoutRect.height) } ?? 0
        let top = min(window?.frame.maxY ?? visible.maxY, visible.maxY)
        // Detached/offscreen QA hosts do not have a usable anchor on this screen.
        let budget = top > visible.minY ? top - visible.minY : visible.height
        return max(1, budget - bottomMargin - overhead)
    }
}

struct PopoverResizeGrip: NSViewRepresentable {
    var currentHeight: () -> CGFloat?
    var minimumHeight: () -> CGFloat
    var maximumHeight: () -> CGFloat
    var onChange: (CGFloat) -> Void
    var onEnd: (CGFloat) -> Void
    var onReset: () -> Void

    func makeNSView(context: Context) -> PopoverResizeGripView {
        let view = PopoverResizeGripView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: PopoverResizeGripView, context: Context) {
        view.currentHeight = currentHeight
        view.minimumHeight = minimumHeight
        view.maximumHeight = maximumHeight
        view.onChange = onChange
        view.onEnd = onEnd
        view.onReset = onReset
        view.toolTip = PulseLocalization.localizedString("popover.resize.help")
        view.reanchorIfDragging()
    }

    static func dismantleNSView(_ view: PopoverResizeGripView, coordinator: ()) {
        view.cancelDrag()
    }
}

/// AppKit retains the mouse-down recipient during a drag, including outside the
/// panel. Ordinary native mouse events need no nested event loop/global monitor.
@MainActor
final class PopoverResizeGripView: NSView {
    var currentHeight: () -> CGFloat? = { nil }
    var minimumHeight: () -> CGFloat = { PopoverPanelSizing.minimumHeight }
    var maximumHeight: () -> CGFloat = { 900 }
    var onChange: (CGFloat) -> Void = { _ in }
    var onEnd: (CGFloat) -> Void = { _ in }
    var onReset: () -> Void = {}

    private var origin: (pointer: NSPoint, topLeft: NSPoint, height: CGFloat)?
    private var lastHeight: CGFloat?
    private var trackingArea: NSTrackingArea?
    private var hovered = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1 / (window?.backingScaleFactor ?? 2)).fill()
        NSColor.secondaryLabelColor.withAlphaComponent(hovered ? 0.7 : 0.45).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 14, y: bounds.midY - 2, width: 28, height: 4),
                     xRadius: 2, yRadius: 2).fill()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown, event.buttonNumber == 0, let window,
              event.window === window, canAdjust else { return }
        window.makeFirstResponder(self)
        if event.clickCount == 2 { cancelDrag(); onReset(); return }
        let height = window.contentLayoutRect.height
        guard height.isFinite, height > 0 else { return }
        origin = (window.convertPoint(toScreen: event.locationInWindow),
                  NSPoint(x: window.frame.minX, y: window.frame.maxY), height)
        lastHeight = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard event.type == .leftMouseDragged, let origin, let window,
              event.window === window, canAdjust else { cancelDrag(); return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let proposed = origin.height + origin.pointer.y - point.y
        guard proposed.isFinite else { cancelDrag(); return }
        // A large upward drag can propose a negative height. It is a gesture,
        // not corrupt stored preferences: clamp it instead of reverting to start.
        let candidate = max(proposed, min(minimumHeight(), maximumHeight()))
        let height = PopoverPanelSizing.resolveHeight(preferred: candidate, automatic: origin.height,
                                                      minimum: minimumHeight(), maximum: maximumHeight())
        lastHeight = height
        onChange(height)
        reanchorIfDragging()
    }

    override func mouseUp(with event: NSEvent) {
        guard event.type == .leftMouseUp, origin != nil else { return }
        guard canAdjust, event.window === window else { cancelDrag(); return }
        let final = lastHeight
        cancelDrag()
        // A single click is not a manual size choice.
        if let final { onEnd(final); notifyAccessibility() }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancelDrag() }
        super.viewWillMove(toWindow: newWindow)
    }

    func cancelDrag() { origin = nil; lastHeight = nil }

    /// SwiftUI's panel host may also resize after a content update. Reapply the
    /// gesture's captured anchor, not the grip's moving local coordinate origin.
    func reanchorIfDragging() {
        guard let origin, let height = lastHeight, let window else { return }
        let overhead = max(0, window.frame.height - window.contentLayoutRect.height)
        var frame = window.frame
        frame.size.height = height + overhead
        frame.origin = NSPoint(x: origin.topLeft.x, y: origin.topLeft.y - frame.height)
        if abs(frame.height - window.frame.height) > 0.5 || abs(frame.maxY - window.frame.maxY) > 0.5 {
            window.setFrame(frame, display: true)
        }
    }

    private var canAdjust: Bool { window?.isVisible == true && window?.attachedSheet == nil && NSApp.modalWindow == nil }

    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityLabel() -> String? { PulseLocalization.localizedString("popover.resize.label") }
    override func accessibilityHelp() -> String? { PulseLocalization.localizedString("popover.resize.help") }
    override func accessibilityValue() -> Any? { currentHeight() ?? 0 }
    override func accessibilityValueDescription() -> String? {
        PulseLocalization.localizedString("popover.resize.value", String(format: "%.0f", Double(currentHeight() ?? 0)))
    }
    override func accessibilityMinValue() -> Any? { minimumHeight() }
    override func accessibilityMaxValue() -> Any? { maximumHeight() }
    override func accessibilityPerformIncrement() -> Bool { nudge(PopoverPanelSizing.accessibilityStep) }
    override func accessibilityPerformDecrement() -> Bool { nudge(-PopoverPanelSizing.accessibilityStep) }
    override func accessibilityPerformPress() -> Bool {
        guard canAdjust else { return false }
        cancelDrag(); onReset(); notifyAccessibility(); return true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: _ = nudge(PopoverPanelSizing.accessibilityStep)
        case 125: _ = nudge(-PopoverPanelSizing.accessibilityStep)
        default: super.keyDown(with: event)
        }
    }

    private func nudge(_ delta: CGFloat) -> Bool {
        guard canAdjust, let current = currentHeight() else { return false }
        let height = PopoverPanelSizing.resolveHeight(preferred: current + delta, automatic: current,
                                                      minimum: minimumHeight(), maximum: maximumHeight())
        onChange(height); onEnd(height); notifyAccessibility()
        return true
    }
    private func notifyAccessibility() { NSAccessibility.post(element: self, notification: .valueChanged) }
}
