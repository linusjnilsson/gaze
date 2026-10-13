import CoreGraphics
import Foundation

/// Decides when looking at another display should move focus there, without a key: the gaze has
/// to rest well inside that display, clear of the bezel by more than the tracking error, for a
/// moment. Glances across, and gaze hovering at the border, never switch.
public struct DisplayDwell: Sendable {
    /// How long the gaze must stay on the other display (seconds).
    public var delay: TimeInterval
    /// How far inside the other display the gaze must be, in multiples of the gaze blur's sigma.
    public var margin: Double = 2
    /// Gaps in tracking shorter than this (blinks, a dropped frame) don't restart the wait.
    public var gapTolerance: TimeInterval = 0.25
    /// After switching, the next switch waits at least this long.
    public var cooldown: TimeInterval = 1

    private var candidate: (displayID: UInt32, since: TimeInterval, lastSeen: TimeInterval)?
    private var lastSwitch: TimeInterval = -.infinity

    public init(delay: TimeInterval) {
        self.delay = delay
    }

    /// Forgets the wait, after typing, mouse use, or a trigger.
    public mutating func reset() {
        candidate = nil
    }

    /// Feeds one gaze point (`nil` while untracked). `current` is the display that has focus,
    /// `sigma` the gaze blur in points. Returns the display to switch to, once.
    public mutating func update(gaze: CGPoint?, at time: TimeInterval, current: UInt32?, displays: [DisplayInfo], sigma: Double) -> UInt32? {
        guard let gaze else {
            if let candidate, time - candidate.lastSeen > gapTolerance { self.candidate = nil }
            return nil
        }
        guard let display = displays.first(where: { $0.frame.contains(gaze) }),
              display.displayID != current,
              Self.distanceInside(gaze, display.frame) >= margin * sigma
        else {
            candidate = nil
            return nil
        }
        if let candidate, candidate.displayID == display.displayID, time - candidate.lastSeen <= gapTolerance {
            self.candidate?.lastSeen = time
        } else {
            candidate = (display.displayID, time, time)
        }
        guard let candidate, time - candidate.since >= delay, time - lastSwitch >= cooldown else { return nil }
        self.candidate = nil
        lastSwitch = time
        return candidate.displayID
    }

    /// Distance from `point` to the nearest edge of `rect` it's inside.
    static func distanceInside(_ point: CGPoint, _ rect: CGRect) -> Double {
        min(point.x - rect.minX, rect.maxX - point.x, point.y - rect.minY, rect.maxY - point.y)
    }
}

/// The window last focused on each display, so moving focus to a display without a window in
/// view brings back what was used there.
public struct DisplayMemory: Sendable {
    private var lastWindow: [UInt32: UInt32] = [:]

    public init() {}

    /// Notes the focused window (front to back `windows`, the frontmost app's first) on the display
    /// holding most of it.
    public mutating func record(focused: ScreenWindow, displays: [DisplayInfo]) {
        guard let display = Self.display(of: focused, displays: displays) else { return }
        lastWindow[display.displayID] = focused.id
    }

    /// The window to focus on `displayID`: the one last focused there if it's still open and still
    /// mostly there, otherwise the frontmost window on it.
    public func window(on displayID: UInt32, windows: [ScreenWindow], displays: [DisplayInfo]) -> ScreenWindow? {
        let onDisplay = windows.filter { Self.display(of: $0, displays: displays)?.displayID == displayID }
        return onDisplay.first { $0.id == lastWindow[displayID] } ?? onDisplay.first
    }

    /// The display holding most of `window`.
    public static func display(of window: ScreenWindow, displays: [DisplayInfo]) -> DisplayInfo? {
        let groups = WindowOverview.byDisplay([window], displays: displays.map(\.frame))
        return groups.firstIndex { !$0.isEmpty }.map { displays[$0] }
    }
}
