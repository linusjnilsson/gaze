import AppKit
import ApplicationServices

/// Watches clicks and typing system-wide, reporting where the user was presumably looking.
///
/// Only positions and timestamps are used: which key was pressed is never read.
@MainActor
final class InteractionMonitor {
    /// Global screen coordinates and the event's uptime timestamp.
    var onClick: ((CGPoint, TimeInterval) -> Void)?
    var onType: ((CGPoint, TimeInterval) -> Void)?

    private var monitors: [Any] = []
    private var lastKeyPress: TimeInterval = 0

    /// Global key events (other apps) need Accessibility access; clicks don't.
    static var hasAccessibilityAccess: Bool { AXIsProcessTrusted() }

    static func requestAccessibilityAccess() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func start() {
        stop()
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        let keys: NSEvent.EventTypeMask = [.keyDown]

        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mouse, handler: { event in
            MainActor.assumeIsolated { self.handleClick(event) }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mouse, handler: { event in
            MainActor.assumeIsolated { self.handleClick(event) }
            return event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: keys, handler: { event in
            MainActor.assumeIsolated { self.handleKey(event) }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: keys, handler: { event in
            MainActor.assumeIsolated { self.handleKey(event) }
            return event
        }) { monitors.append(monitor) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func handleClick(_ event: NSEvent) {
        onClick?(NSEvent.mouseLocation, event.timestamp)
    }

    private func handleKey(_ event: NSEvent) {
        let previous = lastKeyPress
        lastKeyPress = event.timestamp
        // People look at the text cursor when they start typing; mid-burst their eyes are often
        // on the keyboard or already reading ahead. So only the first key after a pause counts.
        guard event.timestamp - previous >= 1.0,
              !event.modifierFlags.contains(.command),
              let caret = Self.caretRect()
        else { return }
        onType?(CGPoint(x: caret.midX, y: caret.midY), event.timestamp)
    }

    /// The focused text cursor's frame in global AppKit coordinates, if the focused app exposes it.
    static func caretRect() -> CGRect? {
        let system = AXUIElementCreateSystemWide()
        // Don't stall the main thread on an unresponsive app.
        AXUIElementSetMessagingTimeout(system, 0.1)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = focused as! AXUIElement

        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let range
        else { return nil }

        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID()
        else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect),
              rect.height > 0, rect.height < 200, rect.width < 2000
        else { return nil }

        // Accessibility uses a top-left origin on the primary display; AppKit uses bottom-left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
