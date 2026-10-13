import AppKit
import ApplicationServices
import GazeKit
import Observation
import SwiftUI

/// Switches focus to the window the user looks at when they tap the trigger key, optionally to
/// another display just by looking at it, and jumps the pointer to the gaze when they start moving
/// the mouse toward it.
@MainActor
@Observable
final class FocusController {
    var isEnabled = true
    var triggerKey = TriggerKey.rightCommand {
        didSet { if triggerKey != oldValue { configureTrigger() } }
    }
    /// Focuses the pane looked at inside the focused window; `nil` is off. Only modifier keys
    /// other than the window trigger's.
    var paneTrigger: TriggerKey? {
        didSet {
            guard paneTrigger != oldValue else { return }
            paneRecognizer = paneTrigger.map(ModifierTrigger.init)
            paneDisarm()
        }
    }
    var pointerJumpEnabled = true
    /// The advanced settings: thresholds, delays, what the window trigger may do.
    @ObservationIgnored var tuning = FocusTuning()
    /// What the last trigger did, for the controls.
    private(set) var lastResult: String?
    /// Why the selected trigger can't work, if it can't.
    private(set) var triggerProblem: String?

    /// The gaze's typical error in millimeters, for how wide a blur to treat it as.
    @ObservationIgnored var gazeErrorMillimeters: () -> Double = { 25 }
    /// True while focus switching shouldn't act (calibrating, no calibration).
    @ObservationIgnored var isSuspended: () -> Bool = { false }

    @ObservationIgnored private let engine: GazeEngine
    @ObservationIgnored private let highlight = FocusHighlight()
    @ObservationIgnored private let overview = WindowOverviewPanel()
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private let mouseTap = MouseButtonTap()

    // Trigger state.
    @ObservationIgnored private var isArmed = false
    @ObservationIgnored private var armedAt: TimeInterval = 0
    @ObservationIgnored private var previewTimer: Timer?
    @ObservationIgnored private var windowRecognizer = ModifierTrigger(.rightCommand)
    // Pane trigger state.
    @ObservationIgnored private var paneRecognizer: ModifierTrigger?
    @ObservationIgnored private var isPaneArmed = false
    /// The pane the outline shows, so releasing acts on exactly that.
    @ObservationIgnored private var panePicked: PanePick?
    /// When ⇧ joined the held trigger, until the overview of all windows opens.
    @ObservationIgnored private var overviewRequestedAt: TimeInterval?
    /// Where the pointer was when the overview opened. Once it moves away, it picks tiles instead of the gaze.
    @ObservationIgnored private var overviewPointerStart: CGPoint?
    @ObservationIgnored private var pointerPicksTiles = false
    /// How far the pointer must move in the overview to take over from the gaze (points), so a
    /// bump of the mouse doesn't.
    private static let pointerTakeover: CGFloat = 12
    /// Gaze points since the trigger went down, newest last, at most `gazeHistory` of them.
    @ObservationIgnored private var recentGazes: [CGPoint] = []
    /// What the preview outline shows, so releasing acts on exactly that.
    @ObservationIgnored private var previewed: Pick?
    @ObservationIgnored private let paneCache = PaneCache()
    /// The windows buried behind the focused one, found once per hold.
    @ObservationIgnored private var buried: [ScreenWindow]?

    private static let paneQueue = DispatchQueue(label: "gaze.pane-focus")

    /// What the window trigger acts on.
    private struct Pick {
        var target: WindowTarget
        var gaze: CGPoint
        /// The target, if it's hidden behind the focused window (so it can be labeled).
        var hidden: UInt32?
    }

    /// What the pane trigger acts on: a pane of the focused window.
    private struct PanePick {
        var pane: Pane
        var panes: WindowPanes
        var window: ScreenWindow
        var gaze: CGPoint
    }

    // Switching displays by looking.
    @ObservationIgnored private var displayDwell = DisplayDwell(delay: 0.35)
    @ObservationIgnored private var displayMemory = DisplayMemory()
    /// The display holding the focused window, as of the last check (once a second, and after
    /// Gaze moves focus).
    @ObservationIgnored private var focusedDisplayID: UInt32?
    @ObservationIgnored private var displayTimer: Timer?
    @ObservationIgnored private var memoryTimer: Timer?
    @ObservationIgnored private var lastKeyTime: TimeInterval = 0
    @ObservationIgnored private var lastMouseTime: TimeInterval = 0

    // Pointer jump state.
    @ObservationIgnored private var lastMouseMove: TimeInterval = 0
    @ObservationIgnored private var moveStart: (point: CGPoint, time: TimeInterval)?
    @ObservationIgnored private var jumpBlockedUntil: TimeInterval = 0

    /// Ticks of gaze (at 30 a second) a pick is averaged over.
    private var gazeHistory: Int { max(1, Int((tuning.averagingTime * 30).rounded())) }
    /// A pause this long before mouse movement makes it a new movement.
    private static let movementPause = 0.35
    /// A new movement that hasn't covered the decision distance by now is a nudge, not a reach.
    private static let decisionTime = 0.3

    init(engine: GazeEngine) {
        self.engine = engine
        mouseTap.shouldTake = { [weak self] in
            guard let self else { return false }
            return isArmed || canTrigger
        }
        mouseTap.onDown = { [weak self] in
            guard let self, canTrigger else { return }
            arm(at: ProcessInfo.processInfo.systemUptime)
        }
        mouseTap.onUp = { [weak self] in
            guard let self, isArmed else { return }
            commit()
        }
    }

    private var canTrigger: Bool {
        isEnabled && !isSuspended() && engine.model != nil
    }

    /// Sets up the trigger selected at launch, or again once Accessibility access is granted.
    func applyTrigger() {
        configureTrigger()
    }

    /// Sets up what the selected trigger needs beyond the event monitors.
    private func configureTrigger() {
        disarm()
        windowRecognizer = ModifierTrigger(triggerKey)
        triggerProblem = nil
        if case .mouse(let button) = triggerKey.kind {
            mouseTap.start(button: button)
            if mouseTap.button == nil { triggerProblem = "Mouse buttons need Accessibility access." }
        } else {
            mouseTap.stop()
        }
        if triggerKey.kind == .capsLock {
            CapsLockRemap.apply { [weak self] applied in
                guard let self, !applied, triggerKey.kind == .capsLock else { return }
                triggerProblem = "Keys are already remapped by another tool, so Gaze left Caps Lock alone."
            }
        } else {
            CapsLockRemap.remove()
        }
    }

    /// Undoes anything system-wide the trigger changed. Called when Gaze quits.
    func shutdown() {
        mouseTap.stop()
        CapsLockRemap.remove(wait: true)
    }

    /// Installs the event monitors. Key events from other apps need Accessibility access, so this
    /// is called again once it's granted.
    func start() {
        stop()
        let keys: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let moves: NSEvent.EventTypeMask = [.mouseMoved]
        for mask in [keys, mouse, moves] {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
                MainActor.assumeIsolated { self.handle(event) }
            }) { monitors.append(monitor) }
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
                MainActor.assumeIsolated { self.handle(event) }
                return event
            }) { monitors.append(monitor) }
        }
        startDisplayTimers()
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        disarm()
        displayTimer?.invalidate()
        memoryTimer?.invalidate()
        displayTimer = nil
        memoryTimer = nil
    }

    private func handle(_ event: NSEvent) {
        let isCapsLock = triggerKey.kind == .capsLock && event.keyCode == CapsLockRemap.keyCode
        switch event.type {
        case .keyDown, .keyUp: lastKeyTime = event.timestamp
        case .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel: lastMouseTime = event.timestamp
        default: break
        }
        switch event.type {
        case .flagsChanged:
            handleModifiers(event)
        case .mouseMoved:
            handleMouseMove(event)
        case .keyDown where isCapsLock:
            if !event.isARepeat, canTrigger { arm(at: event.timestamp) }
        case .keyUp:
            if isCapsLock, isArmed { commit() }
        case .leftMouseDown where overview.isShown:
            // The overview's overlays take the click, so it never reaches the app below.
            pickOverviewTile(overview.tile(at: NSEvent.mouseLocation))
        default:
            // Any other key or click while a trigger is held makes it a chord: cancel.
            windowRecognizer.otherInput()
            paneRecognizer?.otherInput()
            if isArmed { disarm() }
            if isPaneArmed { paneDisarm() }
        }
    }

    // MARK: Trigger

    private func handleModifiers(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
        if isArmed, let down = overviewShift(event, modifiers: modifiers) {
            if down {
                overviewRequestedAt = overviewRequestedAt ?? event.timestamp
            } else if overviewRequestedAt != nil, !overview.isShown {
                // A tap of ⇧ opens it at once: a ⌘⇧ shortcut's key would have come (and
                // cancelled) before ⇧ went up.
                updateOverview()
            }
            return
        }
        if var pane = paneRecognizer {
            let action = pane.modifiersChanged(event, armed: isPaneArmed)
            paneRecognizer = pane
            switch action {
            case .arm: if canTrigger, !isArmed { paneArm(at: event.timestamp) }
            case .commit: paneCommit()
            case .cancel: paneDisarm()
            case nil: break
            }
        }
        switch windowRecognizer.modifiersChanged(event, armed: isArmed) {
        case .arm: if canTrigger, !isPaneArmed { arm(at: event.timestamp) }
        case .commit: commit()
        case .cancel: disarm()
        case nil: break
        }
    }

    /// Whether this event is ⇧ going down (true) or up (false) next to the held trigger, with no
    /// other modifier: that asks for the overview of all windows. With right ⇧ as the trigger,
    /// it's the left one.
    private func overviewShift(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool? {
        let leftShift: UInt16 = 56, rightShift: UInt16 = 60
        guard event.keyCode == leftShift || event.keyCode == rightShift else { return nil }
        let held: NSEvent.ModifierFlags
        switch triggerKey.kind {
        case let .tap(keyCode, flag, _):
            guard keyCode != event.keyCode else { return nil }
            held = flag
        case .doubleTap(let flag): held = flag
        case .capsLock, .mouse: held = []
        }
        guard modifiers.subtracting(.shift) == held.subtracting(.shift) else { return nil }
        let deviceMask: UInt = event.keyCode == leftShift ? 0x02 : 0x04
        return event.modifierFlags.rawValue & deviceMask != 0
    }

    private func arm(at time: TimeInterval) {
        isArmed = true
        // What's buried behind the focused window, outlined while holding.
        let windows = WindowList.onScreen()
        buried = tuning.revealsHidden && tuning.outlinesBuried
            ? focusedWindow(in: windows).map { WindowTargeting.buried(behind: $0.id, windows: windows) } ?? []
            : []
        armedAt = time
        previewTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePreview() }
        }
        // Also while the run loop tracks events (a menu, a drag), which default-mode timers sit out.
        RunLoop.main.add(timer, forMode: .common)
        previewTimer = timer
    }

    private func disarm() {
        isArmed = false
        buried = nil
        recentGazes = []
        overviewRequestedAt = nil
        overviewPointerStart = nil
        pointerPicksTiles = false
        overview.hide()
        previewed = nil
        previewTimer?.invalidate()
        previewTimer = nil
        titles = [:]
        highlight.hide()
    }

    private func recordGaze() {
        guard engine.latestSample != nil, let gaze = engine.gaze else { return }
        recentGazes.append(gaze)
        if recentGazes.count > gazeHistory { recentGazes.removeFirst(recentGazes.count - gazeHistory) }
    }

    private func updatePreview() {
        let now = ProcessInfo.processInfo.systemUptime
        if isArmed { recordGaze() }
        // Once the overview is up (a ⇧ tap opens it before the delay), the outline stays off.
        if isArmed, let requested = overviewRequestedAt, overview.isShown || now - requested >= tuning.overviewDelay {
            updateOverview()
            return
        }
        guard isArmed, now - armedAt >= tuning.previewDelay else { return }
        guard let current = currentTarget(gazes: currentGazes(), keeping: previewed, buried: buried ?? []) else {
            previewed = nil
            highlight.hide()
            return
        }
        previewed = current
        highlight.show(current.target, hidden: current.hidden, title: title(of:))
        highlight.showBuried(buried ?? [], labeled: tuning.labelsBuried)
    }

    /// The gaze since the trigger went down, the current point included.
    private func currentGazes() -> [CGPoint] {
        guard engine.latestSample != nil, let gaze = engine.gaze else { return [] }
        return recentGazes.last == gaze ? recentGazes : recentGazes + [gaze]
    }

    /// Opens the overview of all windows, or follows the gaze across its tiles.
    private func updateOverview() {
        if !overview.isShown {
            previewed = nil
            highlight.hide()
            overview.show(windows: WindowList.onScreen(), displays: engine.displays.map(\.frame), title: title(of:))
            overviewPointerStart = NSEvent.mouseLocation
            pointerPicksTiles = false
        }
        // The mouse works too: once it moves, the tile under the pointer is the pick.
        let pointer = NSEvent.mouseLocation
        if !pointerPicksTiles, let start = overviewPointerStart, hypot(pointer.x - start.x, pointer.y - start.y) > Self.pointerTakeover {
            pointerPicksTiles = true
        }
        if pointerPicksTiles {
            overview.select(overview.tile(at: pointer))
            return
        }
        guard engine.latestSample != nil, let gaze = engine.gaze else {
            overview.select(nil)
            return
        }
        overview.select(WindowOverview.pick(
            gaze: gaze, sigma: sigmaPoints(at: gaze), tiles: overview.tiles.map(\.frame), current: overview.selected
        ))
    }

    /// Closes the overview and focuses the window of tile `index`, if any.
    private func pickOverviewTile(_ index: Int?) {
        let picked = index.map { overview.tiles[$0].window }
        disarm()
        guard let picked else {
            lastResult = "No window picked"
            return
        }
        let focused = WindowFocuser.focus(picked)
        lastResult = focused ? "Focused \(picked.appName)" : "Couldn't focus \(picked.appName)"
        if !picked.frame.contains(NSEvent.mouseLocation) {
            warpPointer(to: CGPoint(x: picked.frame.midX, y: picked.frame.midY))
        }
    }

    private func commit() {
        if overview.isShown {
            pickOverviewTile(overview.selected)
            return
        }
        // Hide the outline before switching, so it doesn't linger over the newly focused window.
        let shown = previewed
        let gazes = currentGazes()
        let buried = buried ?? []
        disarm()
        if let shown {
            act(on: shown)
            return
        }
        guard !gazes.isEmpty else {
            lastResult = "No gaze: face not tracked"
            return
        }
        if let pick = currentTarget(gazes: gazes, keeping: nil, buried: buried) { act(on: pick) }
    }

    private func act(on pick: Pick) {
        switch pick.target {
        case .window(let window):
            let alreadyFocused = window.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier
                && WindowList.onScreen().first(where: { $0.pid == window.pid })?.id == window.id
            if !alreadyFocused {
                let focused = WindowFocuser.focus(window)
                lastResult = focused ? "Focused \(window.appName)" : "Couldn't focus \(window.appName)"
            } else {
                lastResult = "\(window.appName) already has focus"
            }
            warpPointer(into: window.frame, toward: pick.gaze)
        case .ambiguous(let a, let b):
            lastResult = "Not sure: \(a.appName) or \(b.appName)"
            highlight.flash(pick.target, hidden: pick.hidden, title: title(of:))
        case .none:
            // Looking at the desktop of another display: focus what was last used there.
            let displays = engine.displays
            if let display = displays.display(containing: pick.gaze),
               display.displayID != displays.display(containing: NSEvent.mouseLocation)?.displayID {
                switchDisplay(to: display.displayID, gaze: pick.gaze)
            } else {
                lastResult = "No window where you looked"
            }
        }
    }

    // MARK: Displays

    private func startDisplayTimers() {
        displayTimer?.invalidate()
        memoryTimer?.invalidate()
        let display = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDisplayDwell() }
        }
        let memory = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rememberFocusedWindow() }
        }
        RunLoop.main.add(display, forMode: .common)
        RunLoop.main.add(memory, forMode: .common)
        displayTimer = display
        memoryTimer = memory
    }

    /// Notes which window has focus on which display. Only matters with more than one display.
    private func rememberFocusedWindow() {
        guard isEnabled, engine.displays.count > 1 else { return }
        let windows = WindowList.onScreen()
        if let focused = focusedWindow(in: windows) {
            displayMemory.record(focused: focused, displays: engine.displays)
            focusedDisplayID = DisplayMemory.display(of: focused, displays: engine.displays)?.displayID
        } else {
            focusedDisplayID = engine.displays.display(containing: NSEvent.mouseLocation)?.displayID
        }
    }

    /// Moves focus to another display once the gaze has rested on it, unless the user is typing,
    /// using the mouse, or holding a trigger.
    private func checkDisplayDwell() {
        let now = ProcessInfo.processInfo.systemUptime
        guard tuning.switchesDisplays, canTrigger, engine.displays.count > 1, focusedDisplayID != nil,
              !isArmed, !isPaneArmed, !overview.isShown,
              now - lastKeyTime >= tuning.typingPause, now - lastMouseTime >= tuning.mousePause
        else {
            displayDwell.reset()
            return
        }
        displayDwell.delay = tuning.displayDwell
        let gaze = engine.latestSample != nil ? engine.gaze : nil
        let sigma = gaze.map(sigmaPoints(at:)) ?? 0
        if let target = displayDwell.update(gaze: gaze, at: now, current: focusedDisplayID, displays: engine.displays, sigma: sigma), let gaze {
            switchDisplay(to: target, gaze: gaze)
        }
    }

    /// Focuses the window last used on the display (or its frontmost one) and brings the pointer
    /// there, so new windows, Spaces and Mission Control follow. With no window there, just the pointer.
    private func switchDisplay(to displayID: UInt32, gaze: CGPoint) {
        let windows = WindowList.onScreen()
        let name = engine.displays.first { $0.displayID == displayID }?.name ?? "the other display"
        if let window = displayMemory.window(on: displayID, windows: windows, displays: engine.displays) {
            let focused = WindowFocuser.focus(window)
            lastResult = focused ? "Focused \(window.appName) on \(name)" : "Couldn't focus \(window.appName)"
            if focused { displayMemory.record(focused: window, displays: engine.displays) }
            warpPointer(into: window.frame, toward: gaze)
        } else {
            warpPointer(to: gaze)
            lastResult = "Moved pointer to \(name)"
        }
        focusedDisplayID = displayID
    }

    /// Moves the pointer into `area`, where the gaze is (scrolling goes where the pointer is),
    /// unless it's already there.
    private func warpPointer(into area: CGRect, toward gaze: CGPoint) {
        guard !area.contains(NSEvent.mouseLocation) else { return }
        let inset = area.insetBy(dx: min(24, area.width / 4), dy: min(24, area.height / 4))
        warpPointer(to: CGPoint(x: min(max(gaze.x, inset.minX), inset.maxX), y: min(max(gaze.y, inset.minY), inset.maxY)))
    }

    /// The frontmost window of the frontmost app.
    private func focusedWindow(in windows: [ScreenWindow]) -> ScreenWindow? {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return windows.first { $0.pid == frontPID }
    }

    /// The pane of `panes` the gaze picks, judged like windows (a blur, a clear majority).
    private func pickPane(_ panes: WindowPanes, gazes: [CGPoint], sigma: Double, keeping current: Pane?) -> Pane? {
        let areas = panes.panes.map { ScreenWindow(id: UInt32($0.index), pid: 0, frame: $0.frame, appName: "") }
        let target = WindowTargeting.target(gazes: gazes, sigma: sigma, windows: areas, displays: engine.displays.map(\.frame), keeping: current.map { UInt32($0.index) }, thresholds: tuning.thresholds)
        return target.window.map { panes.panes[Int($0.id)] }
    }

    /// What the gaze picks: the window under it, or what's hidden behind the focused window there.
    private func currentTarget(gazes: [CGPoint], keeping previous: Pick?, buried: [ScreenWindow]) -> Pick? {
        guard let gaze = gazes.last else { return nil }
        let windows = WindowList.onScreen()
        let focused = focusedWindow(in: windows)
        let sigma = sigmaPoints(at: gaze)
        let displays = engine.displays.map(\.frame)
        // With revealing hidden windows off, looking at the focused window just picks it.
        let target = WindowTargeting.target(gazes: gazes, sigma: sigma, windows: windows, displays: displays, focused: tuning.revealsHidden ? focused?.id : nil, keeping: previous?.target.window?.id, thresholds: tuning.thresholds)
        let direct = WindowTargeting.target(gazes: gazes, sigma: sigma, windows: windows, displays: displays, thresholds: tuning.thresholds)
        let hidden = target.window.flatMap { $0.id != direct.window?.id ? $0.id : nil }
        return Pick(target: target, gaze: gaze, hidden: hidden)
    }

    // MARK: Pane trigger

    private func paneArm(at time: TimeInterval) {
        isPaneArmed = true
        armedAt = time
        // Read the focused window's panes now, so they're ready by the time the outline shows,
        // and connect to iTerm while the key is held.
        if let focused = focusedWindow(in: WindowList.onScreen()) { _ = paneCache.cached(focused) }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.googlecode.iterm2" {
            Self.paneQueue.async { PaneFinder.warmUpITerm() }
        }
        previewTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePanePreview() }
        }
        RunLoop.main.add(timer, forMode: .common)
        previewTimer = timer
    }

    private func paneDisarm() {
        guard isPaneArmed else { return }
        isPaneArmed = false
        panePicked = nil
        recentGazes = []
        previewTimer?.invalidate()
        previewTimer = nil
        highlight.hide()
    }

    private func updatePanePreview() {
        guard isPaneArmed else { return }
        recordGaze()
        guard ProcessInfo.processInfo.systemUptime - armedAt >= tuning.previewDelay else { return }
        guard let pick = currentPane(gazes: currentGazes(), keeping: panePicked?.pane) else {
            panePicked = nil
            highlight.hide()
            return
        }
        panePicked = pick
        highlight.show(.window(pick.window), hidden: nil, pane: (pick.pane.frame, true), title: title(of:))
    }

    private func paneCommit() {
        let shown = panePicked
        let gazes = currentGazes()
        paneDisarm()
        if let shown {
            act(onPane: shown)
            return
        }
        guard !gazes.isEmpty, let focused = focusedWindow(in: WindowList.onScreen()) else {
            lastResult = "No gaze: face not tracked"
            return
        }
        // A quick tap: wait for the panes if they're still being read.
        Task { @MainActor in
            guard await paneCache.panes(of: focused) != nil else {
                lastResult = "No panes Gaze can see in \(focused.appName)"
                return
            }
            if let pick = currentPane(gazes: gazes, keeping: nil) {
                act(onPane: pick)
            } else {
                lastResult = "No pane where you looked"
            }
        }
    }

    private func act(onPane pick: PanePick) {
        if pick.pane.index == pick.panes.focused {
            lastResult = "That pane already has focus"
        } else {
            paneCache.invalidate(pick.window.id)
            let (pane, window, count) = (pick.pane, pick.window, pick.panes.panes.count)
            Self.paneQueue.async { [weak self] in
                let focused = PaneFinder.focus(pane, of: window, paneCount: count)
                Task { @MainActor in
                    self?.lastResult = focused ? "Focused a pane in \(window.appName)" : "Couldn't focus the pane in \(window.appName)"
                }
            }
        }
        warpPointer(into: pick.pane.frame, toward: pick.gaze)
    }

    /// The pane of the focused window under the gaze. Panes come from the cache, so they join in
    /// once read.
    private func currentPane(gazes: [CGPoint], keeping current: Pane?) -> PanePick? {
        guard let gaze = gazes.last else { return nil }
        let windows = WindowList.onScreen()
        guard let focused = focusedWindow(in: windows) else { return nil }
        let sigma = sigmaPoints(at: gaze)
        let direct = WindowTargeting.target(gazes: gazes, sigma: sigma, windows: windows, displays: engine.displays.map(\.frame), thresholds: tuning.thresholds)
        guard direct.window?.id == focused.id, let panes = paneCache.cached(focused),
              let pane = pickPane(panes, gazes: gazes, sigma: sigma, keeping: current)
        else { return nil }
        return PanePick(pane: pane, panes: panes, window: focused, gaze: gaze)
    }

    /// Window titles for the labels, read through Accessibility once per hold.
    @ObservationIgnored private var titles: [UInt32: String?] = [:]

    private func title(of window: ScreenWindow) -> String? {
        if let cached = titles[window.id] { return cached }
        let title = WindowFocuser.title(of: window)
        titles[window.id] = title
        return title
    }

    /// The gaze blur's standard deviation in points on the display at `point`. The typical
    /// (mean) 2D error of a Gaussian blur is about 1.25σ.
    private func sigmaPoints(at point: CGPoint) -> Double {
        let millimetersPerPoint = engine.displays.display(containing: point)?.millimetersPerPoint ?? 0.2
        let sigma = min(max(gazeErrorMillimeters() / 1.25, 8), 40) * tuning.blurScale
        return sigma / millimetersPerPoint
    }

    // MARK: Pointer jump

    private func handleMouseMove(_ event: NSEvent) {
        let now = event.timestamp
        let location = NSEvent.mouseLocation
        defer { lastMouseMove = now }
        if now - lastMouseMove > Self.movementPause {
            moveStart = (location, now)
        }
        guard let start = moveStart else { return }
        let moved = hypot(location.x - start.point.x, location.y - start.point.y)
        if now - start.time > Self.decisionTime, moved < tuning.jumpDecisionDistance {
            moveStart = nil
            return
        }
        guard moved >= tuning.jumpDecisionDistance else { return }
        moveStart = nil

        guard pointerJumpEnabled, !isArmed, now >= jumpBlockedUntil, !isSuspended(),
              engine.model != nil, engine.latestSample != nil, let gaze = engine.gaze
        else { return }
        let millimetersPerPoint = engine.displays.display(containing: gaze)?.millimetersPerPoint ?? 0.2
        // Jump only past a reach worth saving: well beyond the gaze's own error, and at least the
        // set distance (8 cm by default).
        let minimumDistance = max(4 * sigmaPoints(at: gaze), tuning.jumpMinimumDistance / millimetersPerPoint)
        guard PointerJump.shouldJump(
            from: start.point, to: location, gaze: gaze, minimumDistance: minimumDistance,
            decisionDistance: tuning.jumpDecisionDistance, maximumAngle: tuning.jumpMaximumAngle
        ) else { return }
        warpPointer(to: gaze)
        jumpBlockedUntil = now + 0.5
    }

    private func warpPointer(to point: CGPoint) {
        CGWarpMouseCursorPosition(WindowList.quartzPoint(point))
        // Without this the pointer freezes for a moment after a warp.
        CGAssociateMouseAndMouseCursorPosition(1)
        jumpBlockedUntil = ProcessInfo.processInfo.systemUptime + 0.5
    }
}

/// Other apps' windows currently on screen.
enum WindowList {
    /// Front to back, in global AppKit coordinates. Only ordinary windows (layer 0): no menus,
    /// Dock, menu bar or desktop. Window titles aren't read, so no Screen Recording access is needed.
    static func onScreen() -> [ScreenWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return info.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  let id = entry[kCGWindowNumber as String] as? UInt32,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let boundsInfo = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  bounds.width >= 60, bounds.height >= 60
            else { return nil }
            let name = entry[kCGWindowOwnerName as String] as? String ?? "App"
            return ScreenWindow(id: id, pid: pid, frame: appKitRect(bounds), appName: name)
        }
    }

    /// Quartz and Accessibility use a top-left origin on the primary display; AppKit a bottom-left one.
    static var primaryHeight: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }

    static func appKitRect(_ quartz: CGRect) -> CGRect {
        CGRect(x: quartz.minX, y: primaryHeight - quartz.maxY, width: quartz.width, height: quartz.height)
    }

    static func quartzRect(_ appKit: CGRect) -> CGRect {
        CGRect(x: appKit.minX, y: primaryHeight - appKit.maxY, width: appKit.width, height: appKit.height)
    }

    static func quartzPoint(_ appKit: CGPoint) -> CGPoint {
        CGPoint(x: appKit.x, y: primaryHeight - appKit.y)
    }
}

/// Raises and focuses another app's window through the Accessibility API.
enum WindowFocuser {
    /// Window ordering and app activation from a background app: macOS 14+ often ignores a plain
    /// `activate()` from an app that isn't frontmost, but honors Accessibility.
    @discardableResult
    static func focus(_ window: ScreenWindow) -> Bool {
        let app = AXUIElementCreateApplication(window.pid)
        // Don't stall on an unresponsive app.
        AXUIElementSetMessagingTimeout(app, 0.25)
        let element = axWindow(of: app, matching: WindowList.quartzRect(window.frame))
        if let element {
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        let activated = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success
        if let element {
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        if !activated {
            NSRunningApplication(processIdentifier: window.pid)?.activate()
        }
        return activated || element != nil
    }

    /// The window's title, if the app exposes it. Read through Accessibility rather than the window
    /// list, which would need Screen Recording access.
    static func title(of window: ScreenWindow) -> String? {
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard let element = axWindow(of: app, matching: WindowList.quartzRect(window.frame)) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success,
              let title = value as? String, !title.isEmpty
        else { return nil }
        return title
    }

    /// The app's Accessibility window with this frame (Quartz coordinates): window lists and
    /// Accessibility share no identifier without private API, but frames match exactly.
    static func axWindow(of app: AXUIElement, matching frame: CGRect) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return nil }
        let scored = windows.compactMap { window -> (AXUIElement, CGFloat)? in
            guard let rect = frameOf(window) else { return nil }
            let difference = abs(rect.minX - frame.minX) + abs(rect.minY - frame.minY) + abs(rect.width - frame.width) + abs(rect.height - frame.height)
            return (window, difference)
        }
        guard let best = scored.min(by: { $0.1 < $1.1 }), best.1 < 8 else { return nil }
        return best.0
    }

    private static func frameOf(_ window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }
}

/// Outlines the window a trigger will pick (or the two it can't decide between), labeled with
/// the app and window title.
@MainActor
final class FocusHighlight {
    private var windows: [OverlayWindow] = []
    private var flashTask: Task<Void, Never>?

    /// `hidden` is a window shown from behind the focused one: drawn as a ghost over it.
    /// `pane` is a pane inside the target window to outline too; `alone`, only the pane (the
    /// window already has focus).
    func show(_ target: WindowTarget, hidden: UInt32?, pane: (frame: CGRect, alone: Bool)? = nil, title: (ScreenWindow) -> String?) {
        flashTask?.cancel()
        var items: [(ScreenWindow, HighlightView.Style)] = switch target {
        case .window(let window): [(window, window.id == hidden ? .hidden : .picked)]
        case .ambiguous(let a, let b): [(a, .unsure), (b, .unsure)]
        case .none: []
        }
        if let pane, let window = target.window {
            let area = ScreenWindow(id: 0, pid: window.pid, frame: pane.frame, appName: window.appName)
            items = pane.alone ? [(area, .picked)] : items + [(area, .pane)]
        }
        // Called on every preview tick: redraw only when what's shown changes.
        let shown = items.map { ShownItem(id: $0.0.id, frame: $0.0.frame, style: $0.1) }
        guard shown != lastShown || windows.count != items.count else { return }
        lastShown = shown
        while windows.count > items.count {
            windows.removeLast().close()
        }
        for (index, (window, style)) in items.enumerated() {
            let view = HighlightView(
                style: style,
                icon: NSRunningApplication(processIdentifier: window.pid)?.icon,
                appName: window.appName,
                title: title(window)
            )
            let padded = window.frame.insetBy(dx: -3, dy: -3)
            if index < windows.count {
                windows[index].setFrame(padded, display: true)
                (windows[index].contentView as? NSHostingView<HighlightView>)?.rootView = view
            } else {
                let overlay = OverlayWindow.make(covering: padded, interactive: false, content: view)
                overlay.orderFrontRegardless()
                windows.append(overlay)
            }
        }
    }

    /// Dashed outlines of the windows buried behind the focused one, so it's clear what's there
    /// to bring back. Shown once per hold, fading in, and left alone after that: the pick's
    /// outline goes on top. Tags show the app only: reading every window's title through
    /// Accessibility at once stalls on slow apps, right when the trigger goes down.
    func showBuried(_ buried: [ScreenWindow], labeled: Bool) {
        guard buriedWindows.isEmpty, !buried.isEmpty else { return }
        for window in buried.reversed() {
            let view = HighlightView(style: labeled ? .buried : .buriedUnlabeled, icon: NSRunningApplication(processIdentifier: window.pid)?.icon, appName: window.appName, title: nil)
            let overlay = OverlayWindow.make(covering: window.frame.insetBy(dx: -2, dy: -2), interactive: false, content: view)
            overlay.alphaValue = 0
            // Below the outline of the pick, which may already be up.
            if let pick = windows.first { overlay.order(.below, relativeTo: pick.windowNumber) } else { overlay.orderFrontRegardless() }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                overlay.animator().alphaValue = 1
            }
            buriedWindows.append((window.id, overlay))
        }
    }

    private var buriedWindows: [(id: UInt32, overlay: OverlayWindow)] = []

    private struct ShownItem: Equatable {
        var id: UInt32
        var frame: CGRect
        var style: HighlightView.Style
    }
    private var lastShown: [ShownItem] = []

    /// Shows the outline briefly, as confirmation of what a quick tap did.
    func flash(_ target: WindowTarget, hidden: UInt32?, title: (ScreenWindow) -> String?) {
        show(target, hidden: hidden, title: title)
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(hidden == nil ? 350 : 600))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        flashTask?.cancel()
        lastShown = []
        windows.forEach { $0.orderOut(nil); $0.close() }
        windows = []
        buriedWindows.forEach { $0.overlay.orderOut(nil); $0.overlay.close() }
        buriedWindows = []
    }
}

private struct HighlightView: View {
    enum Style {
        /// The visible window that will be focused.
        case picked
        /// A window hidden behind the focused one, which will be brought back.
        case hidden
        /// One of two windows the gaze can't decide between.
        case unsure
        /// The pane inside the picked window that will get focus.
        case pane
        /// A window buried behind the focused one, shown while the trigger is held.
        case buried, buriedUnlabeled
    }

    let style: Style
    let icon: NSImage?
    let appName: String
    let title: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(style == .hidden ? Color.accentColor.opacity(0.12) : .clear)
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    style == .unsure ? Color.gray : style == .buried || style == .buriedUnlabeled ? Color.accentColor.opacity(0.7) : Color.accentColor,
                    style: StrokeStyle(lineWidth: style == .picked ? 4 : style == .pane || style == .buried || style == .buriedUnlabeled ? 2 : 3, dash: style == .picked || style == .pane ? [] : [10, 6])
                )
            if style == .buried { chip }
            // A visible window speaks for itself; a hidden one is only an outline, and between two
            // candidates the names tell which is which.
            if style == .hidden || style == .unsure { label }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    /// A small name tag in the corner, for buried windows: several can be shown at once.
    private var chip: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
            }
            Text(title.map { $0 == appName ? appName : "\(appName) – \($0)" } ?? appName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: 280, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var label: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 32, height: 32)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(appName).font(.headline)
                if let title, title != appName {
                    Text(title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if style == .hidden {
                    Text("Behind this window")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 8)
        .padding(12)
    }
}
