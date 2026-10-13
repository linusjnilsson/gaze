import AppKit
import ApplicationServices
import Carbon
import GazeKit

/// A pane inside a window: a terminal split, an editor, a list, a web page. Found through
/// Accessibility as the window's scrollable areas.
struct Pane: @unchecked Sendable {
    /// Global AppKit coordinates, clipped to the window.
    var frame: CGRect
    /// The scroll area or web area.
    var element: AXUIElement
    /// Position among the window's panes in Accessibility order, which for iTerm is also the
    /// order of the tab's sessions.
    var index: Int
}

/// A window's panes, and which of them has keyboard focus.
struct WindowPanes: @unchecked Sendable {
    var panes: [Pane]
    var focused: Int?
}

/// Reads windows' panes off the main thread (Accessibility calls into other apps can be slow),
/// and remembers them for a moment: a hold reads each window once.
@MainActor
final class PaneCache {
    private var entries: [UInt32: (time: TimeInterval, panes: WindowPanes?)] = [:]
    private var waiting: [UInt32: [CheckedContinuation<WindowPanes?, Never>]] = [:]
    private static let queue = DispatchQueue(label: "gaze.panes")
    private static let lifetime: TimeInterval = 1.5

    /// The panes if read recently; otherwise starts reading them and returns `nil`.
    func cached(_ window: ScreenWindow) -> WindowPanes? {
        if let entry = entries[window.id], ProcessInfo.processInfo.systemUptime - entry.time < Self.lifetime {
            return entry.panes
        }
        read(window)
        return nil
    }

    /// The panes, read now if needed.
    func panes(of window: ScreenWindow) async -> WindowPanes? {
        if let entry = entries[window.id], ProcessInfo.processInfo.systemUptime - entry.time < Self.lifetime {
            return entry.panes
        }
        return await withCheckedContinuation { continuation in
            waiting[window.id, default: []].append(continuation)
            read(window)
        }
    }

    /// Forgets a window's panes, after its focus changed.
    func invalidate(_ id: UInt32) {
        entries[id] = nil
    }

    private var reading: Set<UInt32> = []

    private func read(_ window: ScreenWindow) {
        guard !reading.contains(window.id) else { return }
        reading.insert(window.id)
        Self.queue.async {
            let panes = PaneFinder.panes(of: window)
            Task { @MainActor in
                self.reading.remove(window.id)
                self.entries[window.id] = (ProcessInfo.processInfo.systemUptime, panes)
                self.waiting.removeValue(forKey: window.id)?.forEach { $0.resume(returning: panes) }
            }
        }
    }
}

enum PaneFinder {
    /// Panes smaller than this are toolbars and fields, not places to work in.
    static let minimumSize = CGSize(width: 120, height: 80)
    /// Enough for a window with many splits, few enough to stay quick in apps with huge trees.
    static let nodeBudget = 800
    /// A slow app gets this long (seconds) before its panes are left out.
    static let timeLimit = 0.3

    /// Content that has no panes inside, and can be enormous (every row, every line).
    private static let leafRoles: Set<String> = [
        kAXTextAreaRole, kAXOutlineRole, kAXTableRole, kAXListRole, kAXBrowserRole, "AXWebArea", kAXStaticTextRole, kAXRowRole,
    ]
    private static let paneRoles: Set<String> = [kAXScrollAreaRole, "AXWebArea"]

    /// The window's panes, or `nil` if there aren't at least two (nothing to choose between).
    static func panes(of window: ScreenWindow) -> WindowPanes? {
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let root = WindowFocuser.axWindow(of: app, matching: WindowList.quartzRect(window.frame)) else { return nil }
        var found: [(element: AXUIElement, frame: CGRect)] = []
        var budget = nodeBudget
        let deadline = ProcessInfo.processInfo.systemUptime + timeLimit
        collect(root, window: window.frame, into: &found, budget: &budget, deadline: deadline)
        guard found.count >= 2 else { return nil }
        let panes = found.enumerated().map { Pane(frame: $0.element.frame, element: $0.element.element, index: $0.offset) }
        return WindowPanes(panes: panes, focused: focusedPane(app: app, panes: panes))
    }

    /// Depth first, so the order follows the window's own layout tree. A pane's inside isn't
    /// searched further: nested scroll areas are parts of one pane.
    private static func collect(_ element: AXUIElement, window: CGRect, into found: inout [(element: AXUIElement, frame: CGRect)], budget: inout Int, deadline: TimeInterval) {
        budget -= 1
        guard budget > 0, ProcessInfo.processInfo.systemUptime < deadline else { return }
        let values = attributes(element, [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute])
        let role = values[0] as? String ?? ""
        if paneRoles.contains(role) {
            if let frame = frame(position: values[1], size: values[2]) {
                let visible = WindowList.appKitRect(frame).intersection(window)
                // Some apps report the same area twice (a web view inside a web view).
                let duplicate = found.contains { abs($0.frame.minX - visible.minX) + abs($0.frame.minY - visible.minY) + abs($0.frame.width - visible.width) + abs($0.frame.height - visible.height) < 8 }
                if !visible.isNull, !duplicate, visible.width >= minimumSize.width, visible.height >= minimumSize.height {
                    found.append((element, visible))
                }
            }
            return
        }
        guard !leafRoles.contains(role) else { return }
        for child in values[3] as? [AXUIElement] ?? [] {
            collect(child, window: window, into: &found, budget: &budget, deadline: deadline)
        }
    }

    /// The pane holding the app's focused element, found by walking up from it.
    private static func focusedPane(app: AXUIElement, panes: [Pane]) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success, let value else { return nil }
        var element = value as! AXUIElement
        for _ in 0..<20 {
            if let pane = panes.first(where: { CFEqual($0.element, element) }) { return pane.index }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success, let parent else { return nil }
            element = parent as! AXUIElement
        }
        return nil
    }

    /// Gives the pane keyboard focus. Most apps take it through Accessibility; iTerm doesn't, so
    /// its session is selected through its scripting interface (the first time, macOS asks
    /// whether Gaze may control iTerm).
    static func focus(_ pane: Pane, of window: ScreenWindow, paneCount: Int) -> Bool {
        if NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier == "com.googlecode.iterm2" {
            return selectITermSession(pane.index + 1, expectedCount: paneCount)
        }
        // The content inside a scroll area usually takes focus, not the scroll area itself.
        let children = attributes(pane.element, [kAXChildrenAttribute])[0] as? [AXUIElement] ?? []
        for element in children + [pane.element] where isFocusSettable(element) {
            if AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
                return true
            }
        }
        return false
    }

    private static func selectITermSession(_ number: Int, expectedCount: Int) -> Bool {
        ITermScript.call("selectsession", [number, expectedCount]) == "ok"
    }

    /// Connects to iTerm ahead of time: the first call takes over 100 ms, later ones a few.
    static func warmUpITerm() {
        _ = ITermScript.call("sessioncount", [])
    }

    private static func isFocusSettable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &settable) == .success && settable.boolValue
    }

    /// Several attributes in one round trip to the app.
    private static func attributes(_ element: AXUIElement, _ names: [String]) -> [Any?] {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values) == .success,
              let array = values as? [Any], array.count == names.count
        else { return names.map { _ in nil } }
        // Missing attributes come back as AXValue errors.
        return array.map { value in
            if CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
            return value
        }
    }

    private static func frame(position: Any?, size: Any?) -> CGRect? {
        guard let position, let size,
              CFGetTypeID(position as CFTypeRef) == AXValueGetTypeID(), CFGetTypeID(size as CFTypeRef) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }
}

/// iTerm's scripting interface, compiled once and run in-process: a call takes a few
/// milliseconds, where launching `osascript` took about 150.
///
/// Only used from the pane focus queue, one call at a time (NSAppleScript isn't thread-safe).
private enum ITermScript {
    /// Sessions are listed in the same order as the panes, as long as both see the same splits.
    private static let source = """
    on selectSession(n, expected)
        tell application id "com.googlecode.iterm2"
            set t to current tab of current window
            if (count of sessions of t) is not expected then return "mismatch"
            select item n of sessions of t
            return "ok"
        end tell
    end selectSession

    on sessionCount()
        tell application id "com.googlecode.iterm2" to return count of sessions of current tab of current window
    end sessionCount
    """

    nonisolated(unsafe) private static var script: NSAppleScript?

    /// Runs a handler (named in lowercase, as AppleScript stores it) with integer arguments.
    static func call(_ handler: String, _ arguments: [Int]) -> String? {
        if script == nil {
            var error: NSDictionary?
            let compiled = NSAppleScript(source: source)
            guard compiled?.compileAndReturnError(&error) == true else { return nil }
            script = compiled
        }
        guard let script else { return nil }
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: handler), forKeyword: AEKeyword(keyASSubroutineName))
        let list = NSAppleEventDescriptor.list()
        for (index, argument) in arguments.enumerated() {
            list.insert(NSAppleEventDescriptor(int32: Int32(argument)), at: index + 1)
        }
        event.setParam(list, forKeyword: keyDirectObject)
        var error: NSDictionary?
        return script.executeAppleEvent(event, error: &error).stringValue
    }
}
